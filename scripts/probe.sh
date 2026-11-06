#!/bin/bash
# Sends a sweep of READ-ONLY queries to the headphones and prints every reply.
# Run it twice in different conditions (e.g. headphones on vs off your head)
# and diff the output to find which value changed.
#
# Usage: scripts/probe.sh <label>     → writes build/probe-<label>.txt
# Needs Hush running with debug control (scripts/build-app.sh --debug).
#
# Safety: in Sony's protocol, codes ending in 0 ask "what can you do" and
# codes ending in 6 read a value. Only those are sent. Codes ending in 8
# change settings and are never sent, nor anything in the 0x0_ (init) and
# 0x2_ (power off / reboot) families.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="${1:?usage: scripts/probe.sh <label>}"
OUT="build/probe-$LABEL.txt"
CTL=build/hushctl
LOG="$HOME/Library/Logs/Hush.log"

queries=()
# Value reads (x6) across families, with inquired types 00…0F.
for family in 4 5 6 8 9 A B C D E F; do
    for sub in 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F; do
        queries+=("${family}6 $sub")
    done
done
# Capability reads (x0) with the usual trailing 00.
for family in 4 5 6 8 9 A B C E F; do
    for sub in 00 01 02 03 04 05; do
        queries+=("${family}0 $sub 00")
    done
done
# General-setting slots, and the battery/status family read.
for slot in D1 D2 D3 D4 D5 D6; do queries+=("D0 $slot 00" "D6 $slot"); done
queries+=("10 00" "10 01" "10 02" "12 00" "12 01" "12 02")

for q in "${queries[@]}"; do
    case "${q:0:2}" in
        ?8|0?|2?) echo "refusing non-read query $q" >&2; exit 1 ;;
    esac
done

start=$(wc -l < "$LOG")
echo "Sending ${#queries[@]} read-only queries…"
for q in "${queries[@]}"; do
    $CTL send $q > /dev/null
done
sleep 4  # let the queue drain and replies arrive

# Keep only replies from the device, without timestamps or sequence numbers,
# so two runs diff cleanly.
tail -n +"$((start + 1))" "$LOG" \
    | grep "\[rx\] command" \
    | sed -E 's/^.*\[rx\] (command[12]) seq [01] /\1 /' \
    | sort -u > "$OUT"

echo "$(wc -l < "$OUT") distinct replies → $OUT"
