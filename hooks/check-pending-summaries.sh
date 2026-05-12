#!/bin/bash
# SessionStart hook: check for pending summarizations that failed in
# previous sessions (SessionEnd or nightly) and remind the user.
#
# Install:
#   cp hooks/check-pending-summaries.sh ~/.claude/hooks/
#   chmod +x ~/.claude/hooks/check-pending-summaries.sh
#   Add to ~/.claude/settings.json under "hooks":
#   {
#     "hooks": {
#       "SessionStart": [{
#         "matcher": "",
#         "hooks": [{
#           "type": "command",
#           "command": "bash ~/.claude/hooks/check-pending-summaries.sh"
#         }]
#       }]
#     }
#   }

VAULT="${CLAUDE_VAULT_PATH:-$HOME/ObsidianVaults/ClaudeCode}"
QUEUE_FILE="${VAULT}/_queue/pending-summaries.txt"

[ ! -f "$QUEUE_FILE" ] && exit 0

# Remove entries whose summaries have since been created (e.g. manually)
CLEANED=false
if [ -s "$QUEUE_FILE" ]; then
    TMP_FILE="${QUEUE_FILE}.tmp"
    > "$TMP_FILE"
    while IFS= read -r raw_path; do
        [ -z "$raw_path" ] && continue
        # Derive the expected summary path from the raw path
        # Raw:     .../sessions/raw/<project>/<file>.md
        # Summary: .../sessions/summaries/<project>/<file>.md
        SUMMARY_PATH=$(echo "$raw_path" | sed 's|/sessions/raw/|/sessions/summaries/|')
        if [ -f "$SUMMARY_PATH" ]; then
            CLEANED=true
        else
            echo "$raw_path" >> "$TMP_FILE"
        fi
    done < "$QUEUE_FILE"
    mv "$TMP_FILE" "$QUEUE_FILE"
fi

# Count remaining pending items
PENDING=$(grep -c . "$QUEUE_FILE" 2>/dev/null || echo 0)

if [ "$PENDING" -eq 0 ]; then
    rm -f "$QUEUE_FILE"
    exit 0
fi

# Print reminder (this output is shown to the user at session start)
echo ""
echo "=== Pending Summarizations ==="
echo "You have $PENDING session(s) that failed to summarize automatically."
echo ""
if [ "$PENDING" -le 5 ]; then
    while IFS= read -r path; do
        [ -z "$path" ] && continue
        BASENAME=$(basename "$path" .md)
        PROJECT=$(basename "$(dirname "$path")")
        echo "  - $PROJECT / $BASENAME"
    done < "$QUEUE_FILE"
    echo ""
fi
echo "Run /summarize-session for each, or process all at once:"
echo "  while IFS= read -r f; do /summarize-session --file \"\$f\"; done < $QUEUE_FILE"
echo "==============================="
echo ""
