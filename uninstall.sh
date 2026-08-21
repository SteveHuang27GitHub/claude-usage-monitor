#!/usr/bin/env bash
# uninstall.sh — remove claude-usage-monitor; restores the original statusLine command
set -euo pipefail
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$CLAUDE_DIR/usage-monitor"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/usage-monitor.json"

if [ -f "$SETTINGS" ]; then
  SETTINGS="$SETTINGS" CONFIG="$CONFIG" python3 - <<'EOF'
import json, os
settings, config = os.environ["SETTINGS"], os.environ["CONFIG"]
s = json.load(open(settings))
inner = ""
if os.path.exists(config):
    inner = json.load(open(config)).get("inner_statusline", "")
if "usage-statusline.js" in (s.get("statusLine") or {}).get("command", ""):
    if inner:
        s["statusLine"] = {"type": "command", "command": inner}
    else:
        s.pop("statusLine", None)
for event, lst in list((s.get("hooks") or {}).items()):
    for e in lst:
        e["hooks"] = [x for x in e.get("hooks", []) if "usage-guard" not in x.get("command", "")]
    s["hooks"][event] = [e for e in lst if e.get("hooks")]
    if not s["hooks"][event]:
        del s["hooks"][event]
json.dump(s, open(settings, "w"), indent=2, ensure_ascii=False)
print("settings.json cleaned")
EOF
fi

case "$(uname -s)" in
  Linux)
    systemctl --user disable --now claude-usage.timer 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/claude-usage.service" "$HOME/.config/systemd/user/claude-usage.timer"
    systemctl --user daemon-reload 2>/dev/null || true;;
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.claude-usage-monitor.plist"
    launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST";;
esac
rm -f "$HOME/.local/bin/claude-usage"
rm -rf "$DEST"
echo "removed $DEST (kept $CONFIG and $CLAUDE_DIR/state/usage.json — delete manually if unwanted)"
