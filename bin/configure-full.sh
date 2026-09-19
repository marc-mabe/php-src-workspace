#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
    cat <<'EOF'
Usage: configure-full.sh [arm64|amd64|i386] [extra configure args...]

Run ./buildconf and ./configure with a broad set of development extensions.
When run on the host, this automatically executes inside the matching Docker
container.

Configures an out-of-tree build in php-src/build/<arch> (override with
PHP_SRC_BUILD_DIR); run make from there.

The architecture may be omitted, in which case the host's is used. Use -- to
separate this script's arguments from ./configure's.

Examples:
  configure-full.sh
  configure-full.sh arm64
  configure-full.sh i386 -- --enable-calendar
EOF
}

parse_args "$@"
arch="${ARCH}"

configure_delegate_to_container "$(basename "$0")" "${arch}" ${ARGS[@]+"${ARGS[@]}"}

FULL_CONFIGURE_ARGS=(
    --enable-option-checking=fatal
    --prefix=/usr/local
    --enable-debug
    --enable-werror
    --enable-phpdbg
    --enable-fpm
    --with-pdo-mysql=mysqlnd
    --with-mysqli=mysqlnd
    --with-pgsql
    --with-pdo-pgsql
    --with-pdo-sqlite
    --with-pdo-firebird
    --enable-intl
    --without-pear
    --enable-gd
    --with-jpeg
    --with-webp
    --with-freetype
    --with-xpm
    --enable-exif
    --with-zlib
    --enable-shmop
    --enable-soap
    --enable-xmlreader
    --with-xsl
    --enable-sysvsem
    --enable-sysvshm
    --enable-sysvmsg
    --enable-pcntl
    --with-readline
    --enable-mbstring
    --with-curl
    --with-gettext
    --enable-sockets
    --with-bz2
    --with-openssl
    --with-gmp
    --enable-bcmath
    --enable-calendar
    --enable-ftp
    --with-ffi
    --enable-zend-test
    --enable-dl-test=shared
    --with-mhash
    --with-sodium
    --enable-dba
)

# 64-bit only: libzip-dev:i386 is not published for Ubuntu 24.04 multilib.
if ! arch_is_32bit "${arch}"; then
    FULL_CONFIGURE_ARGS+=(--with-zip)
fi

configure_run "${arch}" "${FULL_CONFIGURE_ARGS[@]}" ${ARGS[@]+"${ARGS[@]}"}
