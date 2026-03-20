# syntax=docker/dockerfile:1
FROM docker.io/denoland/deno:alpine-2.3.5 AS asset-builder
WORKDIR /weasyl-build
RUN mkdir /weasyl-assets && chown deno:deno /weasyl-build /weasyl-assets
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
RUN apk add --no-cache wget musl-dev gcc make cmake nasm
WORKDIR /mozjpeg-src
# Tải trực tiếp bằng wget để đảm bảo file tồn tại
RUN wget https://github.com -O mozjpeg.tar.gz \
    && tar xf mozjpeg.tar.gz
WORKDIR /mozjpeg-src/mozjpeg-4.1.5/build
RUN cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/mozjpeg-pkg -S .. -B . \
    && cmake --build . --parallel --target install

FROM docker.io/library/alpine:3.22 AS imagemagick-build
RUN apk add --no-cache wget musl-dev gcc make lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
COPY --from=mozjpeg-build /mozjpeg-pkg/include/ /usr/include/
COPY --from=mozjpeg-build /mozjpeg-pkg/lib/ /usr/lib/
WORKDIR /im-src
RUN wget https://imagemagick.org -O im.tar.xz \
    && tar xf im.tar.xz
WORKDIR /im-src/ImageMagick-6.9.13-41
RUN ./configure --prefix=/usr --with-security-policy=websafe --disable-static --enable-shared \
    --with-cache=32GiB --without-x --with-xml \
    && make -j"$(nproc)" && make install DESTDIR="/im-pkg"

FROM docker.io/library/python:3.10-alpine3.22 AS bdist
RUN apk add --no-cache gcc musl-dev libmemcached-dev zlib-dev libpq-dev
WORKDIR /weasyl
COPY --from=mozjpeg-build /mozjpeg-pkg/ /usr/
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
COPY --from=mozjpeg-build /mozjpeg-pkg/lib/ /usr/lib/
COPY --from=imagemagick-build /im-pkg/ /
COPY --from=bdist /weasyl/.venv .venv
COPY --from=assets /weasyl-build/build build
COPY --link libweasyl libweasyl
COPY --link weasyl weasyl
RUN mkdir -p storage/log storage/static storage/profile-stats && chown -R weasyl /weasyl

FROM package
USER weasyl
ENV PORT=8080
EXPOSE 8080
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
