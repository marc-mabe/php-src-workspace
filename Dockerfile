# Dev image for native 64-bit builds (arm64 or amd64 depending on --platform).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV PHP_SRC_DOCKER=1

RUN set -eux; \
apt-get update -y; \
apt-get install -y --no-install-recommends \
    autoconf \
    bison \
    build-essential \
    ca-certificates \
    curl \
    git \
    libargon2-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    libedit-dev \
    libffi-dev \
    libfreetype6-dev \
    libgmp-dev \
    libicu-dev \
    libjpeg-dev \
    libonig-dev \
    libpng-dev \
    libpq-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    libwebp-dev \
    libxml2-dev \
    libxslt1-dev \
    libzip-dev \
    locales \
    make \
    pkg-config \
    re2c \
    unzip \
    wget \
    zlib1g-dev; \
locale-gen en_US.UTF-8; \
rm -rf /var/lib/apt/lists/*

# On Apple Silicon the amd64 image runs under Rosetta, where the `locale` binary
# from libc-bin traps with "Unable to open /proc/self/exe". Tests such as
# ext/standard/tests/strings/setlocale_*.phpt shell out to `locale -a` to
# discover the installed locales and see nothing. The i386 build of the same
# binary is not x86-64, so Rosetta never sees it: the kernel hands it to the
# qemu-i386 binfmt registration instead, the same emulator that runs the i386 php
# binary. Install that build first on PATH. libc-bin is not co-installable
# across architectures, hence extracting the single file. Native arm64 builds do
# not go through Rosetta and are left alone.
ARG TARGETARCH
RUN set -eux; \
if [ "${TARGETARCH}" = "amd64" ]; then \
    dpkg --add-architecture i386; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends libc6:i386; \
    cd /tmp; \
    apt-get download libc-bin:i386; \
    dpkg-deb -x libc-bin_*_i386.deb /tmp/libc-bin-i386; \
    install -m 0755 /tmp/libc-bin-i386/usr/bin/locale /usr/local/bin/locale; \
    rm -rf /tmp/libc-bin-i386 /tmp/libc-bin_*_i386.deb /var/lib/apt/lists/*; \
fi

WORKDIR /php-src

CMD ["bash"]
