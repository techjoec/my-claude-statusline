#!/usr/bin/env bash
# collector.sh — sample system stats to a tmpfs JSON for Claude Code status lines.
#
# /proc-only (no iostat/sar), sliding-window via a ring buffer, no sleep/block.
# Run in a loop by collector-loop.sh (a long-lived systemd service). ALL status-
# line sessions just read the output JSON — they never run tools or compute
# deltas themselves. One sampler serves N sessions.
#
#   state : /dev/shm/cc-sysstat.state   (last few raw samples, ts-keyed)
#   out   : /dev/shm/cc-sysstat.json    (computed metrics, world-readable)
#
# Metrics (all CPU %s normalized to all cores; 100% = every core fully busy):
#   cpu    = /proc/stat compute, EXCLUDING iowait (honest "CPU busy")
#   mem    = /proc/meminfo used %
#   disk   = /proc/diskstats io_ticks %util per whole-disk (rolls up vols/parts)
#   claude = count of host `claude` processes, excluding containers/VMs

# ---- config -----------------------------------------------------------------
# First readable file wins. See cc-sysstat.conf.example for the knobs.
for _c in "${CC_SYSSTAT_CONF:-}" \
          "$HOME/.config/cc-sysstat.conf" \
          /etc/cc-sysstat.conf; do
  # shellcheck source=/dev/null
  [ -n "$_c" ] && [ -r "$_c" ] && { . "$_c"; break; }
done

WINDOW_MS="${CC_SYSSTAT_WINDOW_MS:-15000}"   # sliding-average window
STATE="${CC_SYSSTAT_STATE:-/dev/shm/cc-sysstat.state}"
OUT="${CC_SYSSTAT_OUT:-/dev/shm/cc-sysstat.json}"
DISKS="${CC_SYSSTAT_DISKS-/}"                # "" = no disk metrics at all
NCPU=$(nproc)

# ---- mountpoint -> whole-disk resolution ------------------------------------
# Entries are "mountpoint" or "mountpoint:label". A mountpoint is resolved to
# the *whole disk* backing it, walking up through partitions and LVM/dm layers,
# because /proc/diskstats io_ticks is only meaningful per physical device.
#
# Resolution shells out, so collector-loop.sh does it once at startup and
# exports CC_SYSSTAT_DEVS; we only resolve here when running standalone.
resolve_disks() {
  local entry mp label src dev out=""
  for entry in $DISKS; do
    mp="${entry%%:*}"
    label="${entry#*:}"; [ "$label" = "$entry" ] && label="$mp"
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null) || continue
    [ -z "$src" ] && continue
    dev=$(lsblk --inverse --list -no NAME,TYPE "$src" 2>/dev/null |
          awk '$2=="disk"{n=$1} END{print n}')
    [ -z "$dev" ] && continue          # unresolvable (network fs, zfs, tmpfs)
    out="${out}${out:+ }${label}:${dev}"
  done
  printf '%s' "$out"
}

# Set-but-empty means "resolved, no disks" — only resolve when wholly unset.
if [ -z "${CC_SYSSTAT_DEVS+x}" ]; then
  CC_SYSSTAT_DEVS=$(resolve_disks)
fi

# collector-loop.sh calls this once at startup to hoist resolution out of the tick.
if [ "${1:-}" = "--print-devs" ]; then
  printf '%s\n' "$CC_SYSSTAT_DEVS"
  exit 0
fi

# Split into parallel label/device lists, preserving config order.
LABELS=""; DEVS=""; NDISK=0
for _pair in $CC_SYSSTAT_DEVS; do
  LABELS="${LABELS}${LABELS:+ }${_pair%%:*}"
  DEVS="${DEVS}${DEVS:+ }${_pair##*:}"
  NDISK=$((NDISK + 1))
done

now_ms=$(date +%s%3N)

# ---- samples ----------------------------------------------------------------
# /proc/stat aggregate line: cpu user nice system idle iowait irq softirq steal ...
read -r _ u n s idle iow irq sirq steal _ < /proc/stat
total=$((u + n + s + idle + iow + irq + sirq + steal))
compute=$((u + n + s + irq + sirq + steal))           # excludes idle AND iowait

# /proc/diskstats io_ticks (field 13) for the configured devices, in config
# order. Missing devices read 0 rather than shifting every later field.
ticks=""
if [ "$NDISK" -gt 0 ]; then
  ticks=$(awk -v want="$DEVS" '
    BEGIN{ n = split(want, W, " ") }
    { for (i = 1; i <= n; i++) if ($3 == W[i]) T[i] = $13 }
    END{ for (i = 1; i <= n; i++) printf "%s%d", (i > 1 ? " " : ""), T[i] + 0 }
  ' /proc/diskstats)
fi

# mem used %
mem=$(awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{if(t>0)printf "%d",(t-a)*100/t+0.5}' /proc/meminfo)

# host `claude` process count. Container/VM guests share the host /proc, so drop
# anything whose cgroup is an lxc/incus payload, a docker/k8s pod, or a
# machine.slice guest — only true host-side sessions count toward the total.
cc_count=0
for _p in $(pgrep -x claude 2>/dev/null); do
  _cg=$(cat "/proc/$_p/cgroup" 2>/dev/null) || continue
  case "$_cg" in
    *lxc.payload*|*lxc.monitor*|*docker*|*machine.slice*|*kubepods*) continue ;;
  esac
  cc_count=$((cc_count + 1))
done

cur="$now_ms $total $compute${ticks:+ $ticks}"

# ---- sliding window ---------------------------------------------------------
# Baseline = earliest prior sample still inside the window. Using real timestamps
# means a late/skipped tick just widens the span; it never corrupts the rate.
# A sample whose field count no longer matches (config changed) is discarded.
want_fields=$((3 + NDISK))
oldest=""
newstate=""
if [ -r "$STATE" ]; then
  while read -r ts rest; do
    [ -z "$ts" ] && continue
    case "$ts" in *[!0-9]*) continue;; esac
    set -- $rest
    [ $(($# + 1)) -ne "$want_fields" ] && continue
    age=$((now_ms - ts))
    if [ "$age" -ge 0 ] && [ "$age" -le "$WINDOW_MS" ]; then
      [ -z "$oldest" ] && oldest="$ts $rest"
      newstate="${newstate}${ts} ${rest}"$'\n'
    fi
  done < "$STATE"
fi

# persist trimmed in-window samples + the current one
{ printf '%s' "$newstate"; printf '%s\n' "$cur"; } > "$STATE"

# ---- emit -------------------------------------------------------------------
awk -v o="$oldest" -v c="$cur" -v mem="$mem" -v cores="$NCPU" -v cc="$cc_count" \
    -v labels="$LABELS" -v ndisk="$NDISK" -v want="$want_fields" '
function rnd(x){ return int(x + 0.5) }
function cap(x){ if (x > 100) return 100; if (x < 0) return 0; return x }
BEGIN{
  split(c, C, " ");
  no = split(o, O, " ");
  if (no < want) {                    # warming up: no baseline yet
    printf "{\"ts\":%d,\"ready\":false,\"mem\":%d,\"cores\":%d,\"claude\":%d}\n", C[1], mem, cores, cc;
    exit;
  }
  dt_ms = C[1] - O[1];
  dtot  = C[2] - O[2]; dcomp = C[3] - O[3];
  cpu   = (dtot > 0) ? 100 * dcomp / dtot : 0;
  split(labels, NM, " ");
  disk = "";
  for (k = 1; k <= ndisk; k++) {
    i = k + 3;                        # C[4..] = io_ticks, in config order
    util = (dt_ms > 0) ? 100 * (C[i] - O[i]) / dt_ms : 0;
    disk = disk sprintf("%s\"%s\":%d", (k > 1 ? "," : ""), NM[k], rnd(cap(util)));
  }
  printf "{\"ts\":%d,\"ready\":true,\"window_ms\":%d,\"cpu\":%d,\"mem\":%d,\"cores\":%d,\"claude\":%d,\"disk\":{%s}}\n",
         C[1], dt_ms, rnd(cap(cpu)), mem, cores, cc, disk;
}' > "$OUT.tmp"

# Publish atomically. Writing straight to $OUT truncates it first, so a status
# line reading at that moment gets a half-written file and fails to parse --
# rare, but every session reads this on every repaint, so "rare" still happens.
# rename(2) within the same tmpfs is atomic: readers see old or new, never torn.
chmod 644 "$OUT.tmp" 2>/dev/null
mv -f "$OUT.tmp" "$OUT"
