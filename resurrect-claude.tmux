#!/usr/bin/env bash

# resurrect-claude.tmux — TPM entry point for tmux-resurrect-claude
# Registers save/restore hooks with tmux-resurrect using hook chaining
# so other plugins' hooks are preserved.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Chain a script onto an existing resurrect hook without clobbering it.
# If the hook already has a value (from another plugin or the user),
# append our script with "; " separation.
_chain_hook() {
	local hook_name="$1"
	local script="$2"
	local option="@resurrect-hook-${hook_name}"
	local existing

	existing="$(tmux show-option -gqv "$option" 2>/dev/null)"

	if [ -n "$existing" ]; then
		# Skip if our script is already in the hook (avoids duplication on re-source)
		case "$existing" in
			*"$script"*) return 0 ;;
		esac
		tmux set-option -g "$option" "${existing} ; ${script}"
	else
		tmux set-option -g "$option" "${script}"
	fi
}

_chain_hook "post-save-all" "$CURRENT_DIR/scripts/save_claude_sessions.sh"
_chain_hook "post-restore-all" "$CURRENT_DIR/scripts/restore_claude_sessions.sh"

# Register restart keybinding (default: prefix + R)
restart_key="$(tmux show-option -gqv "@resurrect-claude-restart-key" 2>/dev/null)"
: "${restart_key:=R}"
tmux bind-key "$restart_key" run-shell "$CURRENT_DIR/scripts/restart_claude_sessions.sh"

# Register source-rc restart keybinding (default: prefix + Z)
# Same as restart but sources ~/.zshrc first to pick up env changes
source_rc_restart_key="$(tmux show-option -gqv "@resurrect-claude-source-rc-restart-key" 2>/dev/null)"
: "${source_rc_restart_key:=Z}"
tmux bind-key "$source_rc_restart_key" run-shell "$CURRENT_DIR/scripts/restart_claude_sessions.sh --source-rc"
