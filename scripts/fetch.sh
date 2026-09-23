#!/bin/sh
# Download everything that is not kept in git into .work/:
#   zig     zig 0.14.1 (the cross-compiler)
#   llama2c llama2.c at a pinned commit (reference run.c/runq.c, export.py, tokenizer.bin)
#   models  TinyStories 15M (fp32 + int8) and SmolLM2-135M-Instruct Q4_0
#   font    ChicagoFLF.ttf
# usage: scripts/fetch.sh [zig|llama2c|models|font]...   (no argument = all of them)
set -eu
cd "$(dirname "$0")/.."
W=.work
ZIG_VER=0.14.1
LLAMA2C_REV=350e04fe35433e6d2941dce5a1f53308f87058eb
HF=https://huggingface.co

get() { # url dest
	[ -s "$2" ] && return
	mkdir -p "$(dirname "$2")"
	echo "downloading $2"
	curl -fL --retry 3 -o "$2.part" "$1"
	mv "$2.part" "$2"
}

fetch_zig() {
	[ -x "$W/zig-x86_64-linux-$ZIG_VER/zig" ] && return
	mkdir -p "$W"
	echo "downloading zig $ZIG_VER"
	curl -fL --retry 3 "https://ziglang.org/download/$ZIG_VER/zig-x86_64-linux-$ZIG_VER.tar.xz" | tar xJ -C "$W"
}

fetch_llama2c() {
	[ -d "$W/llama2.c" ] || git clone -q https://github.com/karpathy/llama2.c "$W/llama2.c"
	git -C "$W/llama2.c" checkout -q "$LLAMA2C_REV"
}

fetch_models() {
	fetch_llama2c
	M=$W/models
	get "$HF/karpathy/tinyllamas/resolve/main/stories15M.bin" "$M/stories15M.bin"
	get "$HF/karpathy/tinyllamas/resolve/main/stories15M.pt" "$M/stories15M.pt"
	get "$HF/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_0.gguf" \
		"$M/SmolLM2-135M-Instruct-Q4_0.gguf"
	cp "$W/llama2.c/tokenizer.bin" "$M/tokenizer.bin"
	# The int8 checkpoint is not published; llama2.c's exporter makes it (needs torch + numpy).
	if [ ! -s "$M/stories15M_q80.bin" ]; then
		(cd "$W/llama2.c" && python3 export.py ../models/stories15M_q80.bin \
			--version 2 --checkpoint ../models/stories15M.pt) ||
			echo "int8 export failed: pip install torch numpy, then run scripts/fetch.sh models again" >&2
	fi
}

fetch_font() {
	get https://raw.githubusercontent.com/bryanbraun/after-dark-css/gh-pages/fonts/ChicagoFLF.ttf \
		"$W/fonts/ChicagoFLF.ttf"
}

[ $# -gt 0 ] || set -- zig llama2c models font
for what in "$@"; do "fetch_$what"; done
