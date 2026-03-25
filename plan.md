# Claude Code Safe Bypass: Hook-Based Guardrails

## Goal

Run Claude Code with `--dangerously-skip-permissions` for speed, while using hooks to block or gate destructive commands before they execute.

## How It Works

```
You run Claude Code with --dangerously-skip-permissions
    ↓
Claude decides to run a tool (Bash, Edit, Write, etc.)
    ↓
Pre-hook script intercepts the call
    ↓
Script normalizes the command (expand $HOME/~, collapse flags, lowercase)
    ↓
Script inspects the normalized command against pattern lists
    ↓
Safe?        → runs normally, no prompt
Ask-first?   → blocked with descriptive message, Claude tells you what it needs, you decide
Hard block?  → blocked, Claude adapts to a different approach
```

## Two-Tier Protection

### Hard Block (exit 1, generic message)

Commands that are almost never intentional in a coding assistant context. Claude won't suggest retrying — it will find an alternative approach.

### Ask-First (exit 1, descriptive message)

Commands that are sometimes legitimate but carry risk. Claude will explain what it was trying to do and why, then you can:
- Run it yourself with `! command`
- Tell Claude to proceed differently

The difference is in the exit message. Hard blocks say "BLOCKED". Ask-first says "REQUIRES CONFIRMATION" with context.

---

## Prerequisites

- **`jq`** is required for JSON parsing of tool input from stdin. The script checks for `jq` at startup and **blocks all commands** (fail-safe) if `jq` is not found, with a clear error message.

---

## Command Normalization (before pattern matching)

Before matching, the script normalizes the command:

1. **Expand paths**: `~` → `/Users/galihcitta`, `$HOME` → `/Users/galihcitta`
2. **Lowercase**: entire command lowercased for case-insensitive matching
3. **Collapse whitespace**: multiple spaces/tabs → single space
4. **Unwrap nested execution**: scan inside `bash -c "..."`, `sh -c "..."`, `zsh -c "..."`, `eval "..."` and match the inner content against the same patterns
5. **Normalize rm flags**: `rm -r -f` → `rm -rf`, `rm --recursive --force` → `rm -rf`, `rm -fr` → `rm -rf`
6. **Strip `command` prefix**: `command rm -rf /` → `rm -rf /`

This prevents trivial bypasses through flag reordering, tilde/variable forms, or wrapping in `bash -c`.

---

## Bash Command Patterns

### Hard Block — Destructive File Operations

| Pattern | Notes |
|---|---|
| `rm -rf /`, `rm -rf /Users/galihcitta`, `rm -rf /*` | Broad recursive delete on root/home (after normalization) |
| `rm -rf` on system paths (`/usr`, `/etc`, `/var`, `/System`, `/Applications`, `/Library`) | System directory destruction |
| `rm -rf .` or `rm -rf *` (when cwd is root or home) | Wildcard destruction at dangerous scope |
| `mkfs`, `dd if=` writing to devices (`/dev/*`) | Disk formatting/overwriting |
| `shred`, `wipe` | Secure erasure tools |
| `> /dev/sda` or writes to block devices | Device-level destruction |
| `find <broad-path> -delete`, `find <broad-path> -exec rm` | Indirect broad deletion (broad = `/`, `~`, `$HOME`) |
| File truncation on system/sensitive files (`> /etc/...`, `> ~/.ssh/...`, `cat /dev/null > ...`) | Silent content destruction |
| `mv /` or `mv /Users/galihcitta` to dangerous targets | Moving entire root/home |
| `truncate` command on system/sensitive files | Explicit file truncation |
| `xargs rm` piped from broad find | Piped mass deletion |
| `ln -sf` targeting system files (`/etc/*`, `/usr/*`) | Overwriting critical symlinks |

### Hard Block — Database Destructive

Only matched when a **database client is present** in the command (`psql`, `mysql`, `sqlite3`, `mongosh`, `mongo`, `redis-cli`, or piped to one). This prevents false positives from `echo "DROP TABLE"` or comments.

| Pattern | Notes |
|---|---|
| `DROP DATABASE` | Database destruction |
| `DROP TABLE` | Table destruction |
| `TRUNCATE TABLE` or `TRUNCATE` | Mass data deletion |
| `DELETE FROM` without `WHERE` | Unbounded delete |
| `UPDATE ... SET` without `WHERE` | Unbounded update |

### Hard Block — Git Destructive

| Pattern | Notes |
|---|---|
| `git push --force` / `git push -f` | Overwrites remote history |
| `git push origin --delete` | Deletes remote branch |
| `git push origin :<branch>` | Colon syntax remote branch delete |

**Exceptions (not blocked):**
- `git push --force-with-lease` — safe variant, only pushes if no one else pushed since your last fetch
- `git push --force-if-includes` — safe variant

### Hard Block — Container/Infra Destructive

| Pattern | Notes |
|---|---|
| `docker system prune -a` | Removes all unused images/containers |
| `kubectl delete namespace` | Wipes entire namespace |
| `kubectl delete --all` with broad targets | Mass resource deletion |
| `kubectl drain`, `kubectl cordon` | Node-level disruption |
| `terraform destroy` | Infrastructure teardown |
| `helm uninstall` | Release removal |

### Hard Block — Privilege Escalation

| Pattern | Notes |
|---|---|
| `sudo` (any usage) | Privilege escalation |
| `doas` (any usage) | sudo alternative |

### Hard Block — Cron Destruction

| Pattern | Notes |
|---|---|
| `crontab -r` | Removes all cron jobs without confirmation |

---

### Ask-First — Git Risky Operations

| Pattern | Notes |
|---|---|
| `git reset --hard` | Discards uncommitted work |
| `git clean -fd` | Deletes untracked files |
| `git branch -D` | Force-deletes local branch |
| `git stash drop` | Drops a specific stash |
| `git stash clear` | Drops all stashes |
| `git checkout -- .` or `git restore .` | Discards all working changes |

### Ask-First — System-Level Commands

| Pattern | Notes |
|---|---|
| `shutdown`, `reboot`, `halt`, `poweroff` | System power control |
| `kill -9`, `killall`, `pkill` (broad patterns) | Process termination |
| `launchctl` (load/unload/remove/bootout) | macOS service management |
| `defaults write` on system domains | macOS system preferences |
| `diskutil` (erase, partitionDisk, unmount) | Disk management |
| `csrutil` | SIP configuration |

### Ask-First — Dotfile/Config Modification (via Bash)

Matches any Bash command that writes to these paths (including `echo >>`, `sed -i`, `cat >`, `tee`, etc.):

| Pattern | Notes |
|---|---|
| `~/.zshrc`, `~/.bashrc`, `~/.zprofile`, `~/.bash_profile` | Shell profile changes |
| `~/.gitconfig` | Git config changes |
| `~/.npmrc`, `~/.pypirc` | Package manager config |

### Ask-First — Container Risky Operations

| Pattern | Notes |
|---|---|
| `docker rm -f` | Force-remove containers |
| `docker rmi -f` | Force-remove images |
| `kubectl scale --replicas=0` (in production) | Kills all pod instances |
| `kubectl exec` (in production) | Shell into prod containers |
| `kubectl rollout undo`, `kubectl rollout restart` (in production) | Prod deployment changes |

### Ask-First — Package Removal

| Pattern | Notes |
|---|---|
| `brew uninstall`, `brew remove` | Homebrew package removal |

---

## Write/Edit Tool Patterns

### Hard Block — Protected Paths

| Path | Reason |
|---|---|
| `/etc/*`, `/usr/*`, `/var/*` | System configuration |
| `~/.ssh/*` | SSH keys and config |
| `~/.aws/*` | AWS credentials |
| `~/.gnupg/*` | GPG keys |
| `~/.claude/settings.json` | Prevent self-modification of permissions |

### Ask-First — Dotfiles via Write/Edit

| Path | Reason |
|---|---|
| `~/.zshrc`, `~/.bashrc`, `~/.zprofile` | Shell environment changes |
| `~/.gitconfig` | Git configuration |

---

## Kubectl Context Awareness

For kubectl commands, the hook detects the cluster context:
- **Production** (`jkt-prd` in context name): strict blocking — mutating commands are hard blocked
- **Staging** (`jkt-stg` in context name): permissive — most commands allowed
- Detection: checks `--context` flag in the command, falls back to `kubectl config current-context`
- **Read-only commands always allowed**: `get`, `describe`, `logs`, `top`, `config get-contexts`, `api-resources`, `explain`

---

## Allowed (Not Blocked)

These are explicitly **not blocked**, even though they carry some theoretical risk:
- `rm` of specific files or known build dirs (`node_modules`, `dist`, `.next`, `build`, `__pycache__`)
- `rm -rf` with explicit safe targets in project directories
- `curl`, `wget`, `scp`, `ssh` (network/remote — allowed per decision)
- `npm install`, `pip install`, `brew install` (package installation — allowed per decision)
- `git push` (without `--force`)
- `git push --force-with-lease` (safe force push variant)
- `git commit`, `git add`, `git merge`, `git rebase`
- All read-only operations

---

## File Structure

```
~/.claude/hooks/
├── guard.sh              # Main guard script (all logic)
├── patterns.conf         # Editable pattern definitions (categories + patterns)
└── guard.log             # Auto-created, logs blocked/ask-first attempts

~/.claude/settings.json   # Hook registration (updated, not replaced)
```

Single script + config file. No over-engineering.

## guard.sh Design

```
Input:
  - Arg 1: tool name (bash, edit, write, notebookedit)
  - Stdin: JSON with tool parameters (command, file_path, etc.)
  - Stdin read with 5-second timeout to prevent hanging on missing input

Startup checks:
  1. If CLAUDE_GUARD_OFF=1, exit 0 immediately (escape hatch)
  2. Verify jq is available. If not: stderr "BLOCKED: jq not found, guard cannot run safely", exit 1 (fail-safe)

Logic:
  1. Read stdin with timeout (5s). If no input, exit 0 (allow — nothing to check)
  2. Parse tool input with jq
  3. For bash: extract "command" field, normalize:
     a. Expand ~ and $HOME to /Users/galihcitta
     b. Collapse whitespace
     c. Lowercase
     d. Normalize rm flags (separate → combined, long → short)
     e. Strip "command " prefix
     f. Extract inner command from bash -c "...", sh -c "...", eval "..."
  4. For edit/write: extract "file_path" field, expand ~ and $HOME
  5. Match against patterns.conf (bash patterns for bash, path patterns for edit/write)
  6. On match:
     - Log to guard.log (timestamp, tool, command, category, action)
     - If hard-block: stderr "BLOCKED: {reason}", exit 1
     - If ask-first: stderr "REQUIRES CONFIRMATION: {reason}. Tell the user what you need and why.", exit 1
  7. No match: exit 0

Error handling:
  - Any unexpected error in the script itself: log "GUARD ERROR: {details}" to guard.log,
    stderr "GUARD ERROR: guard.sh encountered an unexpected error, blocking for safety", exit 1
  - This ensures the script is fail-safe — a bug blocks rather than allows
```

## patterns.conf Format

```
# category | action | regex pattern | human-readable reason
#
# action: "block" = hard block, "ask" = ask-first
# regex: extended regex, matched against normalized command (lowercase, expanded paths)
# lines starting with # are comments, blank lines ignored

# --- Destructive File Operations ---
destructive_file | block | rm\s+-rf\s+(/|/Users/galihcitta(/|$)|/\*) | Recursive delete on root or home directory
destructive_file | block | rm\s+-rf\s+/(usr|etc|var|System|Applications|Library)\b | Recursive delete on system directory
destructive_file | block | \bmkfs\b | Disk formatting
destructive_file | block | \bdd\s+if=.*\sof=/dev/ | Writing to block device with dd
destructive_file | block | \b(shred|wipe)\b | Secure file erasure
destructive_file | block | >\s*/dev/[a-z] | Redirect to block device
destructive_file | block | find\s+(/|/Users/galihcitta)\s.*-delete | Recursive find-delete on root or home
destructive_file | block | find\s+(/|/Users/galihcitta)\s.*-exec\s+rm | Recursive find-exec-rm on root or home
destructive_file | block | \btruncate\b.*/(etc|usr|var|\.ssh|\.aws|\.gnupg)/ | Truncate system/sensitive files
destructive_file | block | \bln\s+-sf?\s+.*\s+/(etc|usr)/ | Overwriting system symlinks
destructive_file | block | \bxargs\s+rm\b | Piped mass deletion
destructive_file | block | \bmv\s+(/|/Users/galihcitta)\s | Moving root or home directory

# --- Database Destructive (only when DB client present) ---
database | block | (psql|mysql|sqlite3|mongosh|mongo)\s.*\b(drop\s+(database|table)|truncate)\b | Database/table destruction via CLI
database | block | (psql|mysql|sqlite3|mongosh|mongo)\s.*\bdelete\s+from\s+\w+\s*; | DELETE without WHERE via CLI
database | block | (psql|mysql|sqlite3|mongosh|mongo)\s.*\bupdate\s+\w+\s+set\s+.*; | UPDATE without WHERE via CLI
database | block | \|\s*(psql|mysql|sqlite3)\b.*\b(drop\s+(database|table)|truncate)\b | Piped database destruction
database | block | \|\s*(psql|mysql|sqlite3)\b.*\bdelete\s+from\s+\w+\s*; | Piped DELETE without WHERE

# --- Git Destructive ---
git_destructive | block | git\s+push\s+.*--force(?!-(with-lease|if-includes))\b | Force push (excludes safe variants)
git_destructive | block | git\s+push\s+.*\s-f\b | Force push with short flag
git_destructive | block | git\s+push\s+\S+\s+--delete\b | Delete remote branch
git_destructive | block | git\s+push\s+\S+\s+:[^\s] | Colon syntax delete remote branch

# --- Container/Infra Destructive ---
container | block | docker\s+system\s+prune\s+-a | Docker prune all
container | block | kubectl\s+delete\s+namespace | Delete Kubernetes namespace
container | block | kubectl\s+delete\s+.*--all | Mass Kubernetes resource deletion
container | block | kubectl\s+(drain|cordon)\b | Kubernetes node disruption
container | block | terraform\s+destroy | Terraform infrastructure teardown
container | block | helm\s+uninstall | Helm release removal

# --- Privilege Escalation ---
privilege | block | \bsudo\b | Privilege escalation via sudo
privilege | block | \bdoas\b | Privilege escalation via doas

# --- Cron Destruction ---
cron | block | crontab\s+-r\b | Remove all cron jobs

# --- Git Risky (ask-first) ---
git_risky | ask | git\s+reset\s+--hard | Discards all uncommitted changes
git_risky | ask | git\s+clean\s+-[a-zA-Z]*f | Deletes untracked files
git_risky | ask | git\s+branch\s+-D\b | Force-deletes local branch
git_risky | ask | git\s+stash\s+drop | Drops a stash entry
git_risky | ask | git\s+stash\s+clear | Drops all stash entries
git_risky | ask | git\s+(checkout\s+--\s+\.|restore\s+\.) | Discards all working changes

# --- System-Level (ask-first) ---
system | ask | \b(shutdown|reboot|halt|poweroff)\b | System power control
system | ask | \bkill\s+-9\b | Force kill process
system | ask | \b(killall|pkill)\b | Broad process termination
system | ask | \blaunchctl\s+(load|unload|remove|bootout)\b | macOS service management
system | ask | \bdefaults\s+write\b | macOS system preferences modification
system | ask | \bdiskutil\s+(erase|partitionDisk|unmount)\b | Disk management
system | ask | \bcsrutil\b | SIP configuration

# --- Dotfile/Config Modification (ask-first) ---
dotfile | ask | /Users/galihcitta/\.(zshrc|bashrc|zprofile|bash_profile|gitconfig|npmrc|pypirc)\b | Dotfile/config modification

# --- Container Risky (ask-first) ---
container_risky | ask | docker\s+rm\s+-f | Force-remove Docker containers
container_risky | ask | docker\s+rmi\s+-f | Force-remove Docker images
container_risky | ask | brew\s+(uninstall|remove)\b | Homebrew package removal
```

## Hook Registration

In `~/.claude/settings.json` (merged into existing settings, using **absolute paths**):

```json
{
  "hooks": {
    "Bash": [
      {
        "type": "command",
        "command": "/Users/galihcitta/.claude/hooks/guard.sh bash",
        "event": "pre"
      }
    ],
    "Edit": [
      {
        "type": "command",
        "command": "/Users/galihcitta/.claude/hooks/guard.sh edit",
        "event": "pre"
      }
    ],
    "Write": [
      {
        "type": "command",
        "command": "/Users/galihcitta/.claude/hooks/guard.sh write",
        "event": "pre"
      }
    ],
    "NotebookEdit": [
      {
        "type": "command",
        "command": "/Users/galihcitta/.claude/hooks/guard.sh notebookedit",
        "event": "pre"
      }
    ]
  }
}
```

## Logging

Every blocked/ask-first attempt is logged to `~/.claude/hooks/guard.log`:

```
[2026-03-23 14:05:12] BLOCKED | bash | rm -rf / | destructive_file | Recursive delete on root or home directory
[2026-03-23 14:05:30] ASK     | bash | git reset --hard | git_risky | Discards all uncommitted changes
[2026-03-23 14:06:01] ERROR   | bash | (parse failure) | guard_error | jq parse error on stdin
```

## Escape Hatch

Temporarily disable the hook when you intentionally need a blocked command:

```bash
CLAUDE_GUARD_OFF=1 claude --dangerously-skip-permissions
```

## Error Behavior (Fail-Safe)

| Scenario | Behavior |
|---|---|
| `jq` not installed | Block all commands, log error |
| stdin empty or timeout | Allow (nothing to check) |
| JSON parse failure | Block, log error |
| Regex syntax error in patterns.conf | Block, log error |
| guard.sh crashes unexpectedly | Exit non-zero → Claude Code treats as block (safe default) |

The principle: **if the guard can't verify safety, it blocks**. A broken guard never silently allows.

## Known Limitations

- **Obfuscation bypass**: won't catch encoded commands like `$(echo cm0gLXJm | base64 -d)`
- **Multi-step evasion**: won't prevent writing a destructive script to disk then executing it
- **Scripting one-liners**: `python -c 'import shutil; shutil.rmtree("/")'` won't be caught
- **File content inspection**: `mysql < destructive.sql` won't be caught (can't read file contents)
- **Pattern-based, not intent-based**: this is a safety net for honest mistakes, not a security boundary against adversarial attacks
- **Nested wrapping depth**: `bash -c` extraction is one level deep — `bash -c "bash -c \"rm -rf /\""` won't be caught (acceptable tradeoff vs. complexity)

## Next Steps

1. Review and finalize this plan ← you are here
2. Build `guard.sh` and `patterns.conf`
3. Register hooks in `~/.claude/settings.json` (merge, not overwrite)
4. Test with dry-run scenarios (both block and allow cases)
5. Tune patterns as needed
