#!/usr/bin/env bash
# install.sh — install claude-usage-monitor into ~/.claude
#
#   ./install.sh [--no-timer] [--no-hooks] [--lang zh-TW]
#
# What it does:
#   1. copies src/* to $CLAUDE_CONFIG_DIR/usage-monitor/
#   2. writes $CLAUDE_CONFIG_DIR/usage-monitor.json (keeps existing values; records your
#      current statusLine command as inner_statusline so it keeps working)
#   3. merges settings.json: statusLine → wrapper, hooks → usage-guard (existing hooks untouched)
#   4. installs a background poller (systemd --user timer on Linux, launchd on macOS)
#   5. symlinks claude-usage into ~/.local/bin if it is on PATH
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/usage-monitor"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/usage-monitor.json"
TIMER=1; HOOKS=1; LANG_OPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-timer) TIMER=0;;
    --no-hooks) HOOKS=0;;
    --lang) LANG_OPT="$2"; shift;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac; shift
done

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
command -v node >/dev/null    || { echo "node is required (Claude Code ships with it)" >&2; exit 1; }

echo "▶ installing files to $DEST"
mkdir -p "$DEST" "$CLAUDE_DIR/state"
cp "$HERE"/src/claude-usage "$HERE"/src/usage-statusline.js "$HERE"/src/usage-guard.py "$DEST"/
chmod +x "$DEST"/claude-usage "$DEST"/usage-statusline.js "$DEST"/usage-guard.py

echo "▶ merging settings ($SETTINGS)"
[ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-usage-monitor"
DEST="$DEST" SETTINGS="$SETTINGS" CONFIG="$CONFIG" HOOKS="$HOOKS" LANG_OPT="$LANG_OPT" python3 - <<'EOF'
import json, os
dest, settings, config = os.environ["DEST"], os.environ["SETTINGS"], os.environ["CONFIG"]
hooks_on, lang = os.environ["HOOKS"] == "1", os.environ["LANG_OPT"]
wrapper = f'node "{dest}/usage-statusline.js"'
guard = f'python3 "{dest}/usage-guard.py"'

s = json.load(open(settings)) if os.path.exists(settings) else {}
cfg = json.load(open(config)) if os.path.exists(config) else {}

# remember the user's original statusLine so the wrapper can keep it
cur = (s.get("statusLine") or {}).get("command", "")
if cur and "usage-statusline.js" not in cur:
    cfg["inner_statusline"] = cur
cfg.setdefault("inner_statusline", "")
if lang:
    cfg["lang"] = lang
json.dump(cfg, open(config, "w"), indent=2, ensure_ascii=False)
print(f"  inner_statusline = {cfg['inner_statusline'] or '(none)'}")

s["statusLine"] = {"type": "command", "command": wrapper}

if hooks_on:
    h = s.setdefault("hooks", {})
    entry = {"type": "command", "command": guard, "timeout": 5}
    def add(event, matcher=None):
        lst = h.setdefault(event, [])
        for e in lst:
            for x in e.get("hooks", []):
                if "usage-guard" in x.get("command", ""):
                    x.update(entry)          # refresh path
                    return
        ent = {"hooks": [entry]}
        if matcher: ent["matcher"] = matcher
        lst.append(ent)
    add("UserPromptSubmit")
    add("PostToolUse", "Bash|Edit|Write|MultiEdit|Agent|Task")
    add("PreToolUse", "Agent|Task|Workflow")
    add("Stop")
json.dump(s, open(settings, "w"), indent=2, ensure_ascii=False)
EOF

if [ $TIMER = 1 ]; then
  case "$(uname -s)" in
    Linux)
      if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        echo "▶ installing systemd user timer"
        mkdir -p "$HOME/.config/systemd/user"
        sed "s|@DEST@|$DEST|g" "$HERE/systemd/claude-usage.service.in" > "$HOME/.config/systemd/user/claude-usage.service"
        cp "$HERE/systemd/claude-usage.timer" "$HOME/.config/systemd/user/claude-usage.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now claude-usage.timer
      else
        echo "  (no systemd user session — skipping timer; add a cron entry: */3 * * * * $DEST/claude-usage fetch --notify --quiet)"
      fi;;
    Darwin)
      echo "▶ installing launchd agent"
      mkdir -p "$HOME/Library/LaunchAgents"
      PLIST="$HOME/Library/LaunchAgents/com.claude-usage-monitor.plist"
      sed "s|@DEST@|$DEST|g" "$HERE/launchd/com.claude-usage-monitor.plist.in" > "$PLIST"
      launchctl unload "$PLIST" 2>/dev/null || true
      launchctl load "$PLIST";;
    *) echo "  (unknown OS — skipping background poller)";;
  esac
fi

if [ -d "$HOME/.local/bin" ] && case ":$PATH:" in *":$HOME/.local/bin:"*) true;; *) false;; esac; then
  ln -sf "$DEST/claude-usage" "$HOME/.local/bin/claude-usage"
  echo "▶ symlinked ~/.local/bin/claude-usage"
fi

echo "▶ first fetch"
"$DEST/claude-usage" fetch || echo "  (fetch failed — fine if you use an API key; the status line source still works)"
echo
echo "Done. Restart Claude Code sessions to load the hooks. Check with: $DEST/claude-usage status"
