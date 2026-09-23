#!/bin/sh
# Host side: run kernels/bench.sh on the Kindle until a run is not disturbed by other processes
# (<= 4% CPU used by others and no other model process), at most 6 tries.
# usage: scripts/bench.sh BIN MODEL [args]   e.g. scripts/bench.sh runq-fast stories15M_q80.bin
# env: KINDLE, KINDLE_PASSWORD as in deploy.sh. Needs `scripts/deploy.sh --all` first.
KINDLE=${KINDLE:-root@192.168.15.244}
kssh() {
	if [ -n "${KINDLE_PASSWORD+set}" ]; then
		sshpass -p "$KINDLE_PASSWORD" ssh "$KINDLE" "$@"
	else
		ssh "$KINDLE" "$@"
	fi
}
for try in 1 2 3 4 5 6; do
	out=$(kssh "sh /mnt/us/llm/neon/bench.sh $*")
	oth=$(echo "$out" | sed -n 's/.*others=\(-*[0-9]*\)%.*/\1/p')
	pr=$(echo "$out" | sed -n 's/.*procs=\([0-9]*\).*/\1/p')
	[ "${oth:-99}" -le 4 ] && [ "${pr:-1}" = 0 ] && {
		echo "$out"
		exit 0
	}
	echo "  (discarded, contended: $out)" >&2
	sleep 30
done
echo "GAVE UP: $out"
exit 1
