#!/usr/bin/env bash
set -euo pipefail

# setup-claude-ntfy.sh — Install Claude Code ntfy.sh notification hook
# Usage: bash ~/setup-claude-ntfy.sh --topic "my-topic" --token "tk_xxx" [--threshold 30] [--server "https://ntfy.sh"]

VERSION="1.0.1"

HISTORY="$(cat << 'HISTEOF'
1.0.1  2026-02-20  Auto-capitalize notification text
  - First letter of task/outcome in NTFY markers is uppercased
  - Fallback (raw user message) text is also capitalized
  - CLAUDE.md instructions updated to request capitalized markers
1.0.0  2026-02-20  Initial versioned release
  - Compact notification format (tool + hostname on one line)
  - Added --version and --history flags
  - Topic validation (length, entropy, blocklist)
  - Sensitive data scrubbing (tokens, key=value patterns)
  - Three hook events: Stop, PermissionRequest, Notification
  - Idempotent installation with settings merge
HISTEOF
)"

# ── Help ────────────────────────────────────────────────────────────
usage() {
  cat << EOF
setup-claude-ntfy.sh — Install Claude Code ntfy.sh notification hook

Get push notifications on your phone when Claude Code finishes a task.

Usage:
  bash $0 --topic TOPIC --token TOKEN [options]

Required:
  --topic TOPIC       ntfy.sh topic name — must be unique and hard to guess
                      (min 10 chars, e.g. "yourname-claude-x7f9q2")
  --token TOKEN       ntfy.sh access token (e.g. "tk_xxx...")

Options:
  --threshold SECS    Minimum task duration to trigger a notification (default: 30)
  --server URL        ntfy-compatible server URL (default: https://ntfy.sh)
  --idle              Enable Notification hook (idle/waiting-for-input alerts, off by default)
  --no-permission     Disable PermissionRequest hook (tool permission alerts)
  --help              Show this help message
  --version           Show version number
  --history           Show full release history

Hook events (all respect --threshold):
  Stop                Always enabled. Fires when Claude finishes a task.
  Notification        Fires when Claude is idle/waiting for input (enable: --idle)
  PermissionRequest   Fires when Claude needs tool permission (disable: --no-permission)

What it installs:
  ~/.claude/hooks/ntfy-config.env   Notification settings (chmod 600)
  ~/.claude/hooks/ntfy-notify.sh    Hook script (shared by all hook events)
  ~/.claude/settings.json           Registers hooks (merged, not overwritten)
  ~/.claude/CLAUDE.md               Adds NTFY summary marker instructions

The script is idempotent — safe to run multiple times to update settings.

Examples:
  bash $0 --topic my-alerts --token tk_abc123
  bash $0 --topic my-alerts --token tk_abc123 --threshold 60
  bash $0 --topic my-alerts --token tk_abc123 --no-idle --no-permission
  bash $0 --topic my-alerts --token tk_abc123 --server https://ntfy.example.com
EOF
}

# ── Parse arguments ──────────────────────────────────────────────────
TOPIC=""
TOKEN=""
THRESHOLD=30
SERVER="https://ntfy.sh"
NOTIFY_IDLE=false
NOTIFY_PERMISSION=true

require_value() { if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value" >&2; exit 1; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)   usage; exit 0 ;;
    --version)   echo "$VERSION"; exit 0 ;;
    --history)   echo "setup-claude-ntfy.sh release history"; echo ""; echo "$HISTORY"; exit 0 ;;
    --topic)     require_value "$@"; TOPIC="$2";     shift 2 ;;
    --token)     require_value "$@"; TOKEN="$2";     shift 2 ;;
    --threshold) require_value "$@"; THRESHOLD="$2"; shift 2 ;;
    --server)    require_value "$@"; SERVER="$2";    shift 2 ;;
    --idle)          NOTIFY_IDLE=true;     shift ;;
    --no-idle)       NOTIFY_IDLE=false;    shift ;;
    --no-permission) NOTIFY_PERMISSION=false; shift ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TOPIC" ]]; then
  echo "Error: --topic is required" >&2
  exit 1
fi
if [[ -z "$TOKEN" ]]; then
  echo "Error: --token is required" >&2
  exit 1
fi

# ── Validate topic uniqueness / complexity ──────────────────────────
# Anyone who knows the topic name can subscribe and read notifications,
# so it must be hard to guess.
TOPIC_LEN=${#TOPIC}

# Reject topics shorter than 10 characters
if (( TOPIC_LEN < 10 )); then
  echo "Error: --topic is too short ($TOPIC_LEN chars). Use at least 10 characters to prevent others from guessing it." >&2
  exit 1
fi

# Reject common/obvious topic names
TOPIC_LOWER=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]')
WEAK_TOPICS="test testing notifications notify alerts claude claude-code claude-notify claude-notifications my-topic my-notifications topic mytopic"
for weak in $WEAK_TOPICS; do
  if [[ "$TOPIC_LOWER" == "$weak" ]]; then
    echo "Error: --topic '$TOPIC' is too common and easy to guess. Use a unique, personal topic name (e.g. 'yourname-claude-x7f9q2')." >&2
    exit 1
  fi
done

# Check that the topic contains at least one digit or mixed separators (some entropy)
if ! [[ "$TOPIC" =~ [0-9] ]] && ! [[ "$TOPIC" =~ [-_].+[-_] ]]; then
  echo "Warning: Your topic '$TOPIC' contains no digits and looks simple." >&2
  echo "         Anyone who guesses it can read your notifications." >&2
  read -r -p "         Continue anyway? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted. Choose a harder-to-guess topic (e.g. add random characters)." >&2
    exit 1
  fi
fi

HOOKS_DIR="$HOME/.claude/hooks"
CLAUDE_DIR="$HOME/.claude"
CONFIG_FILE="$HOOKS_DIR/ntfy-config.env"
HOOK_SCRIPT="$HOOKS_DIR/ntfy-notify.sh"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

mkdir -p "$HOOKS_DIR"

# ── 1. Write config env file ────────────────────────────────────────
# Use printf %q to safely quote values — prevents code execution when sourced
printf 'NTFY_TOPIC=%q\n' "$TOPIC" > "$CONFIG_FILE"
printf 'NTFY_TOKEN=%q\n' "$TOKEN" >> "$CONFIG_FILE"
printf 'NTFY_THRESHOLD=%q\n' "$THRESHOLD" >> "$CONFIG_FILE"
printf 'NTFY_SERVER=%q\n' "$SERVER" >> "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"
echo "✓ Wrote $CONFIG_FILE"

# ── 2. Write hook script ────────────────────────────────────────────
cat > "$HOOK_SCRIPT" << 'HOOKEOF'
#!/usr/bin/env bash
# ntfy-notify.sh — Claude Code notification hook (Stop, Notification, PermissionRequest)
# Receives JSON on stdin with transcript_path + event info, parses it, sends ntfy notification

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/ntfy-config.env"
LOG_FILE="$SCRIPT_DIR/ntfy-errors.log"

log_error() {
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> "$LOG_FILE"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "Config file not found: $CONFIG_FILE"
  exit 0
fi
source "$CONFIG_FILE"

# Read stdin (JSON from Claude Code hook)
INPUT=$(cat)

# Extract transcript_path from the hook input
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
  log_error "No valid transcript_path in input: $INPUT"
  exit 0
fi

# Parse transcript and decide whether to notify
python3 - "$TRANSCRIPT_PATH" "$NTFY_TOPIC" "$NTFY_TOKEN" "$NTFY_THRESHOLD" "$NTFY_SERVER" "$INPUT" << 'PYEOF'
import sys
import json
import socket
import os
import re
import urllib.request
from datetime import datetime, timezone

transcript_path = sys.argv[1]
topic = sys.argv[2]
token = sys.argv[3]
threshold = int(sys.argv[4])
server = sys.argv[5]
hook_input = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {}
hook_event = hook_input.get("hook_event_name", "Stop")
log_file = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])) if sys.argv[0] != '' else '.', '')
log_file = os.path.expanduser("~/.claude/hooks/ntfy-errors.log")

def log_error(msg):
    with open(log_file, "a") as f:
        f.write(f"{datetime.now().isoformat()} {msg}\n")

def scrub_sensitive(text):
    """Remove likely secrets/credentials from notification text."""
    # Token patterns — entire match replaced with [REDACTED]
    token_patterns = [
        r'\b(sk[_-]live[_-][\w-]{8,})',                          # Stripe live keys
        r'\b(sk[_-]test[_-][\w-]{8,})',                          # Stripe test keys
        r'\b(ghp_[a-zA-Z0-9]{36,})',                             # GitHub PATs
        r'\b(github_pat_[a-zA-Z0-9_]{20,})',                     # GitHub fine-grained PATs
        r'\b(gho_[a-zA-Z0-9]{36,})',                             # GitHub OAuth tokens
        r'\b(glpat-[a-zA-Z0-9_-]{20,})',                         # GitLab PATs
        r'\b(tk_[a-zA-Z0-9]{8,})',                               # ntfy tokens
        r'\b(AIza[a-zA-Z0-9_-]{30,})',                           # Google API keys
        r'\b(ya29\.[a-zA-Z0-9_-]{50,})',                         # Google OAuth tokens
        r'\b(AKIA[A-Z0-9]{16})',                                 # AWS access key IDs
        r'\b(xox[bpsar]-[a-zA-Z0-9-]{10,})',                    # Slack tokens
        r'(ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,})',   # SSH public keys
        r'\b(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,})',   # JWTs
    ]
    for pat in token_patterns:
        text = re.sub(pat, '[REDACTED]', text, flags=re.IGNORECASE)
    # Key=value patterns — keep the label, redact only the value
    text = re.sub(
        r'(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|secret[_-]?key|conn(?:ection)?[_-]?string)\s*[=:]\s*)\S+',
        r'\1[REDACTED]',
        text
    )
    return text

try:
    # Read JSONL transcript
    entries = []
    with open(transcript_path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue

    if not entries:
        sys.exit(0)

    # Find last external user message and count tools from that point
    last_user_msg = None
    last_user_msg_ts = None
    last_user_idx = -1

    for i, entry in enumerate(entries):
        if (entry.get("type") == "user"
            and entry.get("userType") == "external"):
            # Extract text content
            message = entry.get("message", {})
            content = message.get("content", "")
            if isinstance(content, list):
                # content blocks — find text
                texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
                text = " ".join(texts).strip()
            elif isinstance(content, str):
                text = content.strip()
            else:
                text = ""

            if text:
                last_user_msg = text
                last_user_msg_ts = entry.get("timestamp")
                last_user_idx = i

    if last_user_msg is None or last_user_msg_ts is None:
        sys.exit(0)

    # Parse timestamp
    try:
        if isinstance(last_user_msg_ts, str):
            ts = datetime.fromisoformat(last_user_msg_ts.replace("Z", "+00:00"))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
        elif isinstance(last_user_msg_ts, (int, float)):
            ts = datetime.fromtimestamp(last_user_msg_ts / 1000 if last_user_msg_ts > 1e12 else last_user_msg_ts, tz=timezone.utc)
        else:
            sys.exit(0)
    except Exception:
        sys.exit(0)

    now = datetime.now(timezone.utc)
    duration_secs = (now - ts).total_seconds()

    if duration_secs < threshold:
        sys.exit(0)

    # Count tool usage and look for NTFY summary from last user message onward
    tool_counts = {}
    ntfy_summary = None
    for entry in entries[last_user_idx + 1:]:
        if entry.get("type") == "assistant":
            message = entry.get("message", {})
            content = message.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        if block.get("type") == "tool_use":
                            tool_name = block.get("name", "unknown")
                            tool_counts[tool_name] = tool_counts.get(tool_name, 0) + 1
                        elif block.get("type") == "text":
                            # Look for <!-- NTFY: ... --> marker
                            m = re.search(r'<!--\s*NTFY:\s*(.+?)\s*-->', block.get("text", ""))
                            if m:
                                ntfy_summary = m.group(1)

    # Format duration
    mins = int(duration_secs) // 60
    secs = int(duration_secs) % 60
    if mins > 0:
        duration_str = f"{mins}m {secs:02d}s"
    else:
        duration_str = f"{secs}s"

    hostname = socket.gethostname()

    # Derive project name from cwd (folder basename), fallback to hostname
    cwd = hook_input.get("cwd", "")
    project_name = os.path.basename(cwd) if cwd else hostname

    # Branch on hook event type
    if hook_event == "Notification":
        message = hook_input.get("message", "Claude is waiting for your input")
        title = f"Claude waiting: {project_name} ({duration_str})"
        body = f"⏳ {message} · 💻 {hostname}"
        tags = "robot,hourglass"

    elif hook_event == "PermissionRequest":
        perm_tool_name = hook_input.get("tool_name", "unknown")
        perm_tool_input = hook_input.get("tool_input", {})
        desc = perm_tool_input.get("description", perm_tool_input.get("command", ""))
        title = f"Claude needs permission: {project_name} ({duration_str})"
        body = f"🔐 {perm_tool_name}"
        if desc:
            body += f"\n📝 {scrub_sensitive(str(desc)[:300])} · 💻 {hostname}"
        else:
            body += f" · 💻 {hostname}"
        tags = "robot,lock"

    else:
        # Stop event (default) — full tool counting and NTFY marker logic
        # Format tool summary
        tool_labels = {
            "Edit": "edits",
            "Write": "writes",
            "Bash": "commands",
            "Read": "reads",
            "Grep": "searches",
            "Glob": "globs",
            "Task": "tasks",
            "WebFetch": "fetches",
            "WebSearch": "web searches",
        }
        tool_parts = []
        for tool, label in tool_labels.items():
            count = tool_counts.get(tool, 0)
            if count > 0:
                tool_parts.append(f"{count} {label}")
        for tool, count in tool_counts.items():
            if tool not in tool_labels and count > 0:
                tool_parts.append(f"{count} {tool}")
        tool_summary = " · ".join(tool_parts) if tool_parts else "no tool usage"

        if ntfy_summary and "|" in ntfy_summary:
            task_part, outcome_part = ntfy_summary.split("|", 1)
            task_part = task_part.strip()
            outcome_part = outcome_part.strip()
            if task_part:
                task_part = task_part[0].upper() + task_part[1:]
            if outcome_part:
                outcome_part = outcome_part[0].upper() + outcome_part[1:]
            title = f"Claude done: {project_name} ({duration_str})"
            body = f"📋 {task_part}\n✅ {outcome_part}\n🔧 {tool_summary} · 💻 {hostname}"
        else:
            # Fallback: raw user message
            task_text = last_user_msg[:200].replace("\n", " ").strip()
            if task_text:
                task_text = task_text[0].upper() + task_text[1:]
            if len(last_user_msg) > 200:
                task_text += "..."
            title = f"Claude done: {project_name} ({duration_str})"
            body = f"📋 {task_text}\n🔧 {tool_summary} · 💻 {hostname}"
        tags = "robot,white_check_mark"

    # Scrub sensitive data before sending
    body = scrub_sensitive(body)
    title = scrub_sensitive(title)

    # Send via urllib (keeps token in-process, not visible in ps/proc)
    req = urllib.request.Request(
        f"{server}/{topic}",
        data=body.encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Title": title,
            "Tags": tags,
        },
        method="POST",
    )
    urllib.request.urlopen(req, timeout=15)

except Exception as e:
    log_error(f"Hook error: {e}")
    sys.exit(0)
PYEOF
HOOKEOF
chmod +x "$HOOK_SCRIPT"
echo "✓ Wrote $HOOK_SCRIPT"

# ── 3. Merge hooks into settings.json ───────────────────────────────
python3 - "$SETTINGS_FILE" "$HOOK_SCRIPT" "$NOTIFY_IDLE" "$NOTIFY_PERMISSION" << 'PYEOF'
import json
import os
import sys

settings_file = sys.argv[1]
hook_command = sys.argv[2]
notify_idle = sys.argv[3] == "true"
notify_permission = sys.argv[4] == "true"

# Load existing settings
settings = {}
if os.path.exists(settings_file):
    with open(settings_file, "r") as f:
        raw = f.read()
    try:
        settings = json.loads(raw)
    except json.JSONDecodeError:
        backup = settings_file + ".bak"
        with open(backup, "w") as f:
            f.write(raw)
        print(f"⚠ settings.json was malformed — backed up to {backup}", file=sys.stderr)
        settings = {}

if "hooks" not in settings:
    settings["hooks"] = {}

def is_ntfy_hook(entry):
    """Check if a hook entry belongs to ntfy-notify.sh."""
    for h in entry.get("hooks", []):
        if h.get("command", "").endswith("ntfy-notify.sh"):
            return True
    return False

def upsert_hook(event_name, hook_entry, enabled):
    """Add/update or remove an ntfy hook entry for the given event."""
    if event_name not in settings["hooks"]:
        settings["hooks"][event_name] = []
    event_hooks = settings["hooks"][event_name]

    # Find existing ntfy entry index
    existing_idx = None
    for i, entry in enumerate(event_hooks):
        if is_ntfy_hook(entry):
            existing_idx = i
            break

    if enabled:
        if existing_idx is not None:
            event_hooks[existing_idx] = hook_entry
        else:
            event_hooks.append(hook_entry)
    else:
        if existing_idx is not None:
            event_hooks.pop(existing_idx)
        # Clean up empty event list
        if not event_hooks:
            del settings["hooks"][event_name]

# Base hook config (shared by all events)
base_hook = {
    "type": "command",
    "command": hook_command,
    "timeout": 30,
    "async": True
}

# Stop — always enabled, no matcher
upsert_hook("Stop", {"hooks": [base_hook]}, True)

# Notification — idle_prompt matcher
upsert_hook("Notification", {
    "matcher": "idle_prompt",
    "hooks": [base_hook]
}, notify_idle)

# PermissionRequest — no matcher (fires for all tools)
upsert_hook("PermissionRequest", {"hooks": [base_hook]}, notify_permission)

with open(settings_file, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print("✓ Updated", settings_file)
PYEOF

# ── 4. Add NTFY instruction to CLAUDE.md ────────────────────────────
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
NTFY_BEGIN='# BEGIN NTFY HOOK'
NTFY_END='# END NTFY HOOK'
NTFY_BLOCK="$NTFY_BEGIN
At the very end of every response, include a one-line notification summary in exactly this format:

<!-- NTFY: [what was asked] | [what was done and key details] -->

Example: <!-- NTFY: Fix failing auth tests | Fixed 3 tests in auth/validate.ts — added null check in validateToken(), updated test fixtures to cover edge case -->
Example: <!-- NTFY: Add dark mode toggle | Added toggle component to settings page with localStorage persistence, updated theme context provider, all 12 tests pass -->

Both sides of the | must start with a capital letter (sentence-style). Be descriptive — include file names, function names, counts, and specifics. Keep each side under 400 characters. This line is parsed by a notification hook and never shown to the user.

SECURITY: Never include passwords, API keys, tokens, secrets, credentials, connection strings, or other sensitive values in the NTFY summary. Describe what was done without reproducing secret values. For example, write 'Updated API key in .env' NOT 'Set API_KEY=sk-live-abc123 in .env'.
$NTFY_END"

if [[ -f "$CLAUDE_MD" ]]; then
  if grep -qF "$NTFY_BEGIN" "$CLAUDE_MD"; then
    # Remove old block — check both markers to avoid deleting to EOF on mismatch
    if grep -qF "$NTFY_END" "$CLAUDE_MD"; then
      sed "/$NTFY_BEGIN/,/$NTFY_END/d" "$CLAUDE_MD" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
    else
      # Only BEGIN found (no END) — remove just that line to be safe
      grep -vF "$NTFY_BEGIN" "$CLAUDE_MD" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
    fi
    # Trim trailing blank lines to prevent accumulation on repeated runs
    python3 -c "import sys;p=sys.argv[1];open(p,'w').write(open(p).read().rstrip()+'\n')" "$CLAUDE_MD"
    printf '\n%s\n' "$NTFY_BLOCK" >> "$CLAUDE_MD"
    echo "✓ Updated NTFY instruction in $CLAUDE_MD"
  else
    printf '\n%s\n' "$NTFY_BLOCK" >> "$CLAUDE_MD"
    echo "✓ Appended NTFY instruction to $CLAUDE_MD"
  fi
else
  printf '%s\n' "$NTFY_BLOCK" > "$CLAUDE_MD"
  echo "✓ Created $CLAUDE_MD"
fi

echo ""
echo "Done! Hooks installed. Configuration:"
echo "  Topic:     $TOPIC"
echo "  Server:    $SERVER"
echo "  Threshold: ${THRESHOLD}s"
echo "  Token:     ${TOKEN:0:8}..."

# Build events list
EVENTS="Stop"
if [[ "$NOTIFY_IDLE" == "true" ]]; then
  EVENTS="$EVENTS, Notification (idle)"
fi
if [[ "$NOTIFY_PERMISSION" == "true" ]]; then
  EVENTS="$EVENTS, PermissionRequest"
fi
echo "  Events:    $EVENTS"

echo ""
echo "To test:"
echo "  Stop:       echo '{\"hook_event_name\":\"Stop\",\"transcript_path\":\"/path/to/transcript.jsonl\"}' | $HOOK_SCRIPT"
echo "  Idle:       echo '{\"hook_event_name\":\"Notification\",\"message\":\"Claude is waiting\",\"transcript_path\":\"/path/to/transcript.jsonl\"}' | $HOOK_SCRIPT"
echo "  Permission: echo '{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"},\"transcript_path\":\"/path/to/transcript.jsonl\"}' | $HOOK_SCRIPT"
