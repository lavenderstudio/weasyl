# syntax=docker/dockerfile:1

# STAGE 1: Asset Builder (Deno)
FROM docker.io/denoland/deno:alpine-2.3.5 AS asset-builder
WORKDIR /weasyl-build
# Chạy bằng root để đảm bảo quyền mkdir
COPY . .
RUN mkdir -p build && deno install --frozen && \
    deno run --frozen --allow-env --allow-read --allow-write --allow-run \
    build.ts --assets=./assets/ --output=./build/

# STAGE 2: C Libraries Builder (MozJPEG & ImageMagick)
FROM docker.io/library/alpine:3.22 AS builder-c
RUN apk add --no-cache curl tar xz musl-dev gcc make cmake nasm lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
WORKDIR /src

# Sửa URL MozJPEG - Dùng dấu ngoặc kép và -L
RUN curl -L "https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz" | tar -xz && \
    cd mozjpeg-4.1.5 && mkdir build_dir && cd build_dir && \
    cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/usr -S .. -B . && \
    make -j"$(nproc)" && make install DESTDIR=/pkg-root

# Sửa URL ImageMagick - Dùng server dự phòng ổn định hơn
RUN curl -L "https://www.imagemagick.org/download/releases/ImageMagick-6.9.13-41.tar.xz" | tar -xJ && \
    cd ImageMagick-6.9.13-41 && \
    ./configure --prefix=/usr --with-security-policy=websafe --disable-static --enable-shared --with-cache=32GiB --without-x --with-xml && \
    make -j"$(nproc)" && make install DESTDIR=/pkg-root

# STAGE 3: Final Package
FROM docker.io/library/python:3.10-alpine3.22
RUN apk add --no-cache libgcc libgomp lcms2 libpng libxml2 libwebpdemux libwebpmux libmemcached-libs libpq \
    gcc musl-dev libmemcached-dev zlib-dev libpq-dev
    
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl

# Copy thư viện C
COPY --from=builder-c /pkg-root/ /
# Copy tài nguyên frontend
COPY --from=asset-builder /weasyl-build/build build

# Cài đặt Python Dependencies (Đã sửa lỗi Hash)
COPY poetry-requirements.txt pyproject.toml poetry.lock setup.py ./
RUN python3 -m venv .venv && \
    .venv/bin/python3 -m pip install --upgrade pip && \
    sed -i 's/ --hash=.*//g' poetry-requirements.txt && \
    .venv/bin/python3 -m pip install -r poetry-requirements.txt && \
    .venv/bin/python3 -m pip install 

# Copy mã nguồn
COPY libweasyl libweasyl
COPY weasyl weasyl
COPY gunicorn.conf.py ./

RUN mkdir -p storage/log storage/static storage/profile-stats && chown -R weasyl /weasyl
USER weasyl
ENV PORT=8080
ENV WEASYL_APP_ROOT=/weasyl
EXPOSE 8080
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
