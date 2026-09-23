#!/bin/sh
# Device side (lives in /mnt/us/llm/neon). usage: check.sh REF FAST MODEL -- greedy (-t 0) and default-sampling outputs must match byte-for-byte
cd /mnt/us/llm
until mkdir /tmp/bench.lock 2>/dev/null; do sleep 5; done
trap 'rmdir /tmp/bench.lock' EXIT
for mode in "-t 0" ""; do
  for b in $1 $2; do neon/$b $3 -z tokenizer.bin $mode -s 42 -n 256 -i "Once upon a time" > /tmp/chk_$b.txt 2>/dev/null; done
  cmp -s /tmp/chk_$1.txt /tmp/chk_$2.txt && echo "[${mode:-sampled}] $2 IDENTICAL to $1" || echo "[${mode:-sampled}] $2 DIFFERS from $1"
done
