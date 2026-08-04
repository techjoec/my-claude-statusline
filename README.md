# my-claude-statusline

A single-line [Claude Code](https://claude.com/claude-code) status line showing
working directory, model, and live system load — plus the small systemd
collector that feeds it.

```
~/repos/my-project │ Opus 5 (high) │ Cache: 47m │ Claudes: 3 │ CPU:  6% │ RAM: 27% │ Disk: [ /: 0% /d: 4% /stg: 96% ]
```

## Why a collector

CPU and disk load are rates, and `/proc` only gives you counters — you need two
samples and the gap between them. Measuring that inside the status line leaves
two options, and both are bad: block while you take the second sample (`iostat
1 2` sleeps a full second, every repaint) or keep per-session state that every
open session duplicates. Status lines redraw constantly and you usually have
several sessions open, so this is the hot path, not a corner.

So sampling is split from rendering. One systemd service samples `/proc` every
3s into a JSON file on tmpfs. Each status-line run just reads that file — no
tools spawned, no deltas computed, nothing to wait for. Twenty sessions still
means one sampler, and its cost does not grow as you open more.

Two consequences worth knowing:

- **Freshness and smoothness are separate knobs.** The tick (default 3s) sets
  how current the numbers are; the averaging window (default 15s) sets how much
  they jitter. Each sample carries a real timestamp, so a late or missed tick
  widens the span rather than corrupting the rate.
- **Metrics can be absent.** If the collector is not running, or its data is
  stale, the status line shows just cwd and model rather than stale numbers.

Metrics come from `/proc` only — no `iostat`, no `sar`, no dependency beyond
coreutils, `jq`, and `util-linux`.

## Install

Requires: `bash`, `jq`, `awk`, `findmnt`/`lsblk` (util-linux), systemd, Linux.

```sh
git clone https://github.com/techjoec/my-claude-statusline
cd my-claude-statusline
./install.sh          # sudo for /usr/local/lib + the unit file only
```

Edit `~/.config/cc-sysstat.conf` (seeded on first install) to pick your disks,
then `systemctl restart cc-sysstat`. Check it:

```sh
cat /dev/shm/cc-sysstat.json
```

Then point Claude Code at `statusline.sh` in `~/.claude/settings.json`.
`install.sh` copies it to `$PREFIX` and prints this block with the path filled
in:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /usr/local/lib/cc-sysstat/statusline.sh",
    "refreshInterval": 30
  }
}
```

Any path works — a checkout, `~/.claude/`, wherever you keep scripts.
`refreshInterval` controls idle repaints only; the line always repaints on
activity. The `Cache` countdown depends on it — without idle repaints the
count freezes at its last event-driven value.

`./uninstall.sh` reverses the install. It leaves your config and the
`statusLine` block alone.

## Configuration

All knobs live in `~/.config/cc-sysstat.conf` (or `/etc/cc-sysstat.conf`); see
[`cc-sysstat.conf.example`](cc-sysstat.conf.example) for the annotated list. The
one you must set is which disks to watch:

```sh
CC_SYSSTAT_DISKS="/:/ /data:/d /staging:/stg"
```

Entries are **mountpoints**, optionally `mountpoint:label`. Each is resolved to
the whole physical disk backing it — through partitions and LVM/dm — because
`io_ticks` is only meaningful per physical device. Unresolvable mountpoints
(NFS, tmpfs, ZFS) are skipped. `CC_SYSSTAT_DISKS=""` drops the disk block
entirely and you get just CPU/RAM/Claudes.

The status line renders whatever the collector emits, in config order, so
nothing needs configuring twice.

Tick rate (`CC_SYSSTAT_INTERVAL`, default 3s) and averaging window
(`CC_SYSSTAT_WINDOW_MS`, default 15s) are independent: the tick is freshness,
the window is smoothness.

## Output format

`/dev/shm/cc-sysstat.json`, rewritten every tick:

```json
{"ts":1754160000123,"ready":true,"window_ms":15020,"cpu":6,
 "mem":27,"cores":8,"claude":3,"disk":{"/":0,"/d":4,"/stg":96}}
```

| Field | Meaning |
|---|---|
| `ts` | epoch ms of this sample; consumers should ignore data older than ~30s |
| `ready` | `false` while warming up — no in-window baseline yet, so no rates |
| `window_ms` | actual span the rates were computed over (not the configured target) |
| `cpu` | `/proc/stat` compute %, **excluding iowait** — an honest "CPU busy", normalized so 100% = every core saturated |
| `mem` | used % from `MemTotal`/`MemAvailable` |
| `cores` | `nproc` |
| `claude` | host `claude` processes (see below) |
| `disk` | per-disk `io_ticks` %util, keyed by your configured labels |

`cpu` excludes iowait, so it reads as time actually computing rather than time
blocked on I/O. Disk pressure has its own field.

`claude` counts host-side sessions only — cgroups belonging to lxc/incus
payloads, docker/k8s pods and `machine.slice` guests are filtered out, since
containers share the host `/proc`.

## Reading the line

- **Model** is colored by family: Opus azure, Sonnet aqua, Haiku yellow, Fable
  purple.
- **Cache** counts down this session's prompt-cache TTL — the time left before
  the Anthropic prompt cache holding your conversation expires. Every API call
  refreshes it; the TTL in play (5m or 1h) is read from the session transcript,
  not assumed. Green while warm, orange in the last fifth — the window where
  "reply now or the next turn pays a full cache re-write" is live — and grey
  `cold` once expired. Cold is a resting state, not an error: the next message
  simply rebuilds the cache at cache-write cost and latency. The segment is
  omitted when there is nothing defensible to show (no transcript yet, or no
  API turn found in the tail that is read).
- **Load values** are grey at 0, green below 50%, orange 50–75%, red 76%+. Only
  the number is colored; labels stay violet.
- **Percentages display-cap at 99%** — a pegged metric reads `99%` in red rather
  than `100%`. The color is the alarm, and it keeps the line from shifting width
  at the worst possible moment.
- **The line is width-stable.** Fields are padded to their typical width, so
  numbers changing under normal load do not make the whole line jump around.

## Notes

- Linux only. It reads `/proc/stat`, `/proc/meminfo`, and `/proc/diskstats`
  directly, and installs a systemd unit.
- The service runs as your user at `Nice=15` and idle I/O priority. Do not add
  `ProtectSystem=strict` or `PrivateTmp` to the unit — both make `/dev/shm`
  read-only or private, which silently breaks the JSON write and leaves you with
  a healthy-looking service and a status line that never shows metrics.

## License

MIT — see [LICENSE](LICENSE). Use it, fork it, take pieces of it, no attribution
needed beyond the license text.

This is a personal tool published in case it is useful. It is not a product:
there is no support, no roadmap, and no commitment to respond to issues or pull
requests. Fork freely.
