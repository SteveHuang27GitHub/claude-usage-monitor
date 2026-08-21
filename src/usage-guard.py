#!/usr/bin/env python3
"""usage-guard.py — inject usage alerts into the running Claude Code session

Hook events: UserPromptSubmit / PostToolUse (additionalContext), PreToolUse (deny heavy tools),
Stop / PostToolUse at checkpoint_level → `claude-usage checkpoint` (DEVLOG entry + git commit).
  level 1 : 5h ≥ 80% or 7d ≥ 90%          → reminder: plan a stopping point
  level 2 : 5h ≥ 90% or ETA < 15 min      → wrap up now; heavy tools (Agent/Task/Workflow) denied
  level 3 : 5h ≥ 95%                      → stop, commit / write handoff notes
Context injection is rate-limited per session and level (guard_repeat_sec, default 300s).
"""
import json
import os
import subprocess
import sys
import tempfile
import time

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-usage")

ADVICE = {
    "en": {
        3: "Usage is almost exhausted. STOP starting new work now. An auto-checkpoint (git commit + DEVLOG.md stub) "
           "has been made; replace the DEVLOG stub with what was in progress and the exact next step, then commit. "
           "Do not launch Agent/Workflow. Keep replies short.",
        2: "Usage will hit the limit soon. Wind down progressively: let running subagents finish but start no new ones, "
           "finish the smallest deliverable, then git commit and update DEVLOG.md with status + next step.",
        1: "Usage passed the warning threshold. Plan a stopping point and avoid starting large new work; "
           "check usage before any big fan-out.",
    },
    "zh-TW": {
        3: "額度即將耗盡，立即停止新工作。系統已自動 checkpoint（git commit + DEVLOG.md 暫存條目）；請把 DEVLOG 暫存條目改成「做到哪、下一步是什麼」後再 commit 一次。不要再啟動 Agent/Workflow，回覆盡量精簡。",
        2: "額度很快到頂，請漸進收尾：讓進行中的 subagent 跑完但不要再開新的，完成手上最小可交付單位後 git commit，並在 DEVLOG.md 寫下狀態與下一步。",
        1: "額度已過警戒線。請規劃收尾點，避免展開新的大範圍工作；大型 fan-out 前先確認額度。",
    },
}


def main():
    try:
        hook = json.load(sys.stdin)
    except Exception:
        return 0
    event = hook.get("hook_event_name", "")
    session = hook.get("session_id", "nosession")
    try:
        ev = json.loads(subprocess.run([sys.executable, TOOL, "hook"], capture_output=True,
                                       text=True, timeout=3).stdout)
    except Exception:
        return 0
    level = ev.get("level", 0)
    if level == 0:
        return 0

    # auto-checkpoint (devlog + commit) at checkpoint_level, on Stop / PostToolUse
    ck_level = ev.get("checkpoint_level", 3)
    ck_note = ""
    if ck_level and level >= ck_level and event in ("Stop", "PostToolUse"):
        try:
            r = subprocess.run([sys.executable, TOOL, "checkpoint",
                                "--cwd", hook.get("cwd") or os.getcwd(),
                                "--session", session,
                                "--transcript", hook.get("transcript_path") or "",
                                "--reason", f"usage level {level}: {ev.get('summary', '')}"],
                               capture_output=True, text=True, timeout=60)
            res = json.loads(r.stdout or "{}")
            if res.get("actions"):
                ck_note = " Checkpoint: " + "; ".join(res["actions"]) + "."
        except Exception:
            pass
    if event == "Stop":
        return 0  # never block the stop; checkpoint is the side effect

    lang = ev.get("lang", "en")
    advice = ADVICE.get(lang, ADVICE["en"])[min(level, 3)]
    detail = "; ".join(ev.get("alerts", [])) or ev.get("summary", "")
    msg = f"[usage-guard] Claude usage alert (level {level}): {detail}. {advice}{ck_note}"

    if event == "PreToolUse":
        if level >= ev.get("deny_level", 2) and hook.get("tool_name") in set(ev.get("heavy_tools", [])):
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": msg}}, ensure_ascii=False))
        return 0

    mark = os.path.join(tempfile.gettempdir(), f"claude-usage-guard-{session}.json")
    try:
        seen = json.load(open(mark))
    except Exception:
        seen = {}
    if time.time() - seen.get(str(level), 0) < ev.get("guard_repeat_sec", 300):
        return 0
    seen[str(level)] = int(time.time())
    try:
        json.dump(seen, open(mark, "w"))
    except Exception:
        pass
    print(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": msg}},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
