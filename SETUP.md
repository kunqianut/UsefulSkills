# Setup Guide & Troubleshooting

## Quick Setup

```bash
# 1. Clone and install skills
git clone git@github.com:kunqianut/UsefulSkills.git
for skill in reviewed-work multi-round-review capture-session summarize-session threads briefing suggest-actions; do
  mkdir -p ~/.claude/skills/$skill
  cp UsefulSkills/$skill/SKILL.md ~/.claude/skills/$skill/SKILL.md
done

# 2. Install agents
cp UsefulSkills/agents/*.md ~/.claude/agents/

# 3. Install hooks
mkdir -p ~/.claude/hooks
cp UsefulSkills/hooks/auto-capture-session.sh ~/.claude/hooks/
cp UsefulSkills/hooks/nightly-capture-and-summarize.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/auto-capture-session.sh
chmod +x ~/.claude/hooks/nightly-capture-and-summarize.sh

# 4. Create vault log directory
mkdir -p ~/ObsidianVaults/ClaudeCode/_logs
```

## Required Settings

### ~/.claude/settings.json

Two things must be configured in the **global** settings (not project-level):

**1. SessionEnd hook** — auto-captures the current session on close and summarizes in background:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/auto-capture-session.sh"
          }
        ]
      }
    ]
  }
}
```

**2. Global permissions for the Obsidian vault** — the background `claude -p` summarization needs read/write/edit access to the vault. These MUST be in the global `~/.claude/settings.json`, not in a project-level `settings.local.json`:

```json
{
  "permissions": {
    "allow": [
      "Read(//Users/<your-username>/ObsidianVaults/**)",
      "Write(//Users/<your-username>/ObsidianVaults/**)",
      "Edit(//Users/<your-username>/ObsidianVaults/**)",
      "Bash(cat:*)",
      "Bash(find:*)",
      "Bash(mkdir:*)",
      "Bash(python3:*)"
    ]
  }
}
```

Replace `<your-username>` with your actual macOS username.

### 7. Background `claude -p` doesn't know about skills

**Symptom:** The hook runs `claude -p` to summarize, but the log is empty or shows no output. No summary file is created.

**Cause:** `claude -p` runs headlessly without loading skills from `~/.claude/skills/`. A prompt like "Run `/summarize-session`" does nothing because the skill isn't available.

**Fix:** The hook now uses an explicit, self-contained prompt that tells `claude -p` exactly what to read, analyze, and write — no skill reference needed. Make sure you have the latest version of `auto-capture-session.sh`.

### Nightly Cron (Optional)

```bash
crontab -e
# Add:
0 3 * * * bash ~/.claude/hooks/nightly-capture-and-summarize.sh >> ~/ObsidianVaults/ClaudeCode/_logs/nightly-cron.log 2>&1
```

## Known Issues & Solutions

### 1. Background summarization fails with permission errors

**Symptom:** Raw captures appear in `~/ObsidianVaults/ClaudeCode/sessions/raw/` but no summaries are created. Log files in `_logs/summarize-*.log` show "I need permission to read files from /Users/.../ObsidianVaults/".

**Cause:** The `claude -p` process that runs summarization in the background inherits the CWD of the closed session, not the project where permissions are defined. Project-level permissions (`settings.local.json`) don't apply.

**Fix:** Add vault read/write permissions to the **global** `~/.claude/settings.json` (see Required Settings above). Do NOT put them in project-level `settings.local.json` — that only applies within that specific project.

### 2. SessionEnd hook doesn't re-capture updated sessions

**Symptom:** You resumed a session, did more work, closed it, but the capture in the vault is stale (doesn't include the new work).

**Cause:** Earlier versions of the hook only checked if a capture file *existed* and skipped if so. It didn't compare whether the JSONL had been modified since the last capture.

**Fix:** Update to the latest `auto-capture-session.sh` which compares modification times (`-nt`). The hook now re-captures if the JSONL is newer than the existing capture file.

### 3. New agents/skills not available in current session

**Symptom:** You copied `thread-tracker.md` to `~/.claude/agents/` but `/summarize-session` says the agent is not found.

**Cause:** Claude Code loads agents and skills at session start. They are not hot-reloaded mid-session.

**Fix:** Start a **new** Claude Code session after installing agents or skills. They'll be available immediately in the new session.

### 4. Hook was on SessionStart, not SessionEnd

**Symptom:** The hook captures the *previous* session when you start a new one, but doesn't capture the *current* session when you close it. Long-running sessions are never captured until the next session starts.

**Cause:** Older versions used `SessionStart` instead of `SessionEnd`.

**Fix:** Change the hook event in `~/.claude/settings.json` from `"SessionStart"` to `"SessionEnd"`. The hook script now expects `session_id` in the stdin JSON (provided by `SessionEnd`) to find the exact JSONL file.

### 5. Nightly cron doesn't run (laptop was asleep)

**Symptom:** No nightly captures or logs appear. The cron job was set for 3 AM but the laptop was asleep.

**Cause:** macOS `cron` does not run missed jobs. If the laptop is asleep or shut down at 3 AM, the job is skipped entirely.

**Workarounds:**
- The `SessionEnd` hook covers most cases — sessions are captured when you close them.
- The nightly script uses a 48-hour window (`-mtime -2`), so a missed night is caught the next night.
- If you need guaranteed execution: use macOS `launchd` with `StartCalendarInterval` instead of cron — it runs missed jobs on wake.

### 6. Cron job captures partially-written active sessions

**Symptom:** A nightly capture has truncated or incomplete conversation data.

**Cause:** If a Claude Code session is actively open at 3 AM, its JSONL file is being written to. The nightly script may read a partially-written file.

**Mitigation:** The latest version includes an `lsof` check that skips files held open by a running Claude process. If the check doesn't catch it, the next nightly run or `SessionEnd` hook will re-capture the complete session (since the JSONL will be newer than the partial capture).

## Verifying the Setup

### Check hook is registered
```bash
# In a Claude Code session, type:
/hooks
# Look for SessionEnd with auto-capture-session.sh
```

### Check permissions
```bash
cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('Permissions:', json.dumps(d.get('permissions',{}), indent=2))"
```

### Test the hook manually
```bash
# Simulate a SessionEnd event (replace with a real session ID and CWD):
echo '{"session_id":"<uuid>","cwd":"/path/to/project"}' | bash ~/.claude/hooks/auto-capture-session.sh
```

### Check nightly cron
```bash
crontab -l  # should show the 0 3 * * * entry
```

### Check vault structure
```bash
find ~/ObsidianVaults/ClaudeCode -type f | head -20
```

### Check summarization logs
```bash
ls -lt ~/ObsidianVaults/ClaudeCode/_logs/ | head -10
cat ~/ObsidianVaults/ClaudeCode/_logs/summarize-*.log  # should NOT show permission errors
```
