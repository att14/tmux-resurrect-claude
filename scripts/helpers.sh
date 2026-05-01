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
	ps -ww -o args= -p "$pid" 2>/dev/null
}

# Check if process args were truncated (Claude Code appends ... to long titles).
_is_args_truncated() {
	local args="$1"
	case "$args" in
		*...) return 0 ;;
		*) return 1 ;;
	esac
}

# Get the CLI args sidecar file path.
_get_cli_args_sidecar() {
	echo "$(_get_resurrect_dir)/claude_cli_args.tsv"
}

# Read CLI args for a session from the sidecar file.
_read_sidecar_args() {
	local session_id="$1"
	local sidecar
	sidecar="$(_get_cli_args_sidecar)"
	[ -f "$sidecar" ] || return 0
	grep "^${session_id}	" "$sidecar" 2>/dev/null | tail -1 | cut -f2
}

# Write or update CLI args for a session in the sidecar file.
_write_sidecar_args() {
	local session_id="$1"
	local cli_args="$2"
	local sidecar
	sidecar="$(_get_cli_args_sidecar)"

	if [ -f "$sidecar" ]; then
		local tmp
		tmp="$(mktemp)"
		grep -v "^${session_id}	" "$sidecar" > "$tmp" 2>/dev/null || true
		mv "$tmp" "$sidecar"
	fi

	printf '%s\t%s\n' "$session_id" "$cli_args" >> "$sidecar"
}

# Resolve CLI args for a session: prefer sidecar, fall back to ps.
_resolve_cli_args() {
	local session_id="$1"
	local session_pid="$2"

	local sidecar_args
	sidecar_args="$(_read_sidecar_args "$session_id")"
	if [ -n "$sidecar_args" ]; then
		_log_debug "Using sidecar args for session $session_id"
		echo "$sidecar_args"
		return
	fi

	local process_args cli_args
	process_args="$(_get_process_args "$session_pid")"
	if _is_args_truncated "$process_args"; then
		_log_debug "Warning: process args truncated for pid $session_pid"
	fi
	cli_args="$(_extract_cli_args "$process_args")"
	echo "$cli_args"
}

# Strip the claude binary name and any --resume <id> pair from a command string.
# Returns just the user's CLI flags (e.g., "--dangerously-skip-permissions --plugin-dir foo").
_extract_cli_args() {
	local args="$1"
	# Remove the command name (everything up to and including "claude")
	args="$(echo "$args" | sed 's|^[^ ]*claude[[:space:]]*||')"
	# Remove --resume <value> pair (space-separated) and --resume=<value> (equals form)
	args="$(echo "$args" | sed 's/--resume=[^ ]*//' | sed 's/--resume[[:space:]][[:space:]]*[^ ]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	# Remove -r <value> pair (short form)
	args="$(echo "$args" | sed 's/-r[[:space:]][[:space:]]*[^ ]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	# Remove --continue / -c flags
	args="$(echo "$args" | sed 's/--continue//' | sed 's/ -c / /g' | sed 's/^-c //' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	# Collapse duplicate --dangerously-skip-permissions (alias expansion artifact)
	while echo "$args" | grep -q '\-\-dangerously-skip-permissions.*--dangerously-skip-permissions'; do
		args="$(echo "$args" | sed 's/--dangerously-skip-permissions[[:space:]]*//' | sed 's/^[[:space:]]*//')"
	done
	# Collapse any remaining multi-spaces
	args="$(echo "$args" | sed 's/[[:space:]][[:space:]]*/ /g' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
	echo "$args"
}

# Log a message to tmux's display (visible briefly in the status line).
_log() {
	local msg="$1"
	tmux display-message "resurrect-claude: $msg" 2>/dev/null
}

# Wait for a pane to return to a shell process.
# Polls #{pane_current_command} every 1s until it matches a known shell.
# Returns 0 on success, 1 on timeout (seconds).
# Usage: _wait_for_shell "session:window.pane" 10
_wait_for_shell() {
	local target="$1" timeout="$2"
	local elapsed=0
	while [ "$elapsed" -lt "$timeout" ]; do
		local cmd
		cmd="$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null)"
		case "$cmd" in
			bash|zsh|sh|fish|dash|ksh) return 0 ;;
		esac
		sleep 1
		elapsed=$((elapsed + 1))
	done
	return 1
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
