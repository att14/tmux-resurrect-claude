# tmux-resurrect-claude

A [tmux](https://github.com/tmux/tmux) plugin that saves and restores [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions across tmux-resurrect save/restore cycles.

When you save your tmux environment with [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), this plugin captures which Claude Code sessions are running in which panes. When you restore, it automatically resumes each session with `claude --resume`.

## Requirements

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude`)
- bash 3.2+

## Installation with [TPM](https://github.com/tmux-plugins/tpm)

Add to your `~/.tmux.conf`:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'att14/tmux-resurrect-claude'
```

Reload tmux config or press `prefix + I` to install.

## How it works

### Restart (prefix + R)

Restart all running Claude Code sessions in place — useful after changing config, skills, or plugins:

1. Scans all tmux panes for running Claude Code processes
2. Captures each session's state (session ID, working directory, CLI flags)
3. Gracefully exits each session (`Escape` + `/exit`, with `Ctrl+C` fallback)
4. Waits for panes to return to shell
5. Resumes each session with `claude --resume` using the original flags and working directory

### Save (prefix + Ctrl-s)

When tmux-resurrect saves your session, this plugin hooks into the save lifecycle to:

1. Scan all tmux panes for running Claude Code processes
2. Read each process's session metadata from `~/.claude/sessions/<pid>.json`
3. Write a companion state file (`claude_sessions.tsv`) alongside resurrect's own saves

### Restore (prefix + Ctrl-r)

When tmux-resurrect restores your session, this plugin:

1. Reads the saved state file
2. Verifies each session's conversation still exists on disk (sessions expire after 30 days)
3. Sends `claude --resume <session-id>` to each pane that previously had a Claude session

CLI flags from the original session (e.g., `--dangerously-skip-permissions`, `--plugin-dir`) are preserved and passed on resume.

## Configuration

All options are set in `~/.tmux.conf`:

```tmux
# Enable/disable the plugin (default: on)
set -g @resurrect-claude-enabled 'on'

# Seconds to wait between restoring sessions in successive panes (default: 0.5)
set -g @resurrect-claude-restore-delay '0.5'

# Skip sessions older than this many days (default: 30)
set -g @resurrect-claude-max-age-days '30'

# Key to bind for restarting all Claude sessions (default: R)
set -g @resurrect-claude-restart-key 'R'

# Seconds to wait for Claude to exit before falling back to Ctrl+C (default: 10)
set -g @resurrect-claude-restart-timeout '10'

# Enable debug logging to <resurrect-dir>/claude_debug.log (default: off)
set -g @resurrect-claude-debug 'off'
```

## Compatibility

- Works with [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for automatic save/restore
- Chains onto resurrect hooks without clobbering other plugins
- macOS and Linux

## State file format

The plugin writes `claude_sessions.tsv` to the resurrect save directory (default `~/.tmux/resurrect/`). Each line is a tab-delimited record:

```
session_name	window_index	pane_index	claude_session_id	cwd	cli_args
```

## Troubleshooting

**Sessions not being saved:**
- Verify Claude is running interactively (background/print sessions are skipped)
- Enable debug logging: `set -g @resurrect-claude-debug 'on'`
- Check `~/.tmux/resurrect/claude_debug.log`

**Sessions not restoring:**
- Ensure `claude` is in your PATH
- Check that the session hasn't expired (30-day default retention)
- Verify the pane layout was restored correctly by tmux-resurrect first

**Plugin not loading:**
- Run `prefix + I` to install via TPM
- Verify tmux-resurrect is loaded before this plugin in your `.tmux.conf`

## License

[MIT](LICENSE)
