# syntax=docker/dockerfile:1
FROM docker.io/denoland/deno:alpine-2.3.5 AS asset-builder
WORKDIR /weasyl-build
RUN mkdir -p /weasyl-build/node_modules && chown -R deno:deno /weasyl-build
USER deno
COPY --link deno.json deno.lock ./
RUN deno install --frozen
COPY --link build.ts build.ts

FROM asset-builder AS assets
COPY --link assets assets
RUN mkdir build && deno run \
    --frozen \
    --allow-env \
    --allow-read \
    --allow-write \
    --allow-run \
    build.ts \
    --assets=./assets/ \
    --output=./build/

FROM docker.io/library/alpine:3.22 AS mozjpeg-build
RUN apk add --no-cache curl tar musl-dev gcc make cmake nasm
WORKDIR /mozjpeg-src
RUN curl -L "https://github.com" | tar -xz && \
    mv mozjpeg-* source && mkdir build && cd build && \
    cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/usr -S ../source -B . && \
    make -j"$(nproc)" && make install DESTDIR=/mozjpeg-pkg

FROM docker.io/library/alpine:3.22 AS imagemagick-build
RUN apk add --no-cache curl tar xz musl-dev gcc make lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
COPY --from=mozjpeg-build /mozjpeg-pkg/ /
WORKDIR /im-src
RUN curl -L "https://imagemagick.org" | tar -xJ && \
    mv ImageMagick-* source && cd source && \
    ./configure --prefix=/usr --with-security-policy=websafe --disable-static --enable-shared \
    --with-cache=32GiB --without-x --with-xml && \
    make -j"$(nproc)" && make install DESTDIR="/im-pkg"

FROM docker.io/library/python:3.10-alpine3.22 AS bdist
RUN apk add --no-cache gcc musl-dev libmemcached-dev zlib-dev libpq-dev
WORKDIR /weasyl
COPY --from=mozjpeg-build /mozjpeg-pkg/ /
COPY --from=imagemagick-build /im-pkg/ /
COPY --link poetry-requirements.txt ./
RUN python3 -m venv .poetry-venv && .poetry-venv/bin/python3 -m pip install -r poetry-requirements.txt
RUN python3 -m venv .venv
COPY --link pyproject.toml poetry.lock setup.py ./
RUN .poetry-venv/bin/poetry install --only=main --no-root
RUN mkdir -p libweasyl weasyl && touch libweasyl/__init__.py weasyl/__init__.py
RUN .poetry-venv/bin/poetry install --only-root

FROM docker.io/library/python:3.10-alpine3.22 AS package
RUN apk add --no-cache libgcc libgomp lcms2 libpng libxml2 libwebpdemux libwebpmux libmemcached-libs libpq
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl
COPY --from=mozjpeg-build /mozjpeg-pkg/ /
COPY --from=imagemagick-build /im-pkg/ /
COPY --from=bdist /weasyl/.venv .venv
COPY --from=assets /weasyl-build/build build
COPY --link libweasyl libweasyl
COPY --link weasyl weasyl
RUN mkdir -p storage/log storage/static storage/profile-stats && chown -R weasyl /weasyl

FROM package
USER weasyl
ENV PORT=8080
ENV WEASYL_APP_ROOT=/weasyl
EXPOSE 8080
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
