#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ZRAW_DECODER_LIB="/Users/derekmorrison/projects/storyboardcreativity/zraw-decoder-lib-3e78ca61d288df9fe1704e107820666c828756d8"

echo "=== Building libzraw.a ==="
make -C "$ZRAW_DECODER_LIB" static_lib \
    CC="g++" \
    ARCH="-arch arm64" \
    INCS="-I${ZRAW_DECODER_LIB}/include -I${ZRAW_DECODER_LIB}/src -I/opt/homebrew/opt/openssl@3/include" 2>&1

echo "=== Copying libzraw.a ==="
cp "$ZRAW_DECODER_LIB/build/libzraw.a" Sources/CppBridge/libzraw.a

echo "=== Done ==="
