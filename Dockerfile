# syntax=docker/dockerfile:1
FROM docker.io/denoland/deno:alpine-2.3.5 AS asset-builder
WORKDIR /weasyl-build
RUN mkdir /weasyl-assets && chown deno:deno /weasyl-build /weasyl-assets
USER deno

COPY --chown=deno:deno --link deno.json deno.lock ./

# ĐÃ XÓA MOUNT CACHE
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

FROM docker.io/library/alpine:3.22 AS mozjpeg-src
RUN adduser -S build -h /mozjpeg-build
USER build
WORKDIR /mozjpeg-build
ADD --checksum=sha256:9fcbb7171f6ac383f5b391175d6fb3acde5e64c4c4727274eade84ed0998fcc1 --chown=build --link https://github.com/mozilla/mozjpeg/archive/refs/tags/v4.1.5.tar.gz ./
RUN tar xf v4.1.5.tar.gz

FROM docker.io/library/alpine:3.22 AS mozjpeg
# ĐÃ XÓA MOUNT CACHE
RUN apk upgrade && apk add musl-dev gcc make cmake nasm
RUN adduser -S build -h /mozjpeg-build
USER build
WORKDIR /mozjpeg-build/build
RUN --mount=type=bind,from=mozjpeg-src,source=/mozjpeg-build/mozjpeg-4.1.5,target=/mozjpeg-build/mozjpeg \
    cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/mozjpeg-build/package-root -S ../mozjpeg -B . \
    && cmake --build . --parallel --target install

FROM docker.io/library/alpine:3.22 AS imagemagick6-src
RUN adduser -S build -h /imagemagick6-build
USER build
WORKDIR /imagemagick6-build
ADD --checksum=sha256:fb77a60f500ed82c92ea692b13704c5691a3237e8e07e0987761c42432c65a8b --chown=build --link https://imagemagick.org/archive/releases/ImageMagick-6.9.13-41.tar.xz ./
RUN tar xf ImageMagick-6.9.13-41.tar.xz

FROM docker.io/library/alpine:3.22 AS imagemagick6-build
RUN adduser -S build -h /imagemagick6-build
# ĐÃ XÓA MOUNT CACHE
RUN apk upgrade && apk add musl-dev gcc make lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
USER build
COPY --from=mozjpeg --chown=root:root --link /mozjpeg-build/package-root/include/ /usr/include/
COPY --from=mozjpeg --chown=root:root --link /mozjpeg-build/package-root/lib64/ /usr/lib/
WORKDIR /imagemagick6-build/ImageMagick
RUN \
    --mount=type=bind,from=imagemagick6-src,source=/imagemagick6-build/ImageMagick-6.9.13-41,target=/imagemagick6-build/ImageMagick,rw \
    ./configure \
    --prefix=/usr \
    --with-security-policy=websafe \
    --disable-static \
    --enable-shared \
    --disable-deprecated \
    --disable-docs \
    --disable-cipher \
    --with-cache=32GiB \
    --without-magick-plus-plus \
    --without-perl \
    --without-bzlib \
    --without-dps \
    --without-djvu \
    --without-flif \
    --without-freetype \
    --without-heic \
    --without-jbig \
    --without-openjp2 \
    --without-lqr \
    --without-lzma \
    --without-openexr \
    --without-pango \
    --without-raw \
    --without-raqm \
    --without-tiff \
    --without-wmf \
    --with-xml \
    --without-x \
    --without-zstd \
    CFLAGS='-O2 -fstack-clash-protection -Wformat -Werror=format-security' \
    LDFLAGS='-Wl,--as-needed,-O1,--sort-common' \
    && make -j"$(nproc)" \
    && make install DESTDIR="$HOME/package-root"

FROM docker.io/library/python:3.10-alpine3.22 AS bdist
# ĐÃ XÓA MOUNT CACHE
RUN apk upgrade && apk add gcc musl-dev libmemcached-dev zlib-dev libpq-dev
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl
USER weasyl
COPY --from=mozjpeg --chown=root:root --link /mozjpeg-build/package-root/include/ /usr/include/
COPY --from=mozjpeg --chown=root:root --link /mozjpeg-build/package-root/lib64/ /usr/lib/
COPY --from=imagemagick6-build --chown=root:root --link /imagemagick6-build/package-root/ /
COPY --link poetry-requirements.txt ./
RUN python3 -m venv --system-site-packages --without-pip .poetry-venv
# ĐÃ XÓA MOUNT CACHE
RUN .poetry-venv/bin/python3 -m pip install --require-hashes --only-binary :all: --no-deps -r poetry-requirements.txt
RUN python3 -m venv --system-site-packages --without-pip .venv
COPY --chown=weasyl --link pyproject.toml poetry.lock setup.py ./
# ĐÃ XÓA MOUNT CACHE
RUN .poetry-venv/bin/poetry install --only=main --no-root
RUN dirs='libweasyl/models/test libweasyl/test weasyl/controllers weasyl/test/login weasyl/test/resetpassword weasyl/test/useralias weasyl/test/web weasyl/util'; \
    mkdir -p $dirs && for dir in $dirs; do touch "$dir/__init__.py"; done
RUN .poetry-venv/bin/poetry install --only-root

FROM bdist AS bdist-pytest
# ĐÃ XÓA MOUNT CACHE
RUN .poetry-venv/bin/poetry install --only=dev

FROM docker.io/library/python:3.10-alpine3.22 AS package
# ĐÃ XÓA MOUNT CACHE
RUN apk upgrade && apk add libgcc libgomp lcms2 libpng libxml2 libwebpdemux libwebpmux libmemcached-libs libpq
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl
USER weasyl
COPY --from=mozjpeg --chown=root:root --link /mozjpeg-build/package-root/lib64/ /usr/lib/
COPY --from=imagemagick6-build --chown=root:root --link /imagemagick6-build/package-root/ /
COPY --chown=root:root --link imagemagick-policy.xml /usr/etc/ImageMagick-6/policy.xml

COPY --from=bdist --link /weasyl/.venv .venv
COPY --from=assets --link /weasyl-build/build build
COPY --chown=weasyl:root --link libweasyl libweasyl
COPY --chown=weasyl:root --link weasyl weasyl

ARG version
RUN test -n "$version" && printf '%s\n' "$version" > version.txt

FROM package
RUN mkdir storage storage/log storage/static storage/profile-stats uds-nginx-web \
    && ln -s /run/config config
ENV WEASYL_APP_ROOT=/weasyl
ENV PORT=8080
# Lệnh chạy Weasyl trên Railway
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
EXPOSE 8080
COPY --link gunicorn.conf.py ./
