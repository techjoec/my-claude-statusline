#!/usr/bin/env bash
# uninstall.sh — stop and remove the cc-sysstat collector. Reversible counterpart
# to install.sh. Uses validated absolute paths; never globs.
#
# Leaves ~/.config/cc-sysstat.conf and the statusLine block in
# ~/.claude/settings.json alone. Remove those yourself if you want them gone.
#
# Env: PREFIX (default /usr/local/lib/cc-sysstat) — must match the install.
set -uo pipefail

PREFIX="${PREFIX:-/usr/local/lib/cc-sysstat}"
UNIT_DIR=/etc/systemd/system

sudo systemctl disable --now cc-sysstat.service 2>/dev/null || true

for f in "$UNIT_DIR/cc-sysstat.service" \
         "$PREFIX/collector-loop.sh" \
         "$PREFIX/collector.sh" \
         "$PREFIX/statusline.sh"; do
  [ -n "$f" ] && [ -e "$f" ] && { echo "rm $f"; sudo rm -f "$f"; }
done

# remove the install dir only if it is now empty
[ -d "$PREFIX" ] && sudo rmdir "$PREFIX" 2>/dev/null || true

sudo systemctl daemon-reload

# stale tmpfs output (the status line hides it after 30s anyway)
rm -f "${CC_SYSSTAT_OUT:-/dev/shm/cc-sysstat.json}" \
      "${CC_SYSSTAT_STATE:-/dev/shm/cc-sysstat.state}" 2>/dev/null || true

echo "Uninstalled cc-sysstat collector. Config left at ~/.config/cc-sysstat.conf"
