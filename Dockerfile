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
    ccache \
    curl \
    firebird-dev \
    freetds-dev \
    git \
    libargon2-dev \
    libavif-dev \
    libbz2-dev \
    libcurl4-openssl-dev \
    libdb-dev \
    libedit-dev \
    libenchant-2-dev \
    libffi-dev \
    libfreetype6-dev \
    libgdbm-dev \
    libgmp-dev \
    libicu-dev \
    libjpeg-dev \
    libldap-dev \
    liblmdb-dev \
    libonig-dev \
    libpng-dev \
    libpq-dev \
    libreadline-dev \
    libsasl2-dev \
    libsnmp-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    libtidy-dev \
    libtokyocabinet-dev \
    libwebp-dev \
    libxml2-dev \
    libxpm-dev \
    libxslt1-dev \
    libzip-dev \
    locales \
    make \
    pkg-config \
    re2c \
    unixodbc-dev \
    unzip \
    wget \
    zlib1g-dev; \
locale-gen en_US.UTF-8; \
rm -rf /var/lib/apt/lists/*

# Ubuntu's ccache shims cover gcc and g++ but not cc and c++, and PHP's
# configure picks `cc`; without these the compiler cache is silently bypassed.
RUN ln -sf ../../bin/ccache /usr/lib/ccache/cc; ln -sf ../../bin/ccache /usr/lib/ccache/c++

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

# Benchmarking and profiling (bin/bench.sh, PHP_SRC_PROFILE=1): valgrind for
# callgrind/massif, perf, heaptrack, GNU time for peak RSS, and a database for
# the WordPress workload. Only the 64-bit images get them: those are the ones
# that run natively somewhere, and numbers from an emulated container measure
# the emulator. arm32 is always emulated here and would only build slower.
#
# Ubuntu's /usr/bin/perf is a wrapper that looks for the tools matching
# `uname -r`, which is the host's (or Lima VM's) kernel rather than one the
# image could know about, so it refuses to run. perf's user space works across
# kernel versions; put the packaged binary first on PATH instead.
RUN set -eux; \
if [ "${TARGETARCH}" = "amd64" ] || [ "${TARGETARCH}" = "arm64" ]; then \
    apt-get update -y; \
    apt-get install -y --no-install-recommends \
        heaptrack \
        linux-tools-generic \
        mariadb-server \
        time \
        valgrind; \
    ln -sf "$(ls -d /usr/lib/linux-tools/*/perf | sort -V | tail -n1)" /usr/local/bin/perf; \
    rm -rf /var/lib/apt/lists/*; \
fi

# php-src's dba db4 probe (PHP_DBA_DB_CHECK in ext/dba/config.m4) tests for the
# library file at $prefix/$PHP_LIBDIR -- /usr/lib -- and Ubuntu ships Berkeley DB
# at the multiarch path /usr/lib/<triplet>. Only that file test fails; the link
# step itself finds the library via the linker's default search path, so a
# symlink where the probe looks is enough to get --with-db4 detected.
RUN ln -s "/usr/lib/$(gcc -print-multiarch)/libdb.so" /usr/lib/libdb.so

WORKDIR /php-src

CMD ["bash"]
