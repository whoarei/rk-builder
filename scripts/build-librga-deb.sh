#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILDER_DIR=$(cd "$SCRIPT_DIR/.." && pwd)

LIBRGA_VERSION=${LIBRGA_VERSION:-1.10.6}
LIBRGA_COMMIT=${LIBRGA_COMMIT:-2b32edcb97b601b25683e2941d888c8515da6d55}
LIBRGA_REPOSITORY=${LIBRGA_REPOSITORY:-https://github.com/airockchip/librga.git}
PACKAGING_DIR=${PACKAGING_DIR:-"$BUILDER_DIR/librga"}
OUT_DIR=${OUT_DIR:-"$BUILDER_DIR/dist"}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SOURCE_DIR="$WORK_DIR/librga"
PACKAGE_ROOT="$WORK_DIR/package"
PACKAGE_FILE="$OUT_DIR/librga-dev_${LIBRGA_VERSION}_arm64.deb"

git init --quiet "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$LIBRGA_REPOSITORY"
git -C "$SOURCE_DIR" fetch --quiet --depth 1 origin "$LIBRGA_COMMIT"
git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD

if [[ $(git -C "$SOURCE_DIR" rev-parse HEAD) != "$LIBRGA_COMMIT" ]]; then
    echo "librga commit verification failed" >&2
    exit 1
fi

SOURCE_DATE_EPOCH=$(git -C "$SOURCE_DIR" show -s --format=%ct HEAD)
export SOURCE_DATE_EPOCH

mkdir -p \
    "$PACKAGE_ROOT/DEBIAN" \
    "$PACKAGE_ROOT/usr/include/rga" \
    "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig" \
    "$PACKAGE_ROOT/usr/share/doc/librga-dev" \
    "$OUT_DIR"

cp -a "$SOURCE_DIR/include/." "$PACKAGE_ROOT/usr/include/rga/"
install -m 0644 \
    "$SOURCE_DIR/libs/Linux/gcc-aarch64/librga.so" \
    "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/librga.so"
install -m 0644 "$SOURCE_DIR/COPYING" "$PACKAGE_ROOT/usr/share/doc/librga-dev/copyright"

sed "s/@VERSION@/$LIBRGA_VERSION/g" \
    "$PACKAGING_DIR/control.in" > "$PACKAGE_ROOT/DEBIAN/control"
sed "s/@VERSION@/$LIBRGA_VERSION/g" \
    "$PACKAGING_DIR/librga.pc.in" \
    > "$PACKAGE_ROOT/usr/lib/aarch64-linux-gnu/pkgconfig/librga.pc"

find "$PACKAGE_ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group --build "$PACKAGE_ROOT" "$PACKAGE_FILE"
(
    cd "$OUT_DIR"
    sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$PACKAGE_FILE").sha256"
)

echo "Created $PACKAGE_FILE"
