<p align="center">
  <h1 align="center">Claude Code Safe Bypass</h1>
  <p align="center">
    Hook-based guardrails for Claude Code's <code>--dangerously-skip-permissions</code> mode.<br/>
    Auto Mode experience for Pro & Max plan users — without the risk.
  </p>
</p>

<p align="center">
  <a href="#install">Install</a> •
  <a href="#usage">Usage</a> •
  <a href="#what-gets-blocked">What Gets Blocked</a> •
  <a href="#customize">Customize</a>
</p>

---

## Why?

Claude Code just launched [Auto Mode](https://www.anthropic.com) — Claude handles permission decisions automatically. But it's only available on **Team and Enterprise** plans.

If you're on **Pro or Max**, the closest thing is `--dangerously-skip-permissions`. It's fast, but one wrong path and `rm -rf /` executes without asking.

**This project fixes that.** A PreToolUse hook intercepts every command before it runs, blocks the dangerous ones, and lets everything else fly.

## How it works

```
Claude decides to run a tool (Bash, Edit, Write)
    ↓
PreToolUse hook intercepts the call
    ↓
guard.sh normalizes the command
  → expands ~ and $HOME
  → lowercases everything
  → normalizes flags (rm -r -f → rm -rf)
  → unwraps bash -c "..." wrappers
    ↓
Checks against patterns.conf
    ↓
Safe?        → ✅ runs normally
Ask-first?   → ⚠️ blocked with message, you decide
Hard block?  → 🛑 blocked, Claude finds alternative
```

## Install

```bash
git clone https://github.com/galihcitta/claude-code-safe-bypass.git
cd claude-code-safe-bypass
chmod +x install.sh
./install.sh
```

The installer:
1. Copies hooks to `~/.claude/hooks/`
2. Configures patterns with your username
3. Adds a `claudex` alias to your shell

Then open a new terminal or `source ~/.zshrc`.

### Requirements

- macOS or Linux
- `jq` — install with `brew install jq` (macOS) or `apt install jq` (Linux)
- Claude Code 2.1+

## Usage

```bash
claudex     # bypass mode + guard protection
claude      # normal mode with permission prompts (no hooks)
```

Escape hatch — temporarily disable the guard:
```bash
CLAUDE_GUARD_OFF=1 claudex
```

## What gets blocked

### 🛑 Hard Block — always rejected

| Category | Examples |
|---|---|
| **Destructive file ops** | `rm -rf /`, `rm -rf ~`, `rm -rf /usr`, `mkfs`, `dd of=/dev/`, `shred` |
| **Flag evasion** | `rm -r -f /`, `rm --recursive --force /`, `rm -fr /`, `command rm -rf /` |
| **Nested commands** | `bash -c "rm -rf /"`, `sh -c "sudo rm /"` |
| **Database destruction** | `psql -c "DROP TABLE"`, `echo "TRUNCATE" \| mysql` |
| **Git destructive** | `git push --force`, `git push -f`, `git push origin --delete` |
| **Container/infra** | `docker system prune -a`, `kubectl delete namespace`, `terraform destroy` |
| **Privilege escalation** | `sudo`, `doas` |
| **Mass deletion** | `find / -delete`, `xargs rm`, `crontab -r` |

> **Note:** Database patterns only trigger when a DB client (`psql`, `mysql`, `sqlite3`, etc.) is present in the command. `echo "DROP TABLE"` alone won't be blocked.

### ⚠️ Ask-First — blocked with descriptive message

| Category | Examples |
|---|---|
| **Git risky** | `git reset --hard`, `git clean -fd`, `git branch -D`, `git stash drop/clear` |
| **System commands** | `shutdown`, `reboot`, `kill -9`, `killall`, `pkill`, `diskutil` |
| **Dotfile modification** | `~/.zshrc`, `~/.bashrc`, `~/.gitconfig`, `~/.npmrc` |
| **Container risky** | `docker rm -f`, `docker rmi -f`, `brew uninstall` |

### ✅ Explicitly allowed

Safe operations that are **never** blocked:

- `rm -rf node_modules`, `rm -rf dist`, `rm -rf .next`
- `git push` (without `--force`), `git push --force-with-lease`
- `npm install`, `pip install`, `brew install`
- `curl`, `wget`, `ssh`, `scp`
- `kubectl get/describe/logs/top`
- `docker ps`, `docker build`
- All read-only operations

### Write/Edit path protection

| Action | Paths |
|---|---|
| 🛑 Hard block | `/etc/*`, `/usr/*`, `/var/*`, `~/.ssh/*`, `~/.aws/*`, `~/.gnupg/*`, `~/.claude/settings.json` |
| ⚠️ Ask-first | `~/.zshrc`, `~/.bashrc`, `~/.gitconfig` |

## Customize

Edit `~/.claude/hooks/patterns.conf`. Changes take effect immediately — no restart needed.

```
category ::: action ::: regex ::: reason
```

**Add a hard block:**
```
custom ::: block ::: npm[[:space:]]+publish\b ::: Publishing to npm registry
```

**Add an ask-first:**
```
custom ::: ask ::: docker[[:space:]]+stop\b ::: Stopping Docker containers
```

## Audit log

Every blocked command is logged to `~/.claude/hooks/guard.log`:

```
[2026-03-25 14:05:12] BLOCK   | bash  | rm -rf /         | destructive_file | Recursive delete on root
[2026-03-25 14:05:30] ASK     | bash  | git reset --hard  | git_risky        | Discards all uncommitted changes
```

## Architecture

```
~/.claude/hooks/
├── guard.sh          # Main guard script
├── patterns.conf     # Editable pattern definitions
├── settings.json     # Hook registration (loaded by claudex alias)
└── guard.log         # Auto-created audit log
```

**Key design decisions:**
- `:::` delimiter in patterns.conf (because `|` appears in regex)
- POSIX ERE only — no PCRE, works on macOS and Linux
- `exit 2` to block (exit 1 = hook error in Claude Code)
- `$HOME` expansion before matching — catches `~`, `$HOME`, and absolute paths
- `jq` required — script blocks everything if jq is missing (fail-safe)
- Nested command detection — scans inside `bash -c "..."` wrappers

## Known limitations

This is a **safety net for honest mistakes**, not a security boundary.

- Won't catch obfuscated commands (`$(echo cm0gLXJm | base64 -d)`)
- Won't catch multi-step evasion (write a script, then execute it)
- Won't catch scripting one-liners (`python -c 'import shutil; shutil.rmtree("/")'`)
- Won't inspect piped file contents (`mysql < destructive.sql`)

For OS-level protection that covers these gaps, enable [Claude Code sandbox mode](https://docs.anthropic.com/en/docs/claude-code/sandboxing) alongside this hook.

## Author

**Galih Citta** — [@galihcitta](https://github.com/galihcitta)

---

<p align="center">
  <sub>Built with Claude Code. Protected by Claude Code.</sub>
</p>
