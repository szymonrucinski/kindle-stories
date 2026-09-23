#!/bin/sh
# Device side (lives in /mnt/us/llm/neon). usage: bench.sh BIN MODEL [extra args] -- one timed generation under the shared device lock.
# others = CPU% used by everything except our process during the run (from /proc/stat); ~0 means a clean run.
cd /mnt/us/llm
until mkdir /tmp/bench.lock 2>/dev/null; do sleep 5; done
trap 'rmdir /tmp/bench.lock' EXIT
B=$1; M=$2; shift 2
procs=$(ps | grep -E "[s]mol|[r]un" | grep -v "bench.sh" | wc -l)
s0=$(head -1 /proc/stat)
/usr/bin/time -f "TIME %e %U %S" neon/$B $M -z tokenizer.bin -s 42 -n 256 -i "Once upon a time" "$@" 2>/tmp/bench.err >/dev/null
s1=$(head -1 /proc/stat)
others=$(echo "$s0 $s1 $(grep ^TIME /tmp/bench.err)" | awk '{busy=($13+$14+$15+$18+$19)-($2+$3+$4+$7+$8); tot=0; for(i=13;i<=19;i++) tot+=$i; for(i=2;i<=8;i++) tot-=$i; printf "%.0f", (busy-($25+$26)*100)/tot*100}')
echo "$B procs=$procs others=${others}% $(grep -E "achieved|PROF" /tmp/bench.err | tr "\n" " ")"
