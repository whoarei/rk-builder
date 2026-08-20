#!/bin/bash

set -euo pipefail

BUILDER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODE=remote
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild-image)
            MODE=local
            shift
            ;;
        --pull-image)
            shift
            ;;
        --)
            ARGS+=("$@")
            break
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

echo "build.sh is deprecated; use rk-builder.sh or rk-builder-local.sh" >&2

if [[ $MODE == local ]]; then
    exec "$BUILDER_DIR/rk-builder-local.sh" "${ARGS[@]}"
fi

exec "$BUILDER_DIR/rk-builder.sh" "${ARGS[@]}"
