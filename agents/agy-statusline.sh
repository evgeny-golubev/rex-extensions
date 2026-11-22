#!/bin/sh
# agy's status line command: saves its input for rex-sidecar and rex-crab-pond,
# which read the model, context window and usage quota from it, then prints
# the model and how full the context is. Set it in
# ~/.gemini/antigravity-cli/settings.json:
#   "statusLine": { "type": "command", "command": "<this file>" }
input=$(cat)
dir="$HOME/.gemini/antigravity-cli/state/statusline"
if command -v jq >/dev/null 2>&1; then
	id=$(printf '%s' "$input" | jq -r '.conversation_id // empty')
	case "$id" in
	*[!A-Za-z0-9-]* | "") ;;
	*) mkdir -p "$dir" && printf '%s' "$input" > "$dir/$id.json" ;;
	esac
	printf '%s' "$input" | jq -r '[.model.display_name // "agy", ("ctx " + ((.context_window.used_percentage // 0) | floor | tostring) + "%")] | join(" · ")'
else
	printf 'agy'
fi
