#!/usr/bin/env bash
# statusline.sh — Claude Code status line (single line)
#
# cwd + model (effort) + system metrics from the cc-sysstat collector's tmpfs
# JSON. No tools/deltas are computed here — the collector does all sampling and
# every session just reads /dev/shm/cc-sysstat.json. That is the whole point:
# with N sessions open you get one sampler, not N.
#
# Layout: cwd │ model (effort) │ Claudes: N │ CPU │ RAM │ Disk: [ per-disk %util ]
#
# The disk block is driven entirely by the collector's config — whatever keys
# it emits get rendered, in order. No disks configured, no disk block.

input=$(cat)

# This runs on every repaint of every session, so the cost is dominated by
# process startup, not by the work itself -- reading the JSON is trivial next to
# launching a jq to parse it. Hence a single jq for everything: session fields
# and the collector file together, with the context-window strip done inside it
# rather than by a separate sed.
SYS_JSON="${CC_SYSSTAT_OUT:-/dev/shm/cc-sysstat.json}"
STALE_MS="${CC_STATUSLINE_STALE_MS:-30000}"

# Seconds resolution is plenty for a 30s staleness test, and EPOCHSECONDS is a
# bash builtin -- `date +%s%3N` would be another fork for precision nothing uses.
now_ms=$(( EPOCHSECONDS * 1000 ))

# --slurpfile tolerates a missing file only if we hand it one, so fall back to
# /dev/null, which slurps to [] and reads as "no metrics".
[ -r "$SYS_JSON" ] || SYS_JSON=/dev/null

# Output: line 1 = cwd/model/effort, line 2 = ok/cpu/mem/claudes,
# lines 3+ = one "label<TAB>value" per disk, in collector emit order.
JQ_PROG='
  [ (.cwd // .workspace.current_dir // ""),
    ((.model.display_name // "") | sub(" *\\([0-9]+[KMk]( context)?\\)$"; "")),
    (.effort.level // "") ] | @tsv,
  ( ($sys[0] // {}) as $s
    | if ($s.ready == true) and (($now - ($s.ts // 0)) < $stale)
      then ([1, $s.cpu, $s.mem, ($s.claude // 0)] | @tsv),
           (($s.disk // {}) | to_entries[] | [.key, .value] | @tsv)
      else ([0,0,0,0] | @tsv) end )'

parse() {
  printf '%s' "$input" | jq -r --slurpfile sys "$1" \
    --argjson now "$now_ms" --argjson stale "$STALE_MS" "$JQ_PROG" 2>/dev/null
}

mapfile -t L < <(parse "$SYS_JSON")

# Folding the collector file into the same jq call means a corrupt or
# half-written JSON would otherwise take the whole line down -- cwd and model
# included -- because jq fails as a unit. Retry without it so a bad collector
# costs you the metrics, never the line. Only pays the extra jq when broken.
if [ "${#L[@]}" -eq 0 ] && [ "$SYS_JSON" != /dev/null ]; then
  mapfile -t L < <(parse /dev/null)
fi

IFS=$'\t' read -r cwd model effort <<<"${L[0]:-}"
[ -z "$cwd" ] && cwd=$PWD

# Colors: cwd tan, effort magenta-pink, labels violet, separators/idle grey.
# Three tiers of chrome: group labels (violet) > disk sub-labels (steel blue) >
# structure — separators and brackets (grey/slate).
C_CWD=$'\e[01;38;5;180m'     # tan: warm, so it stays clear of the cool model
                             # colors below (Opus azure especially)
C_EFFORT=$'\e[01;38;5;213m'
C_LABEL=$'\e[01;38;5;141m'   # light violet labels; distinct from threshold colors
C_SEP=$'\e[00;38;5;244m'     # dim grey group separators
C_ZERO=$'\e[00;38;5;244m'    # idle (0%) values recede instead of glowing green
C_BRK=$'\e[00;38;5;60m'      # disk brackets: dark slate, structure only
C_DISK=$'\e[00;38;5;110m'    # disk sub-labels: steel blue, own zone under Disk:
RST=$'\e[00m'

# Per-model color so the family is identifiable at a glance.
model_color() {
  case "$1" in
    *[Oo]pus*)   printf '\e[01;38;5;39m'  ;;  # azure
    *[Ff]able*)  printf '\e[01;38;5;129m' ;;  # purple
    *[Ss]onnet*) printf '\e[01;38;5;51m'  ;;  # aqua
    *[Hh]aiku*)  printf '\e[01;38;5;226m' ;;  # yellow
    *)           printf '\e[01;38;5;44m'  ;;  # unrecognized model: cyan
  esac
}

# Threshold color for a 0-100 load value: grey 0, green 1-49, orange 50-75, red 76+.
sys_color() {
  if   [ "$1" -le 0  ]; then printf '%s' "$C_ZERO"      # idle
  elif [ "$1" -ge 76 ]; then printf '\e[01;38;5;196m'   # red
  elif [ "$1" -ge 50 ]; then printf '\e[01;38;5;208m'   # orange
  else                       printf '\e[01;38;5;78m'     # green
  fi
}

# Same palette keyed on the host claude-session count: 1-3 green, 4-5 orange, 6+ red.
cc_color() {
  if   [ "$1" -ge 6 ]; then printf '\e[01;38;5;196m'    # red
  elif [ "$1" -ge 4 ]; then printf '\e[01;38;5;208m'    # orange
  else                      printf '\e[01;38;5;78m'      # green
  fi
}

sep=" ${C_SEP}│${RST} "      # between groups; disks inside the bracket are space-separated

# model in its family color; effort (when present) in its own color inside parens
seg="$(model_color "$model")${model}${RST}"
[ -n "$effort" ] && seg="${seg} ${C_EFFORT}(${effort})${RST}"

# --- System metrics (already parsed above, in the same jq pass) ---
metrics=""
IFS=$'\t' read -r ok cpu mem cc <<<"${L[1]:-0}"
if [ "${ok:-0}" = "1" ]; then
    # pair <label> <text> <value-color> <min-width> [label-color]
    # Widths are the TYPICAL value's width, not the widest possible one: at
    # everyday readings nothing pads and the line is tight. Only a wider value
    # (a disk in double digits) pushes a single char. Any slack goes in FRONT of
    # the label, never after the colon, so "Label: value" always stays tight.
    pair() { p=$(( $4 - ${#2} )); [ "$p" -lt 0 ] && p=0
             printf '%*s%s%s%s %s%s%s' "$p" "" \
                    "${5:-$C_LABEL}" "$1" "$RST" "$3" "$2" "$RST"; }
    # Every percentage is display-capped at 99% so no field ever needs a 4th
    # char. A pegged metric reads "99%" in red — the color is the alarm, and the
    # last percent doesn't change anything you'd do about it.
    # CPU keeps a 3-wide field: it dips under 10% often enough that the 9->10
    # crossing would shift the line on every other repaint. RAM sits in the
    # double digits permanently, so it gets 2 and in practice never pads.
    val()  { c=$(sys_color "$2"); [ "$2" -gt 99 ] && set -- "$1" 99
             pair "$1" "$2%" "$c" "${4:-3}"; }
    ram()  { val "$1" "$2" "" 2; }
    dsk()  { c=$(sys_color "$2"); [ "$2" -gt 99 ] && set -- "$1" 99
             pair "$1" "$2%" "$c" 2 "$C_DISK"; }
    cnt()  { pair "$1" "$2"  "$(cc_color  "$2")" 1; }

    metrics="$(cnt 'Claudes:' "$cc")${sep}"
    metrics="${metrics}$(val 'CPU:' "$cpu")${sep}$(ram 'RAM:' "$mem")"

    # Disks are lines 3+ of the jq output. Iterating the array in-shell keeps
    # this fork-free, which matters on a path that runs every repaint.
    disks=""
    for ((i = 2; i < ${#L[@]}; i++)); do
      IFS=$'\t' read -r dlabel dval <<<"${L[i]}"
      [ -z "$dlabel" ] && continue
      disks="${disks} $(dsk "${dlabel}:" "$dval")"
    done

    if [ -n "$disks" ]; then
      metrics="${metrics}${sep}${C_LABEL}Disk:${RST} ${C_BRK}[${RST}"
      metrics="${metrics}${disks} ${C_BRK}]${RST}"
    fi
fi

printf "${C_CWD}%s${RST}%s%s" "$cwd" "$sep" "$seg"
[ -n "$metrics" ] && printf "%s%s" "$sep" "$metrics"
