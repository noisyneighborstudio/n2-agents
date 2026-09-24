# Product demo clips — starter set

Silent 1080p MP4s (h264, 7s each, no audio) of the `agents` CLI.

| Clip | Command(s) | Shows |
|---|---|---|
| `01-list.mp4` | `agents list` | Profiles × labs matrix, active profile |
| `02-vendors.mp4` | `agents vendors` | Lab isolation table + install hints for missing CLIs |
| `03-use-pin.mp4` | `agents use Work --vendor codex`, `agents active` | Pinning one lab; `mixed` state when vendors disagree |
| `04-best.mp4` | `agents best --vendor codex` | Quota-aware routing (7d %, `no-token` for signed-out slots) |
| `05-sessions.mp4` | `agents sessions Work` | Recent prompts across Claude + Codex with branch/title |
| `06-run.mp4` | `agents run Work --vendor codex` | Per-process pinning via config-dir env vars |

## How they were made

Each clip is **real `./agents` output**, captured under an isolated `HOME`
with fake vendor CLIs (the same technique as `scripts/test.sh`), rendered to a
terminal-style frame and encoded with ffmpeg. No real profile, login or dot dir
is touched.

- `02-vendors` runs with a minimal `PATH` (`/usr/bin:/bin:/opt/homebrew/bin`),
  so labs installed elsewhere show as missing, with their install commands.
- `agents list` also lists every `/Applications/Claude-<Name>.app` as a
  profile. Those rows are the recording machine's own profiles, so the builder
  drops them; the rest is verbatim.
- The menu bar panel, the sign-in flow and Desktop clone creation need an
  interactive screen recording.

## Re-record

```sh
python3 docs/demos/build.py   # needs Pillow and ffmpeg
```

It rebuilds the fixture in `/tmp/n2demo`, re-captures, and re-encodes the clips
into this directory.
