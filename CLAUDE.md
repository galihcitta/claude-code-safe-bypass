# Claude Code Safe Bypass

Hook-based guardrails for running Claude Code with `--dangerously-skip-permissions`.

## Project structure

- `hooks/guard.sh` — main guard script, runs as a PreToolUse hook
- `hooks/patterns.conf` — editable pattern definitions (category ::: action ::: regex ::: reason)
- `hooks/settings.json` — hook registration for Claude Code settings
- `install.sh` — one-command installer that copies hooks and configures shell alias
- `plan.md` — full design rationale and architecture decisions

## How it works

The guard intercepts every Bash, Edit, Write, and NotebookEdit tool call via Claude Code's PreToolUse hook system. It normalizes the command (expands ~/​$HOME, lowercases, normalizes flags), matches against regex patterns in patterns.conf, and exits with code 2 to block or code 0 to allow.

Two-tier protection:
- **Hard block** (exit 2 + "BLOCKED:" message) — destructive operations
- **Ask-first** (exit 2 + "REQUIRES CONFIRMATION:" message) — risky but sometimes intentional operations

## Key design decisions

- Uses `:::` as delimiter in patterns.conf because `|` appears in regex patterns
- Uses POSIX ERE (`grep -E`) with `[[:space:]]` instead of `\s` for macOS compatibility
- macOS ships bash 3 which lacks `${var,,}` — uses `tr` for lowercasing
- macOS `sed -E` doesn't support `\s` — uses `[[:space:]]` in sed too
- `git push --force` vs `--force-with-lease` handled by dedicated function since ERE lacks negative lookahead
- `git branch -D` vs `-d` checked before lowercasing via case-sensitive pre-check
- `jq` required for JSON parsing — script blocks all commands if jq is missing (fail-safe)
- Stdin read has 5-second timeout to prevent hanging

## Editing patterns

Add lines to `hooks/patterns.conf`. Changes take effect immediately — no restart needed.

```
category ::: action ::: regex ::: reason
```

## Testing

Run `hooks/test_guard.sh` to verify all patterns work correctly.
