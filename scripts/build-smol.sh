#!/bin/sh
# Cross-compile llama.cpp (pinned, not vendored) as static libraries, then link the
# SmolLM2 wrapper against them. Output: build/smol, a static armv7 binary.
set -eu
cd "$(dirname "$0")/.."
REV=42916d83f4a225e56709f873aa8050ac11f5b6a4
SRC=.work/llama.cpp
OUT=.work/llama-build-arm

if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$REV" ]; then
	[ -d "$SRC/.git" ] || git init -q "$SRC"
	git -C "$SRC" fetch -q --depth 1 https://github.com/ggml-org/llama.cpp "$REV"
	git -C "$SRC" checkout -q FETCH_HEAD
fi

cmake -S "$SRC" -B "$OUT" -G Ninja -Wno-dev \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=armv7l \
	-DCMAKE_C_COMPILER="$PWD/scripts/zcc" -DCMAKE_CXX_COMPILER="$PWD/scripts/zcxx" \
	-DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_LLAMAFILE=OFF \
	-DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TESTS=OFF \
	-DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF >/dev/null
cmake --build "$OUT" --target llama

mkdir -p build
scripts/zcxx -O3 -static -s smollm/smol.cpp -o build/smol \
	-I"$SRC/include" -I"$SRC/ggml/include" \
	"$OUT/src/libllama.a" "$OUT/ggml/src/libggml.a" "$OUT/ggml/src/libggml-cpu.a" "$OUT/ggml/src/libggml-base.a"
echo "built build/smol"
