#!/usr/bin/env bash

# restart_claude_sessions.sh — restart all running Claude Code sessions
# Captures state from live processes, gracefully exits each session,
# waits for panes to return to shell, then resumes each session.
#
# Triggered by: keybinding (default: prefix + R)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

main() {
	local source_rc=0
	if [ "${1:-}" = "--source-rc" ]; then
		source_rc=1
	fi

	# Check master switch
	if [ "$(_get_option "@resurrect-claude-enabled" "on")" != "on" ]; then
		return 0
	fi

	# Verify claude is available
	if ! command -v claude &>/dev/null; then
		_log "claude not found in PATH"
		return 1
	fi

	local restart_timeout restore_delay
	restart_timeout="$(_get_option "@resurrect-claude-restart-timeout" "10")"
	restore_delay="$(_get_option "@resurrect-claude-restore-delay" "0.5")"

	# Phase 1: Capture state from live processes
	local pane_list captured processed_panes
	pane_list="$(mktemp)"
	captured="$(mktemp)"
	processed_panes="$(mktemp)"

	# Build a list of all tmux panes with their shell PIDs
	tmux list-panes -a -F "#{pane_pid}	#{session_name}	#{window_index}	#{pane_index}	#{pane_current_path}" > "$pane_list"

	if [ ! -d "$CLAUDE_SESSIONS_DIR" ]; then
		_log "No Claude sessions found"
		rm -f "$pane_list" "$captured"
		return 0
	fi

	for session_file in "$CLAUDE_SESSIONS_DIR"/*.json; do
		[ -f "$session_file" ] || continue

		local json session_pid session_id kind
		json="$(cat "$session_file")"

		session_pid="$(echo "$json" | _json_num "pid")"
		[ -n "$session_pid" ] || continue

		_is_running "$session_pid" || continue

		kind="$(echo "$json" | _json_str "kind")"
		if [ "$kind" != "interactive" ]; then
			_log_debug "Restart: skipping non-interactive session (kind=$kind, pid=$session_pid)"
			continue
		fi

		session_id="$(echo "$json" | _json_str "sessionId")"
		[ -n "$session_id" ] || continue

		# Find which pane this Claude process belongs to
		local ppid pane_info
		ppid="$(_get_ppid "$session_pid")"
		[ -n "$ppid" ] || continue

		pane_info="$(grep "^${ppid}	" "$pane_list")"

		if [ -z "$pane_info" ]; then
			local grandppid
			grandppid="$(_get_ppid "$ppid")"
			if [ -n "$grandppid" ]; then
				pane_info="$(grep "^${grandppid}	" "$pane_list")"
			fi
		fi

		[ -n "$pane_info" ] || continue

		local pane_session_name pane_window pane_index
		pane_session_name="$(echo "$pane_info" | cut -f2)"
		pane_window="$(echo "$pane_info" | cut -f3)"
		pane_index="$(echo "$pane_info" | cut -f4)"

		# Skip duplicate panes
		local pane_key="${pane_session_name}:${pane_window}.${pane_index}"
		if grep -qF "$pane_key" "$processed_panes" 2>/dev/null; then
			_log_debug "Restart: skipping duplicate pane $pane_key"
			continue
		fi
		echo "$pane_key" >> "$processed_panes"

		# Resolve CLI args (sidecar → ps fallback)
		local cli_args
		cli_args="$(_resolve_cli_args "$session_id" "$session_pid")"

		# Use the session file's cwd
		local session_cwd pane_cwd
		pane_cwd="$(echo "$pane_info" | cut -f5)"
		session_cwd="$(echo "$json" | _json_str "cwd")"
		: "${session_cwd:=$pane_cwd}"

		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$pane_session_name" \
			"$pane_window" \
			"$pane_index" \
			"$session_id" \
			"$session_cwd" \
			"$cli_args" >> "$captured"

		_log_debug "Restart: captured session=$pane_session_name window=$pane_window pane=$pane_index id=$session_id"
	done

	rm -f "$pane_list" "$processed_panes"

	if [ ! -s "$captured" ]; then
		_log "No running Claude sessions found"
		rm -f "$captured"
		return 0
	fi

	local total
	total="$(wc -l < "$captured" | tr -d ' ')"
	_log "Restarting $total Claude session(s)..."

	# Phase 2: Gracefully exit each session
	while IFS=$'\t' read -r session_name window_index pane_index session_id cwd cli_args; do
		[ -n "$session_name" ] || continue
		local target="${session_name}:${window_index}.${pane_index}"

		_log_debug "Restart: sending exit to $target"

		# Escape to cancel any pending operation, then /exit
		tmux send-keys -t "$target" Escape
		sleep 0.1
		tmux send-keys -t "$target" "/exit" C-m
	done < "$captured"

	# Phase 2b: Wait for all sessions to exit
	local exited failed
	exited="$(mktemp)"
	failed=0

	while IFS=$'\t' read -r session_name window_index pane_index session_id cwd cli_args; do
		[ -n "$session_name" ] || continue
		local target="${session_name}:${window_index}.${pane_index}"

		if _wait_for_shell "$target" "$restart_timeout"; then
			_log_debug "Restart: $target returned to shell"
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$session_name" "$window_index" "$pane_index" \
				"$session_id" "$cwd" "$cli_args" >> "$exited"
		else
			# Fallback: send Ctrl+C and wait again
			_log_debug "Restart: $target timed out, sending Ctrl+C"
			tmux send-keys -t "$target" C-c
			sleep 0.5
			tmux send-keys -t "$target" "/exit" C-m

			if _wait_for_shell "$target" "$restart_timeout"; then
				_log_debug "Restart: $target returned to shell after Ctrl+C"
				printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
					"$session_name" "$window_index" "$pane_index" \
					"$session_id" "$cwd" "$cli_args" >> "$exited"
			else
				_log_debug "Restart: $target failed to exit, skipping"
				failed=$((failed + 1))
			fi
		fi
	done < "$captured"

	rm -f "$captured"

	# Phase 3: Resume sessions
	local restarted=0

	while IFS=$'\t' read -r session_name window_index pane_index session_id cwd cli_args; do
		[ -n "$session_name" ] || continue
		local target="${session_name}:${window_index}.${pane_index}"

		# Persist CLI args to sidecar for future saves
		_write_sidecar_args "$session_id" "$cli_args"

		# Build resume command (command bypasses aliases to avoid flag doubling)
		local cmd
		if [ -n "$cli_args" ]; then
			cmd="command claude $cli_args --resume $session_id"
		else
			cmd="command claude --resume $session_id"
		fi

		local full_cmd=""
		if [ "$source_rc" -eq 1 ]; then
			local pane_shell
			pane_shell="$(tmux display-message -p -t "$target" '#{pane_current_command}')"
			case "$pane_shell" in
				fish) full_cmd="source ~/.config/fish/config.fish; and " ;;
				bash) full_cmd="source ~/.bashrc && " ;;
				zsh)  full_cmd="source ~/.zshrc && " ;;
				*)    full_cmd="source ~/.profile && " ;;
			esac
		fi
		if [ -n "$cwd" ] && [ "$cwd" != "." ]; then
			full_cmd+="cd $(printf '%q' "$cwd") && $cmd"
		else
			full_cmd+="$cmd"
		fi

		_log_debug "Restart: resuming $target with: $full_cmd"
		tmux send-keys -t "$target" "$full_cmd" C-m

		restarted=$((restarted + 1))

		if [ "$restore_delay" != "0" ]; then
			sleep "$restore_delay"
		fi
	done < "$exited"

	rm -f "$exited"

	_log "Restarted $restarted session(s)$([ "$failed" -gt 0 ] && echo ", $failed failed")"
	_log_debug "Restart complete: $restarted restarted, $failed failed"
}

main "$@"
