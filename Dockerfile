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

FROM docker.io/library/alpine:3.22 AS mozjpeg-src
WORKDIR /mozjpeg-build
# Bỏ --chown tại đây để tránh lỗi invalid user index
ADD --link https://github.com ./
RUN tar xf v4.1.5.tar.gz

FROM docker.io/library/alpine:3.22 AS mozjpeg
RUN apk upgrade && apk add musl-dev gcc make cmake nasm
WORKDIR /mozjpeg-build/build
COPY --from=mozjpeg-src /mozjpeg-build/mozjpeg-4.1.5 /mozjpeg-build/mozjpeg
RUN cmake -DENABLE_STATIC=0 -DPNG_SUPPORTED=0 -DCMAKE_INSTALL_PREFIX=/mozjpeg-build/package-root -S ../mozjpeg -B . \
    && cmake --build . --parallel --target install

FROM docker.io/library/alpine:3.22 AS imagemagick6-src
WORKDIR /imagemagick6-build
# Bỏ --chown tại đây
ADD --link https://imagemagick.org ./
RUN tar xf ImageMagick-6.9.13-41.tar.xz

FROM docker.io/library/alpine:3.22 AS imagemagick6-build
RUN apk upgrade && apk add musl-dev gcc make lcms2-dev libpng-dev libxml2-dev libwebp-dev zlib-dev
COPY --from=mozjpeg /mozjpeg-build/package-root/include/ /usr/include/
COPY --from=mozjpeg /mozjpeg-build/package-root/lib64/ /usr/lib/
WORKDIR /imagemagick6-build/ImageMagick
COPY --from=imagemagick6-src /imagemagick6-build/ImageMagick-6.9.13-41 /imagemagick6-build/ImageMagick
RUN ./configure \
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
    && make install DESTDIR="/imagemagick-package"

FROM docker.io/library/python:3.10-alpine3.22 AS bdist
RUN apk upgrade && apk add gcc musl-dev libmemcached-dev zlib-dev libpq-dev
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl
COPY --from=mozjpeg /mozjpeg-build/package-root/include/ /usr/include/
COPY --from=mozjpeg /mozjpeg-build/package-root/lib64/ /usr/lib/
COPY --from=imagemagick6-build /imagemagick-package/ /
COPY --link poetry-requirements.txt ./
RUN python3 -m venv --system-site-packages --without-pip .poetry-venv
RUN .poetry-venv/bin/python3 -m pip install --require-hashes --only-binary :all: --no-deps -r poetry-requirements.txt
RUN python3 -m venv --system-site-packages --without-pip .venv
COPY --link pyproject.toml poetry.lock setup.py ./
RUN .poetry-venv/bin/poetry install --only=main --no-root
RUN dirs='libweasyl/models/test libweasyl/test weasyl/controllers weasyl/test/login weasyl/test/resetpassword weasyl/test/useralias weasyl/test/web weasyl/util'; \
    mkdir -p $dirs && for dir in $dirs; do touch "$dir/__init__.py"; done
RUN .poetry-venv/bin/poetry install --only-root

FROM docker.io/library/python:3.10-alpine3.22 AS package
RUN apk upgrade && apk add libgcc libgomp lcms2 libpng libxml2 libwebpdemux libwebpmux libmemcached-libs libpq
RUN adduser -S weasyl -h /weasyl -u 1000
WORKDIR /weasyl
COPY --from=mozjpeg /mozjpeg-build/package-root/lib64/ /usr/lib/
COPY --from=imagemagick6-build /imagemagick-package/ /
COPY --link imagemagick-policy.xml /usr/etc/ImageMagick-6/policy.xml
COPY --from=bdist /weasyl/.venv .venv
COPY --from=assets /weasyl-build/build build
COPY --link libweasyl libweasyl
COPY --link weasyl weasyl

FROM package
RUN mkdir -p storage storage/log storage/static storage/profile-stats uds-nginx-web \
    && ln -s /run/config config \
    && chown -R weasyl /weasyl
USER weasyl
ENV WEASYL_APP_ROOT=/weasyl
ENV PORT=8080
CMD [".venv/bin/gunicorn", "-b", "0.0.0.0:8080", "weasyl.main:app"]
EXPOSE 8080
COPY --link gunicorn.conf.py ./
