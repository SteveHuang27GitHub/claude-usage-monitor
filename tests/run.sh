#!/usr/bin/env bash
# tests/run.sh — offline end-to-end test of claude-usage + statusline wrapper + usage-guard hook
#
#   tests/run.sh [--online] [--keep]
#     --online  also exercise the real /api/oauth/usage endpoint (needs Claude Code credentials)
#     --keep    keep the temporary CLAUDE_CONFIG_DIR for inspection
#
# Runs against an isolated CLAUDE_CONFIG_DIR; never touches ~/.claude.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$HERE/src"
TOOL="$SRC/claude-usage"; WRAPPER="$SRC/usage-statusline.js"; GUARD="$SRC/usage-guard.py"
ONLINE=0; KEEP=0
for a in "$@"; do case "$a" in --online) ONLINE=1;; --keep) KEEP=1;; esac; done

REAL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-usage-test.XXXXXX")
export CLAUDE_CONFIG_DIR="$TMP"
[ $ONLINE = 1 ] && [ -f "$REAL_DIR/.credentials.json" ] && ln -s "$REAL_DIR/.credentials.json" "$TMP/.credentials.json"
export NOTIFY_DISABLE=1
SESSION="usagetest-$$"
cleanup() { rm -f "${TMPDIR:-/tmp}/claude-usage-guard-${SESSION}.json" "${TMPDIR:-/tmp}/claude-usage-ckpt-${SESSION}"*.json; [ $KEEP = 1 ] && echo "kept: $TMP" || rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31m✘\033[0m %s\n    %s\n' "$1" "${2:-}"; }
check() { if grep -qE -- "$2" <<<"$3"; then ok "$1"; else fail "$1" "expected /$2/, got: $(head -c 300 <<<"$3")"; fi; }

NOW=$(date +%s)
sl_json() { printf '{"session_id":"%s","model":{"display_name":"TestModel"},"workspace":{"current_dir":"/tmp/proj"},"context_window":{"remaining_percentage":70},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$SESSION" "$1" $((NOW+3600)) "$2" $((NOW+86400)); }
hook_json() { printf '{"hook_event_name":"%s","session_id":"%s","tool_name":"%s"}' "$1" "$SESSION" "${2:-Bash}"; }
state_py() { python3 -c "
import json,os,sys
p=os.path.join(os.environ['CLAUDE_CONFIG_DIR'],'state','usage.json'); s=json.load(open(p))
$1
json.dump(s,open(p,'w'))"; }
state_get() { python3 -c "
import json,os
s=json.load(open(os.path.join(os.environ['CLAUDE_CONFIG_DIR'],'state','usage.json'))); print($1)"; }

echo "▶ 1. no state file"
check "status says no data" "No usage data" "$("$TOOL" status)"
check "hook silent without data" "^$" "$(hook_json PostToolUse | python3 "$GUARD")"
check "segment empty" "^$" "$("$TOOL" segment)"

echo "▶ 2. wrapper without inner statusline (5h 21% / 7d 2%)"
out=$(sl_json 21 2 | node "$WRAPPER")
check "fallback shows model + dir" "TestModel.*proj" "$out"
check "segment ⚡5h 21%" "⚡5h .*21%" "$out"
check "segment 7d 2%" "7d .*2%" "$out"
check "state written (statusline)" "statusline" "$("$TOOL" status)"
check "hook level 0 silent" "^$" "$(hook_json PostToolUse | python3 "$GUARD")"
check "PreToolUse level 0 no deny" "^$" "$(hook_json PreToolUse Agent | python3 "$GUARD")"

echo "▶ 3. wrapper with inner statusline"
echo '{"inner_statusline":"printf INNER-OK"}' > "$TMP/usage-monitor.json"
out=$(sl_json 21 2 | node "$WRAPPER")
check "inner output preserved" "INNER-OK" "$out"
check "segment appended after inner" "INNER-OK.*⚡5h" "$out"
rm "$TMP/usage-monitor.json"

echo "▶ 4. level 1 (5h 82%)"
sl_json 82 2 | node "$WRAPPER" >/dev/null
check "level=1" '"level": 1' "$("$TOOL" hook)"
check "UserPromptSubmit injects context" "additionalContext.*level 1" "$(hook_json UserPromptSubmit | python3 "$GUARD")"
check "same level deduped" "^$" "$(hook_json PostToolUse | python3 "$GUARD")"
check "level 1 does not deny Agent" "^$" "$(hook_json PreToolUse Agent | python3 "$GUARD")"
check "80% alert logged" "≥80%" "$(cat "$TMP/state/usage-alerts.log")"

echo "▶ 5. level 2 (5h 91%) + deny"
sl_json 91 2 | node "$WRAPPER" >/dev/null
check "deny Agent" '"permissionDecision": "deny"' "$(hook_json PreToolUse Agent | python3 "$GUARD")"
check "deny Workflow" 'deny' "$(hook_json PreToolUse Workflow | python3 "$GUARD")"
check "Bash allowed" "^$" "$(hook_json PreToolUse Bash | python3 "$GUARD")"
check "new level injects again" "level 2" "$(hook_json PostToolUse | python3 "$GUARD")"
check "90% alert logged" "≥90%" "$(cat "$TMP/state/usage-alerts.log")"
check "91% rendered red" $'\e\\[5;31m91%' "$(sl_json 91 2 | node "$WRAPPER")"

echo "▶ 6. level 3 (5h 96%)"
sl_json 96 2 | node "$WRAPPER" >/dev/null
check "level=3" '"level": 3' "$("$TOOL" hook)"
check "95% alert logged" "≥95%" "$(cat "$TMP/state/usage-alerts.log")"

echo "▶ 7. burn-rate ETA"
sl_json 55 2 | node "$WRAPPER" >/dev/null
state_py "s['samples']=[[$((NOW-900)),37],[$((NOW-600)),43],[$((NOW-300)),49],[$NOW,55]]"
out=$("$TOOL" status)
check "burn rate computed" "burn rate: 1\.[0-9]+%/min" "$out"
check "ETA ~37 min (no alert)" "~3[5-9] min" "$out"
check "ETA>15 keeps level 0" '"level": 0' "$("$TOOL" hook)"
state_py "s['samples']=[[$((NOW-900)),7],[$((NOW-600)),23],[$((NOW-300)),39],[$NOW,55]]"
check "3.2%/min → ETA notification" "limit in ~1[0-4] min" "$("$TOOL" check)"
check "ETA alert → level 2" '"level": 2' "$("$TOOL" hook)"
check "segment shows ⏳" "⏳1[0-9]m" "$("$TOOL" segment)"

echo "▶ 8. window reset clears dedupe"
state_py "s['windows']['five_hour']['pct']=91; s['notified']={'five_hour':{'levels':[80,90]}}"
sl_json 3 2 | node "$WRAPPER" >/dev/null
[ "$(state_get "s['notified'].get('five_hour',{}).get('levels')")" = "[]" ] && ok "notified levels cleared" || fail "notified levels cleared"
[ "$(state_get "len(s['samples'])")" = 1 ] && ok "samples cleared" || fail "samples cleared"

echo "▶ 9. stale marker"
state_py "s['updated']-=1200"
check "status shows stale" "stale" "$("$TOOL" status)"
check "segment shows stale" "stale" "$("$TOOL" segment)"

echo "▶ 10. config overrides"
echo '{"thresholds":{"five_hour":[50]},"lang":"zh-TW","heavy_tools":["Bash"],"deny_level":1}' > "$TMP/usage-monitor.json"
sl_json 55 2 | node "$WRAPPER" >/dev/null
check "custom threshold 50 → level 1" '"level": 1' "$("$TOOL" hook)"
check "zh-TW alert text" "用量 55%" "$("$TOOL" status)"
check "custom heavy tool + deny_level 1" "deny" "$(hook_json PreToolUse Bash | python3 "$GUARD")"
check "config command" '"deny_level": 1' "$("$TOOL" config)"
rm "$TMP/usage-monitor.json"

echo "▶ 11. malformed input"
check "record ignores bad JSON" "^$" "$(echo 'not json' | "$TOOL" record; echo)"
check "guard ignores bad JSON" "^$" "$(echo '{' | python3 "$GUARD")"
out=$(echo '{' | node "$WRAPPER"; echo "rc=$?")
check "wrapper survives bad JSON (exit 0, no model text)" "rc=0" "$out"

echo "▶ 12. checkpoint (devlog + auto-commit)"
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo hello > "$REPO/a.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -qm init
echo change >> "$REPO/a.txt"; echo new > "$REPO/b.txt"
TR="$TMP/transcript.jsonl"
printf '%s\n' '{"type":"user","message":{"content":"do x"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"I refactored the parser and started on tests."}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Next step: wire the CLI flag."}]}}' > "$TR"
sl_json 96 2 | node "$WRAPPER" >/dev/null
out=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$SESSION" "$REPO" "$TR" | python3 "$GUARD")
check "Stop hook produces no output (never blocks)" "^$" "$out"
check "DEVLOG.md created" "auto-checkpoint" "$(cat "$REPO/DEVLOG.md")"
check "DEVLOG has transcript tail" "wire the CLI flag" "$(cat "$REPO/DEVLOG.md")"
check "DEVLOG lists changed files" "a.txt, b.txt" "$(cat "$REPO/DEVLOG.md")"
check "DEVLOG has usage summary" "5h 96%" "$(cat "$REPO/DEVLOG.md")"
check "auto-commit made" "checkpoint: auto-commit" "$(git -C "$REPO" log -1 --format=%s)"
check "worktree clean after commit" "^$" "$(git -C "$REPO" status --porcelain)"
out=$(printf '{"hook_event_name":"PostToolUse","session_id":"%s","cwd":"%s","transcript_path":"%s"}' "$SESSION" "$REPO" "$TR" | python3 "$GUARD")
check "PostToolUse level 3 injects with checkpoint note absent (deduped)" "level 3" "$out"
[ "$(git -C "$REPO" log --oneline | wc -l)" = 2 ] && ok "checkpoint deduped (still 2 commits)" || fail "checkpoint deduped"
echo more >> "$REPO/a.txt"
out=$("$TOOL" checkpoint --cwd "$REPO" --session "$SESSION" --reason manual --force)
check "manual --force checkpoint commits again" '"git: committed"' "$out"
out=$("$TOOL" checkpoint --cwd "$TMP" --reason manual --force)
check "non-git dir skipped" "not a git repo" "$out"
echo '{"auto_commit":false,"devlog_file":""}' > "$TMP/usage-monitor.json"
echo x >> "$REPO/a.txt"
out=$("$TOOL" checkpoint --cwd "$REPO" --reason manual --force)
check "auto_commit=false, devlog off → no actions" '"actions": \[\]' "$out"
check "file left uncommitted" "a.txt" "$(git -C "$REPO" status --porcelain)"
rm "$TMP/usage-monitor.json"
echo '{"checkpoint_level":0}' > "$TMP/usage-monitor.json"
printf '{"hook_event_name":"Stop","session_id":"%s-b","cwd":"%s"}' "$SESSION" "$REPO" | python3 "$GUARD" >/dev/null
check "checkpoint_level 0 disables auto-checkpoint" "a.txt" "$(git -C "$REPO" status --porcelain)"
rm "$TMP/usage-monitor.json"
rm -f "${TMPDIR:-/tmp}/claude-usage-ckpt-${SESSION}.json" "${TMPDIR:-/tmp}/claude-usage-ckpt-${SESSION}-b.json"

if [ $ONLINE = 1 ]; then
  echo "▶ 13. live API fetch"
  out=$("$TOOL" fetch 2>&1) && check "fetch ok (source=api)" "\(api\)" "$out" || fail "fetch" "$out"
fi

echo; echo "result: $PASS passed, $FAIL failed"
[ $FAIL = 0 ]
