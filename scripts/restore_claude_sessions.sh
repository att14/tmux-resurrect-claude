#!/usr/bin/env bash

# restore_claude_sessions.sh — restore hook for tmux-resurrect-claude
# Reads the saved Claude session state and resumes sessions in the
# appropriate panes after tmux-resurrect restores the layout.
#
# Triggered by: @resurrect-hook-post-restore-all

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

main() {
	# Check master switch
	if [ "$(_get_option "@resurrect-claude-enabled" "on")" != "on" ]; then
		return 0
	fi

	# Verify claude is available
	if ! command -v claude &>/dev/null; then
		_log_debug "claude not found in PATH, skipping restore"
		return 0
	fi

	local resurrect_dir state_file restore_delay max_age_days
	resurrect_dir="$(_get_resurrect_dir)"
	state_file="$resurrect_dir/claude_sessions.tsv"
	restore_delay="$(_get_option "@resurrect-claude-restore-delay" "0.5")"
	max_age_days="$(_get_option "@resurrect-claude-max-age-days" "30")"

	# Check state file exists and is non-empty
	if [ ! -s "$state_file" ]; then
		_log_debug "No saved Claude sessions found"
		return 0
	fi

	local count skipped max_age_seconds now deduped_file
	count=0
	skipped=0
	max_age_seconds=$((max_age_days * 86400))
	now="$(date +%s)"

	# Dedup entries per pane, keeping the one with the longest cli_args
	deduped_file="$(mktemp)"
	awk -F'\t' '{
		key = $1 ":" $2 "." $3
		if (!(key in seen) || length($6) > length(best[key])) {
			seen[key] = $0
			best[key] = $6
		}
	}
	END { for (key in seen) print seen[key] }' "$state_file" > "$deduped_file"

	while IFS=$'\t' read -r session_name window_index pane_index session_id cwd cli_args; do
		# Skip empty lines
		[ -n "$session_name" ] || continue

		_log_debug "Restoring: session=$session_name window=$window_index pane=$pane_index id=$session_id"

		# Verify the pane exists after resurrect restore
		if ! tmux list-panes -t "${session_name}:${window_index}" -F "#{pane_index}" 2>/dev/null | grep -q "^${pane_index}$"; then
			_log_debug "Pane ${session_name}:${window_index}.${pane_index} not found, skipping"
			skipped=$((skipped + 1))
			continue
		fi

		# Only send keys to idle shell panes — skip panes that already have
		# a process running (happens when resurrect preserves existing panes
		# instead of recreating them from scratch)
		local pane_cmd
		pane_cmd="$(tmux display-message -p -t "${session_name}:${window_index}.${pane_index}" '#{pane_current_command}' 2>/dev/null)"
		case "$pane_cmd" in
			bash|zsh|sh|fish|dash|ksh) ;;
			*)
				_log_debug "Pane ${session_name}:${window_index}.${pane_index} is running '$pane_cmd', skipping"
				skipped=$((skipped + 1))
				continue
				;;
		esac

		# Check if the session conversation still exists on disk
		if ! _session_exists_on_disk "$session_id"; then
			_log_debug "Session $session_id not found on disk (expired?), skipping"
			skipped=$((skipped + 1))
			continue
		fi

		# Fix bare --worktree: resolve to --worktree <path> and cd to main repo
		_fixup_worktree_resume "$cwd" "$cli_args"
		cwd="$_FW_CWD"
		cli_args="$_FW_CLI_ARGS"

		# Persist CLI args to sidecar for future saves
		_write_sidecar_args "$session_id" "$cli_args"

		# Build the resume command (command bypasses aliases to avoid flag doubling)
		local cmd safe_args
		safe_args="$(_shell_quote_model "$cli_args")"
		if [ -n "$safe_args" ]; then
			cmd="command claude $safe_args --resume $session_id"
		else
			cmd="command claude --resume $session_id"
		fi

		# Change to the saved working directory first, then launch claude
		local full_cmd
		if [ -n "$cwd" ] && [ "$cwd" != "." ]; then
			full_cmd="cd $(printf '%q' "$cwd") && $cmd"
		else
			full_cmd="$cmd"
		fi

		# Send the command to the pane
		tmux send-keys -t "${session_name}:${window_index}.${pane_index}" "$full_cmd" C-m

		count=$((count + 1))

		# Delay between pane restores to avoid overwhelming the system
		if [ "$restore_delay" != "0" ]; then
			sleep "$restore_delay"
		fi
	done < "$deduped_file"

	rm -f "$deduped_file"

	if [ "$count" -gt 0 ] || [ "$skipped" -gt 0 ]; then
		_log "Restored $count Claude session(s)$([ "$skipped" -gt 0 ] && echo ", skipped $skipped")"
	fi
	_log_debug "Restore complete: $count restored, $skipped skipped"
}

main
