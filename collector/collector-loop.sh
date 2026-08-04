#!/usr/bin/env bash
# collector-loop.sh — long-lived runner for collector.sh.
#
# One persistent process rather than a systemd timer firing a oneshot: a timer
# logs "Starting/Finished" every tick, which at this cadence floods the journal.
# As a single long-lived service systemd logs it once, at start.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for _c in "${CC_SYSSTAT_CONF:-}" \
          "$HOME/.config/cc-sysstat.conf" \
          /etc/cc-sysstat.conf; do
  # shellcheck source=/dev/null
  [ -n "$_c" ] && [ -r "$_c" ] && { . "$_c"; break; }
done

INTERVAL="${CC_SYSSTAT_INTERVAL:-3}"

# Resolve mountpoints -> whole disks ONCE here, not on every 3s tick: resolution
# shells out to findmnt/lsblk per disk, which is the most expensive thing in the
# whole collector and the answer effectively never changes while mounted.
# Exported so collector.sh skips its own resolution. Re-resolved on restart —
# after changing CC_SYSSTAT_DISKS, restart the service.
export CC_SYSSTAT_DEVS
CC_SYSSTAT_DEVS=$("$HERE/collector.sh" --print-devs 2>/dev/null)

while :; do
  "$HERE/collector.sh"
  sleep "$INTERVAL"
done
