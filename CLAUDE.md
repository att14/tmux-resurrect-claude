# tmux-resurrect-claude

## Release workflow

After merging a PR that bumps the version in CHANGELOG.md, tag the merge commit on main:

```bash
git tag v<version> <merge-commit-sha>
git push origin v<version>
```
