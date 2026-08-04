#!/usr/bin/env bash
# install.sh — install the cc-sysstat collector as a systemd service.
#
# Copies (does NOT symlink) the collector into PREFIX, so editing your checkout
# afterwards has no effect on the running service until you install again.
#
#   statusline.sh                -> $PREFIX/statusline.sh
#   collector/collector.sh       -> $PREFIX/collector.sh
#   collector/collector-loop.sh  -> $PREFIX/collector-loop.sh
#   collector/cc-sysstat.service -> /etc/systemd/system/cc-sysstat.service
#
# Then daemon-reload + enable --now. Needs sudo for those two destinations only.
#
# Env: PREFIX (default /usr/local/lib/cc-sysstat)
set -uo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Preflight. jq is only used by statusline.sh, not the collector, so a missing
# jq yields a happily-running service and a status line that silently shows
# nothing -- the most confusing possible failure. Fail here instead.
missing=""
for t in jq awk findmnt lsblk nproc systemctl; do
  command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
done
if [ -n "$missing" ]; then
  echo "Missing required tools:$missing" >&2
  echo "On Debian/Ubuntu: sudo apt install jq util-linux coreutils" >&2
  exit 1
fi

PREFIX="${PREFIX:-/usr/local/lib/cc-sysstat}"
UNIT_DIR=/etc/systemd/system
CONF="$HOME/.config/cc-sysstat.conf"

echo "Installing cc-sysstat collector"
echo "  from : $SRC_DIR/collector"
echo "  to   : $PREFIX  (+ service in $UNIT_DIR, running as $USER)"

sudo install -d -m 755 "$PREFIX"
sudo install -m 755 "$SRC_DIR/statusline.sh"               "$PREFIX/statusline.sh"
sudo install -m 755 "$SRC_DIR/collector/collector.sh"      "$PREFIX/collector.sh"
sudo install -m 755 "$SRC_DIR/collector/collector-loop.sh" "$PREFIX/collector-loop.sh"

# Fill the unit's placeholders with this install's prefix and user.
sed -e "s|__PREFIX__|$PREFIX|g" -e "s|__USER__|$USER|g" \
    "$SRC_DIR/collector/cc-sysstat.service" |
  sudo install -m 644 /dev/stdin "$UNIT_DIR/cc-sysstat.service"

# Seed a config on first install only — never clobber one you have edited.
if [ ! -e "$CONF" ]; then
  install -d -m 755 "$(dirname "$CONF")"
  install -m 644 "$SRC_DIR/cc-sysstat.conf.example" "$CONF"
  echo "  conf : $CONF  (seeded from example — edit CC_SYSSTAT_DISKS)"
else
  echo "  conf : $CONF  (already exists, left alone)"
fi

sudo systemctl daemon-reload
sudo systemctl enable cc-sysstat.service >/dev/null 2>&1 || true
sudo systemctl restart cc-sysstat.service

echo
systemctl status cc-sysstat.service --no-pager 2>/dev/null | sed -n '1,4p'
echo
echo "JSON updates every ~3s at ${CC_SYSSTAT_OUT:-/dev/shm/cc-sysstat.json}"
echo
echo "Now add this to ~/.claude/settings.json (note: the INSTALLED path, so"
echo "nothing depends on this checkout still existing):"
echo
echo '  "statusLine": {'
echo '    "type": "command",'
echo "    \"command\": \"bash $PREFIX/statusline.sh\","
echo '    "refreshInterval": 30'
echo '  }'
