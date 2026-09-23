#!/bin/sh
# Copy Kindle Stories to a jailbroken Kindle running KOReader, over SSH.
# usage: scripts/deploy.sh [--all] [--restart]
#   (default)  plugin + font
#   --all      also binaries from build/, tokenizer and models from .work/models, into /mnt/us/llm
#   --restart  restart KOReader afterwards so the plugin is (re)loaded
# env: KINDLE=root@<ip> (default: KOReader's USB network address)
#      KINDLE_PASSWORD=... to log in with sshpass (may be empty: KOReader's SSH server allows that)
set -eu
cd "$(dirname "$0")/.."
KINDLE=${KINDLE:-root@192.168.15.244}
KO=/mnt/us/koreader
LLM=/mnt/us/llm

kssh() {
	if [ -n "${KINDLE_PASSWORD+set}" ]; then
		sshpass -p "$KINDLE_PASSWORD" ssh "$KINDLE" "$@"
	else
		ssh "$KINDLE" "$@"
	fi
}
# dropbear has no sftp, so files go through cat/tar.
put() { kssh "cat > '$2' && chmod +x '$2'" <"$1"; } # local remote

all=0 restart=0
for arg in "$@"; do
	case $arg in
	--all) all=1 ;;
	--restart) restart=1 ;;
	*) echo "unknown option: $arg" >&2 && exit 2 ;;
	esac
done

echo "plugin -> $KO/plugins/kindlestories.koplugin"
# The plugin used to be called tinystories.koplugin; two copies would both load.
kssh "rm -rf $KO/plugins/tinystories.koplugin $KO/plugins/kindlestories.koplugin && mkdir -p $KO/plugins/kindlestories.koplugin"
tar cf - -C plugin/kindlestories.koplugin _meta.lua main.lua parse.lua |
	kssh "tar xf - -C $KO/plugins/kindlestories.koplugin"

[ -s .work/fonts/ChicagoFLF.ttf ] || scripts/fetch.sh font
put .work/fonts/ChicagoFLF.ttf "$KO/fonts/ChicagoFLF.ttf"

if [ $all = 1 ]; then
	echo "binaries and models -> $LLM"
	kssh "mkdir -p $LLM/neon $LLM/smollm"
	put build/runq-fast "$LLM/runq-fast"
	put build/smol "$LLM/smollm/smol"
	for f in build/run-fast build/runq-fast build/run-ref build/runq-ref build/exp_check kernels/bench.sh kernels/check.sh; do
		[ -e "$f" ] && put "$f" "$LLM/neon/$(basename "$f")"
	done
	for f in tokenizer.bin stories15M.bin stories15M_q80.bin; do
		[ -e ".work/models/$f" ] && put ".work/models/$f" "$LLM/$f"
	done
	put .work/models/SmolLM2-135M-Instruct-Q4_0.gguf "$LLM/smollm/SmolLM2-135M-Instruct-Q4_0.gguf"
fi

if [ $restart = 1 ]; then
	echo "restarting KOReader"
	# Bracketed patterns so pkill/grep don't match this very ssh command line.
	kssh 'pkill -f "[r]eader.lua"; for i in $(seq 30); do ps | grep -q "[k]oreader.sh" || break; sleep 1; done
		cd /mnt/us/koreader && (setsid nohup ./koreader.sh --kual >/tmp/ko.log 2>&1 &)'
fi
echo done
