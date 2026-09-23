# Kindle Stories. Binaries are cross-compiled for the Kindle's Cortex-A9 with zig.
# Downloads (zig, llama2.c, llama.cpp, models, font) go to .work/, outputs to build/.

ZIG := .work/zig-x86_64-linux-0.14.1/zig
CC := scripts/zcc
CFLAGS := -O3 -ffast-math -static -include stdint.h
PLUGIN := plugin/kindlestories.koplugin
LUA ?= lua

C_SRC := kernels/run-fast.c kernels/runq-fast.c kernels/exp_check.c kernels/neon_common.h smollm/smol.cpp
SH_SRC := $(wildcard scripts/*.sh kernels/*.sh) scripts/zcc scripts/zcxx
KERNELS := build/run-fast build/runq-fast build/exp_check

.PHONY: all build kernels ref smol test lint fmt fetch deploy deploy-all clean

all: build

build: kernels smol

kernels: $(KERNELS)

# The unmodified llama2.c programs, for speed and output comparisons.
ref: build/run-ref build/runq-ref

smol: build/smol

$(ZIG):
	scripts/fetch.sh zig

build/%: kernels/%.c kernels/neon_common.h | $(ZIG)
	@mkdir -p build
	$(CC) $(CFLAGS) $< -lm -o $@

build/%-ref: | $(ZIG)
	scripts/fetch.sh llama2c
	@mkdir -p build
	$(CC) $(CFLAGS) .work/llama2.c/$*.c -lm -o $@

build/smol: smollm/smol.cpp scripts/build-smol.sh | $(ZIG)
	scripts/build-smol.sh

test:
	cd $(PLUGIN) && $(LUA) test_parse.lua

lint:
	luacheck $(PLUGIN)
	stylua --check $(PLUGIN)
	clang-format --dry-run --Werror $(C_SRC)
	for f in $(SH_SRC); do sh -n $$f || exit 1; done

fmt:
	stylua $(PLUGIN)
	clang-format -i $(C_SRC)

fetch:
	scripts/fetch.sh

# Plugin (and font) only. deploy-all also pushes binaries, tokenizer and models to /mnt/us/llm.
deploy:
	scripts/deploy.sh

deploy-all: build
	scripts/deploy.sh --all

clean:
	rm -rf build
