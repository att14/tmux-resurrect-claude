# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-05-11

### Fixed

- Sanitize resurrect save files to prevent bloat from child process trees.
  The upstream `ps.sh` strategy can dump 200KB+ lines from processes like
  `fsevent_watch`, inflating saves from ~5KB to 1.5MB. These non-record
  lines are never used by restore and are now stripped in the post-save hook.
- Prevent duplicate hook chaining when tmux config is re-sourced.

## [0.3.0] - 2026-05-01

### Added

- Restart with shell reload keybinding (`prefix + Z`). Same as restart but
  sources the shell's rc file before resuming each session, picking up env changes.
  Detects zsh, bash, fish, and falls back to `~/.profile`.
- `@resurrect-claude-source-rc-restart-key` option to configure the keybinding (default: `Z`).

## [0.2.0] - 2026-04-27

### Added

- Restart all running Claude Code sessions with `prefix + R` keybinding.
  Gracefully exits each session (`Escape` + `/exit`, with `Ctrl+C` fallback)
  and resumes with the original flags and working directory.
- `_wait_for_shell` helper function for polling pane state.
- `@resurrect-claude-restart-key` option to configure the restart keybinding (default: `R`).
- `@resurrect-claude-restart-timeout` option to configure exit timeout in seconds (default: `10`).

## [0.1.0] - 2026-04-26

### Added

- Initial implementation of tmux-resurrect-claude.
- Save hook captures running Claude Code sessions (session ID, working directory, CLI flags)
  to `claude_sessions.tsv` alongside tmux-resurrect saves.
- Restore hook resumes Claude Code sessions with `claude --resume` after tmux-resurrect restore.
- CLI flag preservation (`--dangerously-skip-permissions`, `--plugin-dir`, etc.) across save/restore.
- Hook chaining to avoid clobbering other plugins' resurrect hooks.
- `@resurrect-claude-enabled` option to enable/disable the plugin.
- `@resurrect-claude-restore-delay` option to control delay between pane restores.
- `@resurrect-claude-max-age-days` option to skip expired sessions.
- `@resurrect-claude-debug` option for debug logging.

### Fixed

- Skip panes that already have a running process during restore, avoiding
  duplicate sessions when resurrect preserves existing panes.

[0.3.1]: https://github.com/att14/tmux-resurrect-claude/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/att14/tmux-resurrect-claude/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/att14/tmux-resurrect-claude/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/att14/tmux-resurrect-claude/commits/v0.1.0
