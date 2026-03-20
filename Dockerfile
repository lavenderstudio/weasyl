# syntax=docker/dockerfile:1

# STAGE 1: Xây dựng tài nguyên Frontend
FROM docker.io/denoland/deno:alpine-2.3.5 AS asset-builder
WORKDIR /weasyl-build
RUN mkdir -p /weasyl-build/node_modules && chown -R deno:deno /weasyl-build
USER deno
COPY --link deno.json deno.lock ./
RUN deno install --frozen
COPY --link assets assets
COPY --link build.ts build.ts
RUN mkdir build && deno run --frozen --allow-env --allow-read --allow-write --allow-run build.ts --assets=./assets/ --output=./build/

# STAGE 2: Biên dịch các thư viện C (MozJPEG & ImageMagick)
FROM docker.io/library/alpine:3.22 AS builder-c
RUN apk add --no-cache curl tar xz musl-dev gcc make cmake nasm lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
WORKDIR /src

# Build MozJPEG
RUN curl -L "https://github.com" | tar -xz && \
    cd mozjpeg-* && mkdir build && cd build && \
    cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/usr -S .. -B . && \
    make -j"$(nproc)" && make install DESTDIR=/pkg-root

# Build ImageMagick
RUN curl -L "https://imagemagick.org" | tar -xJ && \
    cd ImageMagick-* && \
    ./configure --prefix=/usr --with-security-policy=websafe --disable-static --enable-shared --with-cache=32GiB --without-x --with-xml && \
    make -j"$(nproc)" && make install DESTDIR=/pkg-root

# STAGE 3: Chuẩn bị môi trường Python
FROM docker.io/library/python:3.10-alpine3.22 AS python-build
RUN apk add --no-cache gcc musl-dev libmemcached-dev zlib-dev libpq-dev
WORKDIR /weasyl
COPY --from=builder-c /pkg-root/ /
COPY --link poetry-requirements.txt pyproject.toml poetry.lock setup.py ./
RUN python3 -m venv .poetry-venv && .poetry-venv/bin/python3 -m pip install -r poetry-requirements.txt
RUN .poetry-venv/bin/poetry install --only=main --no-root
RUN mkdir -p libweasyl weasyl && touch libweasyl/__init__.py weasyl/__init__.py && \
    .poetry-venv/bin/poetry install --only-root

# STAGE 4: Stage chạy cuối cùng (Package)
FROM docker.io/library/python:3.10-alpine3.22 AS package
RUN apk add --no-cache libgcc libgomp lcms2 libpng libxml2 libwebpdemux libwebpmux libmemcached-libs libpq
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl

COPY --from=builder-c /pkg-root/ /
COPY --from=python-build /weasyl/.venv .venv
COPY --from=asset-builder /weasyl-build/build build
COPY --link libweasyl libweasyl
COPY --link weasyl weasyl
COPY --link gunicorn.conf.py ./

RUN mkdir -p storage/log storage/static storage/profile-stats && chown -R weasyl /weasyl
USER weasyl
ENV PORT=8080
ENV WEASYL_APP_ROOT=/weasyl
EXPOSE 8080
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
