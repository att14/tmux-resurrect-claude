#!/usr/bin/env bash

# helpers.sh — shared utilities for tmux-resurrect-claude
# Platform detection, JSON parsing, process tree walking, tmux option reading.

CLAUDE_SESSIONS_DIR="$HOME/.claude/sessions"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# Read a tmux user option with a default value.
# Usage: _get_option "@resurrect-claude-enabled" "on"
_get_option() {
	local option="$1"
	local default="$2"
	local value
	value="$(tmux show-option -gqv "$option" 2>/dev/null)"
	echo "${value:-$default}"
}

# Get the resurrect save directory.
_get_resurrect_dir() {
	local dir
	dir="$(_get_option "@resurrect-dir" "$HOME/.tmux/resurrect")"
	# Expand ~ if present
	dir="${dir/#\~/$HOME}"
	echo "$dir"
}

# Extract a string value from a JSON object (no jq dependency).
# Reads from stdin. Handles simple flat JSON objects.
# Usage: echo '{"key":"val"}' | _json_str "key"
_json_str() {
	local key="$1"
	sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# Extract a numeric value from a JSON object (no jq dependency).
# Usage: echo '{"pid":123}' | _json_num "pid"
_json_num() {
	local key="$1"
	sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p'
}

# Read a Claude session file by PID.
# Returns the JSON contents, or empty string if file doesn't exist.
_read_session_file() {
	local pid="$1"
	local file="$CLAUDE_SESSIONS_DIR/${pid}.json"
	if [ -f "$file" ]; then
		cat "$file"
	fi
}

# Check whether a Claude conversation is still on disk (not expired).
# Claude retains sessions for ~30 days.
# Usage: _session_exists_on_disk "uuid-here"
_session_exists_on_disk() {
	local session_id="$1"
	# Search the projects directory for the session's JSONL file
	find "$CLAUDE_PROJECTS_DIR" -name "${session_id}.jsonl" -print -quit 2>/dev/null | grep -q .
}

# Get the parent PID of a process.
_get_ppid() {
	local pid="$1"
	ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
}

# Check if a process is still running.
_is_running() {
	local pid="$1"
	kill -0 "$pid" 2>/dev/null
}

# Get the full command-line arguments for a process.
_get_process_args() {
	local pid="$1"
	ps -o args= -p "$pid" 2>/dev/null
}

# Strip the claude binary name and any --resume <id> pair from a command string.
# Returns just the user's CLI flags (e.g., "--dangerously-skip-permissions --plugin-dir foo").
_extract_cli_args() {
	local args="$1"
	# Remove the command name (everything up to and including "claude")
	args="$(echo "$args" | sed 's|^[^ ]*claude[[:space:]]*||')"
	# Remove --resume <value> pair
	args="$(echo "$args" | sed 's/--resume[[:space:]]*[^ ]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	# Remove -r <value> pair (short form)
	args="$(echo "$args" | sed 's/-r[[:space:]]*[^ ]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	# Remove --continue / -c flags
	args="$(echo "$args" | sed 's/--continue//' | sed 's/ -c / /g' | sed 's/^-c //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	echo "$args"
}

# Log a message to tmux's display (visible briefly in the status line).
_log() {
	local msg="$1"
	tmux display-message "resurrect-claude: $msg" 2>/dev/null
}

# Log a message to a file for debugging.
_log_debug() {
	local msg="$1"
	local log_file
	log_file="$(_get_resurrect_dir)/claude_debug.log"
	if [ "$(_get_option "@resurrect-claude-debug" "off")" = "on" ]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$log_file"
	fi
}
