# claude-usage-monitor

Real-time subscription usage monitor for [Claude Code](https://claude.com/claude-code).
Know *before* you hit the 5-hour / 7-day rate limit — and let the session wrap itself up
(commit + devlog) instead of being cut off mid-task.

```
Fable │ my-project │ ███░░░░░░░ 36% │ ⚡5h 82% 7d 12% ⏳11m
                                      ^^^^^^^^^^^^^^^^^^^^^^^^^ added by this tool
```

## What it does

| Layer | Mechanism | Result |
|---|---|---|
| **Status line** | Wraps your existing `statusLine` command; reads the `rate_limits` field Claude Code sends after every API response | `⚡5h 82% 7d 12%` with colour (green < 70 %, yellow < 90 %, red ≥ 90 %) and a burn-rate ETA `⏳11m` |
| **Burn-rate ETA** | Linear regression over the last 20 min of samples | Warns when the 5 h window is predicted to hit 100 % within 15 min — even if you are only at 60 % |
| **Desktop notifications** | `notify-send` (Linux) / `osascript` (macOS) | At 80 / 90 / 95 % (5 h), 90 / 95 % (7 d), and on ETA alerts. Once per threshold per reset window |
| **Session notifications** | `UserPromptSubmit` / `PostToolUse` hooks inject `additionalContext` | Claude itself is told to plan a stopping point, then to wind down, then to stop |
| **Heavy-tool guard** | `PreToolUse` hook | From level 2 on, `Agent` / `Task` / `Workflow` calls are denied so a last fan-out can't burn the remaining budget |
| **Auto-checkpoint** | `Stop` / `PostToolUse` hooks at level 3 | Appends a `DEVLOG.md` entry (usage, branch, changed files, last assistant messages from the transcript) and `git commit`s — so even a hard cut-off leaves a recoverable state |
| **Background poller** | systemd user timer / launchd, every 3 min | Queries the same endpoint `/usage` uses; works across sessions and while Claude Code is closed |

### Alert levels

| Level | Trigger | Session behaviour |
|---|---|---|
| 1 | 5 h ≥ 80 % or 7 d ≥ 90 % | "Plan a stopping point, avoid large new work" |
| 2 | 5 h ≥ 90 % or ETA < 15 min | "Wind down: let running subagents finish, start none, commit + update DEVLOG" · heavy tools denied |
| 3 | 5 h ≥ 95 % | Auto-checkpoint (DEVLOG stub + commit) · "Stop; replace the DEVLOG stub with real notes" |

## Install

Requirements: Claude Code with a Claude.ai subscription (Pro / Max / Team / Enterprise), `python3`, `node`, `git`.
Linux or macOS (Windows: the status line + hooks work, notifications and the poller do not).

```bash
git clone https://github.com/<you>/claude-usage-monitor
cd claude-usage-monitor
./install.sh              # add --lang zh-TW for Traditional Chinese messages
```

The installer:
1. copies `src/` to `~/.claude/usage-monitor/`
2. records your current `statusLine.command` as `inner_statusline` in `~/.claude/usage-monitor.json` so it keeps rendering
3. merges the status line + hooks into `~/.claude/settings.json` (backup: `settings.json.bak-usage-monitor`; existing hooks untouched)
4. installs the poller (`--no-timer` to skip) and symlinks `claude-usage` into `~/.local/bin`

**Restart your Claude Code sessions** afterwards — hooks are loaded at startup (the status line hot-reloads).

Uninstall with `./uninstall.sh` (restores the original status line and removes the hooks / poller).

## Usage

```bash
claude-usage status      # current 5h / 7d %, reset times, burn rate, ETA
claude-usage fetch       # force a refresh via the API
claude-usage check       # evaluate thresholds and send pending notifications
claude-usage config      # effective configuration
claude-usage checkpoint --cwd . --reason manual --force   # devlog + commit right now
```

Alerts are also logged to `~/.claude/state/usage-alerts.log`.

## Configuration

`~/.claude/usage-monitor.json` (see [`config.example.json`](config.example.json)); every key is optional.

| Key | Default | Meaning |
|---|---|---|
| `inner_statusline` | `""` | Original status line command to wrap (set by the installer) |
| `thresholds.five_hour` | `[80, 90, 95]` | Levels 1 / 2 / 3 for the 5 h window |
| `thresholds.seven_day` | `[90, 95]` | Levels 1 / 2 for the 7 d window |
| `eta_warn_min` / `eta_min_pct` | `15` / `50` | ETA alert when < N min to limit and usage ≥ pct |
| `sample_window_sec` | `1200` | Regression window for the burn rate |
| `stale_sec` | `600` | Mark data stale after N s without update |
| `notify` | `true` | Desktop notifications |
| `guard_repeat_sec` | `300` | Min interval between context injections per level |
| `heavy_tools` / `deny_level` | `["Agent","Task","Workflow"]` / `2` | Which tools get denied, from which level |
| `checkpoint_level` | `3` | Auto-checkpoint at/above this level (`0` = off) |
| `auto_commit` | `true` | `git add -A && git commit` in the session's cwd |
| `devlog_file` | `"DEVLOG.md"` | Relative to repo root, or absolute; `""` = no devlog |
| `devlog_transcript_msgs` / `_chars` | `4` / `1500` | How much of the transcript tail goes into the stub |
| `lang` | `"en"` | `"en"` or `"zh-TW"` |

## How it works

* Claude Code passes a JSON document to the `statusLine` command on every update. Since 2.1.x it includes
  `rate_limits.five_hour.used_percentage` / `resets_at` and `seven_day` (documented in the status line
  reference). The wrapper stores that in `~/.claude/state/usage.json` — zero extra API calls.
* Hooks do **not** receive `rate_limits`, so `usage-guard.py` reads the state file written by the status line.
* The poller calls `GET https://api.anthropic.com/api/oauth/usage` with the OAuth token Claude Code already
  stores (`~/.claude/.credentials.json`, or the macOS Keychain). This is the same endpoint the `/usage`
  command uses. It is not a documented public API and may change; the status-line source keeps working
  regardless.
* `checkpoint` reads the session transcript (`transcript_path` from the hook payload) to pull the last
  assistant messages into the devlog entry, so the note says what was actually being done.

## Caveats

* `rate_limits` only appears after the session's first API response; the segment is empty until then.
* Utilisation is reported in whole percent, so the burn-rate estimate needs a few minutes of samples.
* API-key / Bedrock / Vertex sessions have no plan limits; everything stays silent.
* The auto-commit is a safety net (`checkpoint: auto-commit by claude-usage-monitor (...)`). Squash or amend
  it once you are back. Set `auto_commit: false` if you prefer only the devlog entry.

## Development

```bash
tests/run.sh            # offline end-to-end suite (isolated CLAUDE_CONFIG_DIR, ~55 checks)
tests/run.sh --online   # also hits the live usage endpoint
```

## License

MIT
