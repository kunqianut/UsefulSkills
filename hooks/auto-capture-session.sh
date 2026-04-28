#!/bin/bash
# SessionStart hook: auto-capture the previous session's raw conversation data
# to the Obsidian vault. Runs on every session start (new or resumed).
#
# Install:
#   cp hooks/auto-capture-session.sh ~/.claude/hooks/
#   chmod +x ~/.claude/hooks/auto-capture-session.sh
#   Add to ~/.claude/settings.json:
#   {
#     "hooks": {
#       "SessionStart": [{
#         "matcher": "",
#         "hooks": [{
#           "type": "command",
#           "command": "bash ~/.claude/hooks/auto-capture-session.sh"
#         }]
#       }]
#     }
#   }

VAULT="${CLAUDE_VAULT_PATH:-$HOME/ObsidianVaults/ClaudeCode}"

if ! command -v python3 &>/dev/null; then
    echo "Auto-capture skipped: python3 not found." >&2
    exit 0
fi

INPUT=$(cat)

CWD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cwd',''))" 2>&1)
if [ $? -ne 0 ] || [ -z "$CWD" ]; then
    [ -n "$CWD" ] && echo "Auto-capture: failed to parse hook input: $CWD" >&2
    exit 0
fi

ENCODED=$(echo "$CWD" | sed 's|/|-|g')
PROJ_DIR="$HOME/.claude/projects/${ENCODED}"

[ ! -d "$PROJ_DIR" ] && exit 0

# bash 3.2 compatible (no mapfile)
JSONL_FILES=()
while IFS= read -r f; do
    JSONL_FILES+=("$f")
done < <(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null)
[ ${#JSONL_FILES[@]} -lt 2 ] && exit 0

PREV_FILE="${JSONL_FILES[1]}"
PREV_ID=$(basename "$PREV_FILE" .jsonl)
SHORT_ID="${PREV_ID:0:8}"
PROJECT_NAME=$(basename "$CWD")

EXISTING=$(find "${VAULT}/sessions/raw/${PROJECT_NAME}" -name "*-${SHORT_ID}.md" 2>/dev/null | head -1)
[ -n "$EXISTING" ] && exit 0

# Pass paths via environment variables to avoid shell injection in heredoc
export _CAPTURE_PREV_FILE="$PREV_FILE"
export _CAPTURE_VAULT="$VAULT"

RESULT=$(python3 << 'PYEOF'
import json, os, sys
from collections import Counter
from datetime import datetime

fpath = os.environ["_CAPTURE_PREV_FILE"]
vault = os.environ["_CAPTURE_VAULT"]

skipped = 0
records = []
try:
    with open(fpath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                skipped += 1
except OSError as e:
    sys.stderr.write(f"Error: could not read {fpath}: {e}\n")
    sys.exit(1)

if skipped > 0:
    sys.stderr.write(f"Warning: {skipped} malformed lines skipped in {fpath}\n")

if not records:
    sys.stderr.write(f"Error: no valid records found in {fpath} ({skipped} lines were malformed)\n")
    sys.exit(1)

session_id = ""
timestamps = []
branches = Counter()
cwd_val = ""
custom_title = ""
agent_name = ""
pr_links = []

for r in records:
    if r.get("sessionId") and not session_id:
        session_id = r["sessionId"]
    if r.get("timestamp"):
        timestamps.append(r["timestamp"])
    if r.get("gitBranch"):
        branches[r["gitBranch"]] += 1
    if r.get("cwd") and not cwd_val:
        cwd_val = r["cwd"]
    if r.get("type") == "custom-title":
        custom_title = r.get("customTitle", "")
    if r.get("type") == "agent-name":
        agent_name = r.get("agentName", "")
    if r.get("type") == "pr-link" and r.get("prUrl"):
        pr_links.append(r["prUrl"])

project_name = os.path.basename(cwd_val) if cwd_val else "unknown"
primary_branch = branches.most_common(1)[0][0] if branches else "unknown"
start_time = min(timestamps) if timestamps else ""
end_time = max(timestamps) if timestamps else ""
date = start_time[:10] if start_time else datetime.now().strftime("%Y-%m-%d")
title = custom_title or agent_name or "Untitled"

duration_minutes = 0
if start_time and end_time:
    try:
        t1 = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        t2 = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
        duration_minutes = int((t2 - t1).total_seconds() / 60)
    except (ValueError, TypeError) as e:
        sys.stderr.write(f"Warning: could not parse timestamps for duration: {e}\n")
        duration_minutes = 0

lines = []
lines.append("---")
lines.append(f"date: {date}")
lines.append(f"project: {json.dumps(project_name)}")
lines.append(f"session_id: {json.dumps(session_id)}")
lines.append(f"branch: {json.dumps(primary_branch)}")
lines.append(f"all_branches: {json.dumps(sorted(branches.keys()))}")
lines.append("type: session-raw")
lines.append(f"tags: {json.dumps(['claude-code', project_name])}")
lines.append(f"start_time: {json.dumps(start_time)}")
lines.append(f"end_time: {json.dumps(end_time)}")
lines.append(f"duration_minutes: {duration_minutes}")
lines.append(f"title: {json.dumps(title)}")
lines.append("---")
lines.append("")
lines.append(f"# Session: {project_name} / {primary_branch} / {date}")
lines.append("")
lines.append("## Metadata")
lines.append(f"- **Project**: {project_name} (`{cwd_val}`)")
lines.append(f"- **Branch**: {primary_branch}")
lines.append(f"- **Duration**: {start_time} → {end_time} (~{duration_minutes} minutes)")
lines.append(f"- **Session ID**: `{session_id}`")
lines.append(f"- **Title**: {title}")
if pr_links:
    lines.append(f"- **PR Links**: {', '.join(pr_links)}")
lines.append("")
lines.append("## Conversation")
lines.append("")

turn_num = 0
for r in records:
    if r.get("type") == "user":
        content = (r.get("message") or {}).get("content", "")
        if isinstance(content, str) and content.strip():
            turn_num += 1
            ts = r.get("timestamp", "")
            lines.append(f"### Turn {turn_num} — {ts}")
            lines.append("")
            lines.append("**User:**")
            lines.append(content.strip())
            lines.append("")
        elif isinstance(content, list):
            text_parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip()]
            if text_parts:
                turn_num += 1
                ts = r.get("timestamp", "")
                lines.append(f"### Turn {turn_num} — {ts}")
                lines.append("")
                lines.append("**User:**")
                lines.append("\n".join(text_parts))
                lines.append("")
    elif r.get("type") == "assistant":
        texts = []
        tool_calls = []
        for c in (r.get("message") or {}).get("content", []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
            elif c.get("type") == "tool_use":
                name = c.get("name", "")
                inp = c.get("input") or {}
                if name == "Bash":
                    summary = inp.get("command", "")[:150]
                elif name in ("Read", "Write", "Edit"):
                    summary = inp.get("file_path", "")[:150]
                elif name == "Agent":
                    summary = inp.get("description", "")[:150]
                else:
                    keys = list(inp.keys())[:3]
                    summary = ", ".join(f"{k}={str(inp[k])[:50]}" for k in keys)
                tool_calls.append(f"- `{name}`: `{summary}`")
        if texts or tool_calls:
            lines.append("**Claude:**")
            for t in texts:
                lines.append(t)
                lines.append("")
            if tool_calls:
                lines.append("**Tool Calls:**")
                lines.extend(tool_calls)
                lines.append("")
            lines.append("---")
            lines.append("")

tool_counts = Counter()
for r in records:
    if r.get("type") == "assistant":
        for c in (r.get("message") or {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_use":
                tool_counts[c.get("name", "unknown")] += 1

if tool_counts:
    lines.append("## Tool Usage Summary")
    lines.append("")
    lines.append("| Tool | Count |")
    lines.append("|------|-------|")
    for tool, count in tool_counts.most_common():
        lines.append(f"| {tool} | {count} |")
    lines.append("")

output = "\n".join(lines)

out_dir = os.path.join(vault, "sessions", "raw", project_name)
try:
    os.makedirs(out_dir, exist_ok=True)
    short_id = (session_id or os.path.basename(fpath).replace(".jsonl", ""))[:8]
    out_path = os.path.join(out_dir, f"{date}-{short_id}.md")
    with open(out_path, "w") as f:
        f.write(output)
except OSError as e:
    sys.stderr.write(f"Error: could not write session capture to {out_dir}: {e}\n")
    sys.exit(2)

print(json.dumps({
    "path": out_path,
    "project": project_name,
    "branch": primary_branch,
    "date": date,
    "duration": duration_minutes,
    "turns": turn_num
}))
PYEOF
)

unset _CAPTURE_PREV_FILE _CAPTURE_VAULT

if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
    PROJECT=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('project',''))")
    BRANCH=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('branch',''))")
    DATE=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('date',''))")
    echo "Previous session captured: ${PROJECT}/${BRANCH} (${DATE}). Run /summarize-session --previous to generate a structured summary."
else
    echo "Auto-capture failed for previous session. Run /capture-session --previous manually to retry." >&2
fi
