#!/bin/bash
# Measure click-to-browser latency for a set of URLs.
#
# The wall-clock timestamp Finch writes at the top of its handler is the join
# point: `send` below is taken just before we hand the URL to LaunchServices,
# so (recv - send) is everything that happens before Finch is even running —
# process spawn, LaunchServices lookup, Apple Event dispatch — and the stage
# deltas on the log line are everything after.
set -u
LOG="$HOME/.finch.log"
GAP="${GAP:-3}"
: > "$LOG"

for url in "$@"; do
    send=$(perl -MTime::HiRes=time -e 'printf "%.6f", time')
    open "$url"
    sleep "$GAP"
    line=$(tail -n 1 "$LOG")
    recv=$(echo "$line" | awk '{print $1}')
    pre=$(perl -e "printf \"%.1f\", ($recv - $send) * 1000")
    printf '%-56s pre=%sms %s\n' "${url:0:56}" "$pre" "${line#* }"
done
