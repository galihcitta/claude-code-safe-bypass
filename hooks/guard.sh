#!/usr/bin/env bash
# Claude Code Guard — Pre-hook safety script
# Blocks or gates destructive commands before execution.
# See plan.md for full design rationale.
#
# Installation:
#   1. Copy hooks/ directory to ~/.claude/hooks/
#   2. Edit patterns.conf — replace YOUR_USERNAME with your macOS username
#   3. Register hooks in settings.json (see settings.json in this repo)
#   4. chmod +x ~/.claude/hooks/guard.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Config — adjust HOME_DIR to your home directory
# ---------------------------------------------------------------------------
GUARD_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${GUARD_DIR}/patterns.conf"
LOG_FILE="${GUARD_DIR}/guard.log"
HOME_DIR="${HOME_DIR:-$HOME}"
STDIN_TIMEOUT=5
DELIMITER=":::"

# ---------------------------------------------------------------------------
# Escape hatch — set CLAUDE_GUARD_OFF=1 to disable
# ---------------------------------------------------------------------------
if [[ "${CLAUDE_GUARD_OFF:-0}" == "1" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Dependency check (fail-safe)
# ---------------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo "BLOCKED: jq is not installed. Guard cannot verify command safety. Install jq to proceed." >&2
  exit 2
fi

if [[ ! -f "$PATTERNS_FILE" ]]; then
  echo "BLOCKED: patterns.conf not found at ${PATTERNS_FILE}. Guard cannot verify command safety." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_event() {
  local action="$1" tool="$2" command="$3" category="$4" reason="$5"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] %-7s | %-5s | %s | %s | %s\n' \
    "$timestamp" "$action" "$tool" "$command" "$category" "$reason" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Read stdin with timeout
# ---------------------------------------------------------------------------
read_stdin() {
  local input=""
  if read -r -t "$STDIN_TIMEOUT" input; then
    local rest=""
    while read -r -t 1 rest; do
      input="${input}
${rest}"
    done
    echo "$input"
  else
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Command normalization
# ---------------------------------------------------------------------------
normalize_command() {
  local cmd="$1"

  # Expand ~ and $HOME to absolute path
  cmd="${cmd//\~/$HOME_DIR}"
  cmd="${cmd//\$HOME/$HOME_DIR}"
  cmd="${cmd//\$\{HOME\}/$HOME_DIR}"

  # Lowercase
  cmd="$(echo "$cmd" | tr '[:upper:]' '[:lower:]')"

  # Collapse whitespace
  cmd="$(echo "$cmd" | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')"

  # Strip 'command ' prefix (used to bypass aliases)
  cmd="$(echo "$cmd" | sed 's/^command //')"

  # Normalize rm flags: combine separate flags into -rf
  cmd="$(echo "$cmd" | sed -E '
    s/rm[[:space:]]+--recursive[[:space:]]+--force/rm -rf/g;
    s/rm[[:space:]]+--force[[:space:]]+--recursive/rm -rf/g;
    s/rm[[:space:]]+-r[[:space:]]+-f/rm -rf/g;
    s/rm[[:space:]]+-f[[:space:]]+-r/rm -rf/g;
    s/rm[[:space:]]+-fr/rm -rf/g;
  ')"

  echo "$cmd"
}

# ---------------------------------------------------------------------------
# Extract inner command from bash -c / sh -c / eval wrappers
# ---------------------------------------------------------------------------
extract_inner_command() {
  local cmd="$1"
  local inner=""

  # Try double-quoted: bash -c "..."
  inner="$(echo "$cmd" | sed -nE 's/.*(bash|sh|zsh)[[:space:]]+-c[[:space:]]+"(.+)".*/\2/p')"

  # Try single-quoted: bash -c '...'
  if [[ -z "$inner" ]]; then
    inner="$(echo "$cmd" | sed -nE "s/.*(bash|sh|zsh)[[:space:]]+-c[[:space:]]+'(.+)'.*/\2/p")"
  fi

  # Try eval "..."
  if [[ -z "$inner" ]]; then
    inner="$(echo "$cmd" | sed -nE 's/.*eval[[:space:]]+"(.+)".*/\1/p')"
  fi

  # Try eval '...'
  if [[ -z "$inner" ]]; then
    inner="$(echo "$cmd" | sed -nE "s/.*eval[[:space:]]+'(.+)'.*/\1/p")"
  fi

  echo "$inner"
}

# ---------------------------------------------------------------------------
# Special pre-checks (handle cases regex can't express in ERE)
# ---------------------------------------------------------------------------
check_git_force_push() {
  local cmd="$1"

  # If it's a git push with --force-with-lease or --force-if-includes, allow it
  if echo "$cmd" | grep -qE 'git[[:space:]]+push\b.*--force-with-lease'; then
    return 1  # not dangerous
  fi
  if echo "$cmd" | grep -qE 'git[[:space:]]+push\b.*--force-if-includes'; then
    return 1  # not dangerous
  fi

  # If it's git push with --force (bare), block it
  if echo "$cmd" | grep -qE 'git[[:space:]]+push\b.*[[:space:]]--force\b'; then
    return 0  # dangerous
  fi

  return 1  # not a force push
}

# Check for case-sensitive git patterns (before lowercasing destroys info)
check_case_sensitive() {
  local cmd="$1"

  # git branch -D (uppercase D = force delete, lowercase d = safe delete)
  if echo "$cmd" | grep -qE 'git[[:space:]]+branch[[:space:]]+-D\b'; then
    echo "ask:::git_risky:::Force-deletes local branch"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Parse a ::: delimited line into parts
# ---------------------------------------------------------------------------
parse_pattern_line() {
  local line="$1"
  P_CATEGORY="$(echo "$line" | awk -F':::' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  P_ACTION="$(echo "$line" | awk -F':::' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  P_PATTERN="$(echo "$line" | awk -F':::' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  P_REASON="$(echo "$line" | awk -F':::' '{for(i=4;i<=NF;i++){if(i>4)printf ":::";printf "%s",$i}}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
}

# ---------------------------------------------------------------------------
# Pattern matching
# ---------------------------------------------------------------------------
match_patterns() {
  local input="$1"
  local tool_type="$2"  # "bash" or "path"

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    parse_pattern_line "$line"

    [[ -z "$P_PATTERN" ]] && continue

    if [[ "$tool_type" == "bash" ]]; then
      [[ "$P_CATEGORY" == "protected_path" || "$P_CATEGORY" == "protected_dotfile" ]] && continue
    fi

    if [[ "$tool_type" == "path" ]]; then
      [[ "$P_CATEGORY" != "protected_path" && "$P_CATEGORY" != "protected_dotfile" ]] && continue
    fi

    if echo "$input" | grep -qE "$P_PATTERN" 2>/dev/null; then
      echo "${P_ACTION}${DELIMITER}${P_CATEGORY}${DELIMITER}${P_REASON}"
      return 0
    fi
  done < "$PATTERNS_FILE"

  return 1
}

# ---------------------------------------------------------------------------
# Handle match result
# ---------------------------------------------------------------------------
handle_match() {
  local match_result="$1"
  local tool="$2"
  local original_cmd="$3"
  local suffix="${4:-}"

  local action category reason
  action="$(echo "$match_result" | awk -F':::' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  category="$(echo "$match_result" | awk -F':::' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  reason="$(echo "$match_result" | awk -F':::' '{for(i=3;i<=NF;i++){if(i>3)printf ":::";printf "%s",$i}}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  log_event "$(echo "$action" | tr '[:lower:]' '[:upper:]')" "$tool" "$original_cmd" "$category" "$reason"

  if [[ "$action" == "block" ]]; then
    echo "BLOCKED: ${reason}${suffix}." >&2
    exit 2
  elif [[ "$action" == "ask" ]]; then
    echo "REQUIRES CONFIRMATION: ${reason}${suffix}. Tell the user what you need and why." >&2
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local tool="${1:-}"
  if [[ -z "$tool" ]]; then
    echo "BLOCKED: guard.sh requires tool name as first argument (bash, edit, write, notebookedit)." >&2
    exit 2
  fi

  local raw_input
  raw_input="$(read_stdin)"

  if [[ -z "$raw_input" ]]; then
    exit 0
  fi

  local check_value=""
  local tool_type=""

  case "$tool" in
    bash)
      tool_type="bash"
      check_value="$(echo "$raw_input" | jq -r '.tool_input.command // .command // empty' 2>/dev/null)" || {
        log_event "ERROR" "$tool" "(parse failure)" "guard_error" "jq failed to parse stdin"
        echo "BLOCKED: Guard failed to parse command input. Blocking for safety." >&2
        exit 2
      }
      ;;
    edit|write|notebookedit)
      tool_type="path"
      check_value="$(echo "$raw_input" | jq -r '.tool_input.file_path // .file_path // empty' 2>/dev/null)" || {
        log_event "ERROR" "$tool" "(parse failure)" "guard_error" "jq failed to parse stdin"
        echo "BLOCKED: Guard failed to parse file path input. Blocking for safety." >&2
        exit 2
      }
      ;;
    *)
      exit 0
      ;;
  esac

  if [[ -z "$check_value" ]]; then
    exit 0
  fi

  if [[ "$tool_type" == "bash" ]]; then
    local cs_result=""
    if cs_result="$(check_case_sensitive "$check_value")"; then
      handle_match "$cs_result" "$tool" "$check_value"
    fi

    local normalized
    normalized="$(normalize_command "$check_value")"

    if check_git_force_push "$normalized"; then
      log_event "BLOCK" "$tool" "$check_value" "git_destructive" "Force push overwrites remote history"
      echo "BLOCKED: Force push overwrites remote history." >&2
      exit 2
    fi

    local match_result=""
    if match_result="$(match_patterns "$normalized" "bash")"; then
      handle_match "$match_result" "$tool" "$check_value"
    fi

    local inner
    inner="$(extract_inner_command "$normalized")"
    if [[ -n "$inner" ]]; then
      local inner_normalized
      inner_normalized="$(normalize_command "$inner")"

      if check_git_force_push "$inner_normalized"; then
        log_event "BLOCK" "$tool" "$check_value (inner)" "git_destructive" "Force push overwrites remote history"
        echo "BLOCKED: Force push overwrites remote history (detected inside nested command)." >&2
        exit 2
      fi

      if match_result="$(match_patterns "$inner_normalized" "bash")"; then
        handle_match "$match_result" "$tool" "$check_value" " (detected inside nested command)"
      fi
    fi

  elif [[ "$tool_type" == "path" ]]; then
    local normalized_path
    normalized_path="${check_value//\~/$HOME_DIR}"
    normalized_path="${normalized_path//\$HOME/$HOME_DIR}"
    normalized_path="${normalized_path//\$\{HOME\}/$HOME_DIR}"
    normalized_path="$(echo "$normalized_path" | tr '[:upper:]' '[:lower:]')"

    local match_result=""
    if match_result="$(match_patterns "$normalized_path" "path")"; then
      handle_match "$match_result" "$tool" "$check_value"
    fi
  fi

  exit 0
}

trap 'log_event "ERROR" "${1:-unknown}" "(crash)" "guard_error" "guard.sh crashed unexpectedly"; echo "GUARD ERROR: guard.sh encountered an unexpected error, blocking for safety." >&2; exit 2' ERR

main "$@"
