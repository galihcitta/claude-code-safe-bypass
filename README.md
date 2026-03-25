# Claude Code Safe Bypass

Run Claude Code with `--dangerously-skip-permissions` while staying protected by hook-based guardrails that block destructive commands before they execute.

## What it does

When Claude Code runs in bypass mode, there are no permission prompts — commands execute immediately. This hook intercepts every tool call and checks it against a pattern list before it runs.

- **Hard block**: destructive operations are rejected outright (rm -rf /, sudo, git push --force, DROP TABLE, terraform destroy, etc.)
- **Ask-first**: risky but sometimes intentional operations are rejected with a descriptive message so you can decide (git reset --hard, shutdown, dotfile modifications, etc.)
- **Allow**: everything else runs without interruption

## How it works

```
Claude decides to run a tool (Bash, Edit, Write)
    ↓
PreToolUse hook intercepts the call
    ↓
guard.sh normalizes the command (expand ~/$HOME, lowercase, normalize flags)
    ↓
Checks against patterns.conf
    ↓
Safe?        → runs normally
Ask-first?   → blocked with message, you decide
Hard block?  → blocked, Claude finds alternative
```

## Install

```bash
git clone <this-repo>
cd claude-code-safe-bypass
chmod +x install.sh
./install.sh
```

The installer:
1. Copies hooks to `~/.claude/hooks/`
2. Replaces `YOUR_USERNAME` in patterns with your actual username
3. Adds a `claudex` alias to your shell

Then open a new terminal or run `source ~/.zshrc`.

## Usage

```bash
claudex          # bypass mode with guard protection
claude            # normal mode with permission prompts (no hooks)
```

To temporarily disable the guard:
```bash
CLAUDE_GUARD_OFF=1 claudex
```

## What gets blocked

### Hard Block (always rejected)

| Category | Examples |
|---|---|
| Destructive file ops | `rm -rf /`, `rm -rf ~`, `rm -rf /usr`, `mkfs`, `dd of=/dev/`, `shred` |
| Flag evasion | `rm -r -f /`, `rm --recursive --force /`, `rm -fr /`, `command rm -rf /` |
| Nested commands | `bash -c "rm -rf /"`, `sh -c "sudo rm /"` |
| Database destruction | `psql -c "DROP TABLE"`, `echo "TRUNCATE" \| mysql` (only when DB client present) |
| Git destructive | `git push --force`, `git push -f`, `git push origin --delete`, `git push origin :branch` |
| Container/infra | `docker system prune -a`, `kubectl delete namespace`, `terraform destroy`, `helm uninstall` |
| Privilege escalation | `sudo`, `doas` |
| Cron destruction | `crontab -r` |
| System symlinks | `ln -sf ... /etc/` |
| Mass deletion | `find / -delete`, `xargs rm` |

### Ask-First (blocked with descriptive message)

| Category | Examples |
|---|---|
| Git risky | `git reset --hard`, `git clean -fd`, `git branch -D`, `git stash drop/clear`, `git checkout -- .` |
| System commands | `shutdown`, `reboot`, `kill -9`, `killall`, `pkill`, `launchctl`, `diskutil`, `csrutil` |
| Dotfile modification | Writing to `~/.zshrc`, `~/.bashrc`, `~/.gitconfig`, `~/.npmrc` |
| Container risky | `docker rm -f`, `docker rmi -f`, `brew uninstall` |

### Explicitly Allowed

- `rm -rf node_modules`, `rm -rf dist`, `rm -rf .next` (safe build dirs)
- `git push` (without `--force`), `git push --force-with-lease` (safe variant)
- `npm install`, `pip install`, `brew install`
- `curl`, `wget`, `ssh`, `scp`
- `kubectl get/describe/logs/top`
- `docker ps`, `docker build`
- All read-only operations

### Write/Edit Path Protection

| Action | Paths |
|---|---|
| Hard block | `/etc/*`, `/usr/*`, `/var/*`, `~/.ssh/*`, `~/.aws/*`, `~/.gnupg/*`, `~/.claude/settings.json` |
| Ask-first | `~/.zshrc`, `~/.bashrc`, `~/.gitconfig` |

## Customize

Edit `~/.claude/hooks/patterns.conf` to add, remove, or change patterns. Format:

```
category ::: action ::: regex ::: reason
```

Example — block npm publish:
```
custom ::: block ::: npm[[:space:]]+publish\b ::: Publishing to npm registry
```

Example — ask before docker stop:
```
custom ::: ask ::: docker[[:space:]]+stop\b ::: Stopping Docker containers
```

No need to restart Claude Code — pattern changes take effect immediately.

## Audit log

Every blocked command is logged to `~/.claude/hooks/guard.log`:

```
[2026-03-23 14:05:12] BLOCK   | bash  | rm -rf / | destructive_file | Recursive delete on root directory
[2026-03-23 14:05:30] ASK     | bash  | git reset --hard | git_risky | Discards all uncommitted changes
```

## Known limitations

- Won't catch obfuscated commands (`$(echo cm0gLXJm | base64 -d)`)
- Won't catch multi-step evasion (write destructive script, then execute it)
- Won't catch scripting one-liners (`python -c 'import shutil; shutil.rmtree("/")'`)
- Won't inspect contents of piped files (`mysql < destructive.sql`)
- Pattern-based, not intent-based — a safety net for honest mistakes, not a security boundary

For OS-level protection that covers these gaps, enable [Claude Code sandbox mode](https://docs.anthropic.com/en/docs/claude-code/sandboxing) alongside this hook.

## Files

```
~/.claude/hooks/
├── guard.sh          # Main guard script
├── patterns.conf     # Editable pattern definitions
├── settings.json     # Hook registration (loaded by claudex)
└── guard.log         # Auto-created audit log
```

## Requirements

- macOS or Linux
- `jq` (`brew install jq`)
- Claude Code 2.1+

## Author

**Galih Citta** — [github.com/galihcitta](https://github.com/galihcitta)
