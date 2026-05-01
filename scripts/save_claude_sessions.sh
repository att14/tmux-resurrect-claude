#!/usr/bin/env bash

# save_claude_sessions.sh — save hook for tmux-resurrect-claude
# Scans all tmux panes for running Claude Code sessions and writes
# their session IDs to a companion state file alongside resurrect's saves.
#
# Triggered by: @resurrect-hook-post-save-all

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

main() {
	# Check master switch
	if [ "$(_get_option "@resurrect-claude-enabled" "on")" != "on" ]; then
		return 0
	fi

	local resurrect_dir state_file pane_list processed_panes count
	resurrect_dir="$(_get_resurrect_dir)"
	state_file="$resurrect_dir/claude_sessions.tsv"
	pane_list="$(mktemp)"
	processed_panes="$(mktemp)"
	count=0

	# Ensure the resurrect directory exists
	mkdir -p "$resurrect_dir"

	# Truncate state file
	: > "$state_file"

	# Build a list of all tmux panes with their shell PIDs
	# Format: pane_pid<TAB>session_name<TAB>window_index<TAB>pane_index<TAB>cwd
	tmux list-panes -a -F "#{pane_pid}	#{session_name}	#{window_index}	#{pane_index}	#{pane_current_path}" > "$pane_list"

	# Scan Claude session files for running sessions that belong to a pane
	if [ -d "$CLAUDE_SESSIONS_DIR" ]; then
		for session_file in "$CLAUDE_SESSIONS_DIR"/*.json; do
			[ -f "$session_file" ] || continue

			local json session_pid session_id kind
			json="$(cat "$session_file")"

			session_pid="$(echo "$json" | _json_num "pid")"
			[ -n "$session_pid" ] || continue

			# Check if the process is still running
			_is_running "$session_pid" || continue

			# Only save interactive sessions
			kind="$(echo "$json" | _json_str "kind")"
			if [ "$kind" != "interactive" ]; then
				_log_debug "Skipping non-interactive session (kind=$kind, pid=$session_pid)"
				continue
			fi

			session_id="$(echo "$json" | _json_str "sessionId")"
			[ -n "$session_id" ] || continue

			# Find which pane this Claude process belongs to by checking its parent
			local ppid pane_info
			ppid="$(_get_ppid "$session_pid")"
			[ -n "$ppid" ] || continue

			pane_info="$(grep "^${ppid}	" "$pane_list")"

			# If direct parent isn't a pane, walk up one more level
			# (handles cases where claude is a child of a child of the shell)
			if [ -z "$pane_info" ]; then
				local grandppid
				grandppid="$(_get_ppid "$ppid")"
				if [ -n "$grandppid" ]; then
					pane_info="$(grep "^${grandppid}	" "$pane_list")"
				fi
			fi

			[ -n "$pane_info" ] || continue

			# Parse pane info
			local pane_session_name pane_window pane_index pane_cwd
			pane_session_name="$(echo "$pane_info" | cut -f2)"
			pane_window="$(echo "$pane_info" | cut -f3)"
			pane_index="$(echo "$pane_info" | cut -f4)"
			pane_cwd="$(echo "$pane_info" | cut -f5)"

			# Skip if we already recorded this pane (dedup multiple session files)
			local pane_key="${pane_session_name}:${pane_window}.${pane_index}"
			if grep -qF "$pane_key" "$processed_panes" 2>/dev/null; then
				_log_debug "Skipping duplicate pane $pane_key for session $session_id"
				continue
			fi
			echo "$pane_key" >> "$processed_panes"

			# Resolve CLI args (sidecar → ps fallback)
			local cli_args
			cli_args="$(_resolve_cli_args "$session_id" "$session_pid")"

			# Use the session file's cwd (more accurate than pane cwd if claude cd'd)
			local session_cwd
			session_cwd="$(echo "$json" | _json_str "cwd")"
			: "${session_cwd:=$pane_cwd}"

			# Write to state file
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$pane_session_name" \
				"$pane_window" \
				"$pane_index" \
				"$session_id" \
				"$session_cwd" \
				"$cli_args" >> "$state_file"

			_log_debug "Saved: session=$pane_session_name window=$pane_window pane=$pane_index id=$session_id"
			count=$((count + 1))
		done
	fi

	rm -f "$pane_list" "$processed_panes"

	if [ "$count" -gt 0 ]; then
		_log "Saved $count Claude session(s)"
	fi
	_log_debug "Save complete: $count session(s)"
}

main
