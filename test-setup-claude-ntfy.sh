#!/usr/bin/env bash
set -euo pipefail

# test-setup-claude-ntfy.sh — Tests for setup-claude-ntfy.sh
# Usage: bash test-setup-claude-ntfy.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-claude-ntfy.sh"

# ── Test framework ──────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=""

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "  ✓ %s\n" "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "  ✗ %s\n" "$1"
  FAILURES="${FAILURES}\n  - $1: $2"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc" "expected='$expected' actual='$actual'"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc" "output does not contain '$needle'"
  fi
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc" "output should not contain '$needle'"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -f "$path" ]]; then
    pass "$desc"
  else
    fail "$desc" "file does not exist: $path"
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -f "$path" ]]; then
    pass "$desc"
  else
    fail "$desc" "file should not exist: $path"
  fi
}

assert_file_mode() {
  local desc="$1" path="$2" expected_mode="$3"
  local actual_mode
  actual_mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)
  if [[ "$actual_mode" == "$expected_mode" ]]; then
    pass "$desc"
  else
    fail "$desc" "expected mode $expected_mode, got $actual_mode"
  fi
}

assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc" "expected exit code $expected, got $actual"
  fi
}

section() {
  printf "\n── %s ──\n" "$1"
}

# ── Sandbox setup ───────────────────────────────────────────────────
SANDBOX=$(mktemp -d)
FAKE_HOME="$SANDBOX/fakehome"
mkdir -p "$FAKE_HOME"

cleanup() {
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

# Run setup script with HOME redirected to sandbox
run_setup() {
  HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" "$@" 2>&1
}

# ════════════════════════════════════════════════════════════════════
# PART 1: ARGUMENT PARSING
# ════════════════════════════════════════════════════════════════════
section "Argument parsing"

# --help
output=$(run_setup --help || true)
assert_contains "--help shows usage" "$output" "Usage:"
assert_contains "--help shows topic" "$output" "--topic"

# Missing --topic
output=$(run_setup --token tk_test123 2>&1 || true)
assert_contains "missing --topic errors" "$output" "--topic is required"

# Missing --token
output=$(run_setup --topic my-topic 2>&1 || true)
assert_contains "missing --token errors" "$output" "--token is required"

# Unknown option
output=$(run_setup --topic my-topic --token tk_test123 --bogus 2>&1 || true)
assert_contains "unknown option errors" "$output" "Unknown option"

# --topic without value
output=$(run_setup --topic 2>&1 || true)
assert_contains "--topic without value errors" "$output" "requires a value"

# --token without value
output=$(run_setup --topic my-topic --token 2>&1 || true)
assert_contains "--token without value errors" "$output" "requires a value"

# Exit codes for argument errors
set +e
HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" --topic my-topic 2>/dev/null; code=$?
assert_exit_code "missing token exits non-zero" "1" "$code"

HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" --token tk_test 2>/dev/null; code=$?
assert_exit_code "missing topic exits non-zero" "1" "$code"

HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" --help 2>/dev/null; code=$?
assert_exit_code "--help exits zero" "0" "$code"

# --version
output=$(HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" --version 2>&1); code=$?
assert_exit_code "--version exits zero" "0" "$code"
assert_contains "--version shows version number" "$output" "."

# --history
output=$(HOME="$FAKE_HOME" bash "$SETUP_SCRIPT" --history 2>&1); code=$?
assert_exit_code "--history exits zero" "0" "$code"
assert_contains "--history shows release history" "$output" "release history"
assert_contains "--history includes version entry" "$output" "1.0.0"
set -e

# ════════════════════════════════════════════════════════════════════
# PART 2: SUCCESSFUL INSTALLATION (default settings)
# ════════════════════════════════════════════════════════════════════
section "Successful installation (defaults)"

# Fresh home for this section
FAKE_HOME="$SANDBOX/home_defaults"
mkdir -p "$FAKE_HOME"

output=$(run_setup --topic test-topic-9x7z --token tk_testtoken123)
assert_contains "reports success" "$output" "Done! Hooks installed"

# Config file
assert_file_exists "config file created" "$FAKE_HOME/.claude/hooks/ntfy-config.env"
assert_file_mode "config file is 600" "$FAKE_HOME/.claude/hooks/ntfy-config.env" "600"

config_content=$(cat "$FAKE_HOME/.claude/hooks/ntfy-config.env")
assert_contains "config has topic" "$config_content" "NTFY_TOPIC=test-topic-9x7z"
assert_contains "config has token" "$config_content" "NTFY_TOKEN=tk_testtoken123"
assert_contains "config has threshold" "$config_content" "NTFY_THRESHOLD=30"
assert_contains "config has server" "$config_content" "NTFY_SERVER=https://ntfy.sh"

# Hook script
assert_file_exists "hook script created" "$FAKE_HOME/.claude/hooks/ntfy-notify.sh"
if [[ -x "$FAKE_HOME/.claude/hooks/ntfy-notify.sh" ]]; then
  pass "hook script is executable"
else
  fail "hook script is executable" "not executable"
fi

# Settings file
assert_file_exists "settings.json created" "$FAKE_HOME/.claude/settings.json"
settings_content=$(cat "$FAKE_HOME/.claude/settings.json")
assert_contains "settings has hooks.Stop" "$settings_content" '"Stop"'
assert_contains "settings has ntfy-notify.sh" "$settings_content" "ntfy-notify.sh"
assert_contains "settings has async true" "$settings_content" '"async": true'
assert_contains "settings has timeout 30" "$settings_content" '"timeout": 30'

# CLAUDE.md
assert_file_exists "CLAUDE.md created" "$FAKE_HOME/.claude/CLAUDE.md"
claude_md=$(cat "$FAKE_HOME/.claude/CLAUDE.md")
assert_contains "CLAUDE.md has BEGIN marker" "$claude_md" "# BEGIN NTFY HOOK"
assert_contains "CLAUDE.md has END marker" "$claude_md" "# END NTFY HOOK"
assert_contains "CLAUDE.md has NTFY format" "$claude_md" "<!-- NTFY:"
assert_contains "CLAUDE.md has security warning" "$claude_md" "SECURITY"

# ════════════════════════════════════════════════════════════════════
# PART 3: CUSTOM SETTINGS
# ════════════════════════════════════════════════════════════════════
section "Custom settings"

FAKE_HOME="$SANDBOX/home_custom"
mkdir -p "$FAKE_HOME"

output=$(run_setup --topic custom-topic-4k2 --token tk_custom456 --threshold 120 --server https://ntfy.example.com)
config_content=$(cat "$FAKE_HOME/.claude/hooks/ntfy-config.env")
assert_contains "custom topic" "$config_content" "NTFY_TOPIC=custom-topic-4k2"
assert_contains "custom token" "$config_content" "NTFY_TOKEN=tk_custom456"
assert_contains "custom threshold" "$config_content" "NTFY_THRESHOLD=120"
assert_contains "custom server" "$config_content" "NTFY_SERVER=https://ntfy.example.com"

# Verify summary output shows custom values
assert_contains "summary shows custom topic" "$output" "custom-topic"
assert_contains "summary shows custom server" "$output" "ntfy.example.com"
assert_contains "summary shows custom threshold" "$output" "120s"

# ════════════════════════════════════════════════════════════════════
# PART 4: IDEMPOTENCY
# ════════════════════════════════════════════════════════════════════
section "Idempotency"

FAKE_HOME="$SANDBOX/home_idempotent"
mkdir -p "$FAKE_HOME"

# Run twice
run_setup --topic test-idem-1a --token tk_idem1 >/dev/null
run_setup --topic test-idem-2b --token tk_idem2 --threshold 60 >/dev/null

# Config should have the SECOND run's values
config_content=$(cat "$FAKE_HOME/.claude/hooks/ntfy-config.env")
assert_contains "config updated to second topic" "$config_content" "NTFY_TOPIC=test-idem-2b"
assert_contains "config updated to second token" "$config_content" "NTFY_TOKEN=tk_idem2"
assert_contains "config updated to second threshold" "$config_content" "NTFY_THRESHOLD=60"

# Settings should have exactly 2 ntfy hook entries (Stop+Permission; Notification off by default)
ntfy_count=$(grep -c "ntfy-notify.sh" "$FAKE_HOME/.claude/settings.json")
assert_eq "settings has exactly 2 ntfy hooks (Stop+Permission)" "2" "$ntfy_count"

# CLAUDE.md should have exactly one BEGIN/END block
begin_count=$(grep -c "# BEGIN NTFY HOOK" "$FAKE_HOME/.claude/CLAUDE.md")
end_count=$(grep -c "# END NTFY HOOK" "$FAKE_HOME/.claude/CLAUDE.md")
assert_eq "CLAUDE.md has exactly one BEGIN marker" "1" "$begin_count"
assert_eq "CLAUDE.md has exactly one END marker" "1" "$end_count"

# Run a THIRD time to make sure no accumulation
run_setup --topic test-idem-3c --token tk_idem3 >/dev/null
begin_count=$(grep -c "# BEGIN NTFY HOOK" "$FAKE_HOME/.claude/CLAUDE.md")
assert_eq "CLAUDE.md still one BEGIN after third run" "1" "$begin_count"

# ════════════════════════════════════════════════════════════════════
# PART 5: SETTINGS MERGE (preserves existing settings)
# ════════════════════════════════════════════════════════════════════
section "Settings merge (preserves existing)"

FAKE_HOME="$SANDBOX/home_merge"
mkdir -p "$FAKE_HOME/.claude"

# Pre-populate settings with existing content
cat > "$FAKE_HOME/.claude/settings.json" << 'EOF'
{
  "apiProvider": "anthropic",
  "customApiKey": "sk-test",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/my-other-hook.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF

run_setup --topic merge-topic-5m --token tk_merge >/dev/null

settings_content=$(cat "$FAKE_HOME/.claude/settings.json")
assert_contains "preserves apiProvider" "$settings_content" '"apiProvider"'
assert_contains "preserves existing hook" "$settings_content" "my-other-hook.sh"
assert_contains "adds ntfy hook" "$settings_content" "ntfy-notify.sh"

# ════════════════════════════════════════════════════════════════════
# PART 6: MALFORMED SETTINGS.JSON
# ════════════════════════════════════════════════════════════════════
section "Malformed settings.json"

FAKE_HOME="$SANDBOX/home_malformed"
mkdir -p "$FAKE_HOME/.claude"

echo "this is { not json !!!" > "$FAKE_HOME/.claude/settings.json"

output=$(run_setup --topic mal-topic-6x7 --token tk_mal 2>&1)
assert_contains "warns about malformed settings" "$output" "malformed"
assert_file_exists "backup created" "$FAKE_HOME/.claude/settings.json.bak"

backup_content=$(cat "$FAKE_HOME/.claude/settings.json.bak")
assert_contains "backup has original content" "$backup_content" "this is { not json"

# New settings.json should be valid JSON
python3 -c "import json; json.load(open('$FAKE_HOME/.claude/settings.json'))" 2>/dev/null
assert_exit_code "new settings.json is valid JSON" "0" "$?"

# ════════════════════════════════════════════════════════════════════
# PART 7: CLAUDE.MD — existing file without NTFY block
# ════════════════════════════════════════════════════════════════════
section "CLAUDE.md — append to existing"

FAKE_HOME="$SANDBOX/home_existing_md"
mkdir -p "$FAKE_HOME/.claude"

cat > "$FAKE_HOME/.claude/CLAUDE.md" << 'EOF'
# My Project

Some existing instructions here.
EOF

run_setup --topic md-topic-7y8z --token tk_md >/dev/null

claude_md=$(cat "$FAKE_HOME/.claude/CLAUDE.md")
assert_contains "preserves existing content" "$claude_md" "My Project"
assert_contains "preserves existing instructions" "$claude_md" "Some existing instructions"
assert_contains "appends NTFY block" "$claude_md" "# BEGIN NTFY HOOK"

# ════════════════════════════════════════════════════════════════════
# PART 8: CLAUDE.MD — no trailing blank line accumulation
# ════════════════════════════════════════════════════════════════════
section "CLAUDE.md — no blank line accumulation"

FAKE_HOME="$SANDBOX/home_blanks"
mkdir -p "$FAKE_HOME/.claude"

echo "# Existing" > "$FAKE_HOME/.claude/CLAUDE.md"

run_setup --topic blanks-topic-8z1 --token tk_blanks >/dev/null
run_setup --topic blanks-topic-8z1 --token tk_blanks >/dev/null
run_setup --topic blanks-topic-8z1 --token tk_blanks >/dev/null

# Count consecutive blank lines before BEGIN marker
blank_runs=$(awk '/^$/{c++; if(c>2) found=1} /[^ ]/{c=0} END{print found+0}' "$FAKE_HOME/.claude/CLAUDE.md")
assert_eq "no excessive blank line accumulation" "0" "$blank_runs"

# ════════════════════════════════════════════════════════════════════
# PART 9: HOOK SCRIPT — transcript parsing & notification logic
# ════════════════════════════════════════════════════════════════════
section "Hook script — transcript parsing"

FAKE_HOME="$SANDBOX/home_hook"
mkdir -p "$FAKE_HOME"
run_setup --topic hook-topic-9w2 --token tk_hook --threshold 5 >/dev/null

HOOK="$FAKE_HOME/.claude/hooks/ntfy-notify.sh"

# Helper: create a JSONL transcript file
make_transcript() {
  local file="$SANDBOX/$1"
  shift
  > "$file"
  for line in "$@"; do
    echo "$line" >> "$file"
  done
  echo "$file"
}

# Get a timestamp N seconds ago (ISO format)
ts_ago() {
  python3 -c "
from datetime import datetime, timezone, timedelta
dt = datetime.now(timezone.utc) - timedelta(seconds=$1)
print(dt.strftime('%Y-%m-%dT%H:%M:%S+00:00'))
"
}

# 9a: Missing config file — should exit 0 and log error
section "Hook — missing config"
HOOK_NOCONF="$SANDBOX/noconf-hook"
mkdir -p "$HOOK_NOCONF"
cp "$HOOK" "$HOOK_NOCONF/ntfy-notify.sh"
# No config file in this directory

set +e
echo '{"transcript_path":"/nonexistent"}' | HOME="$FAKE_HOME" bash "$HOOK_NOCONF/ntfy-notify.sh" 2>/dev/null; code=$?
set -e
assert_exit_code "missing config exits 0" "0" "$code"

# 9b: Missing/invalid transcript path — should exit 0
set +e
echo '{}' | HOME="$FAKE_HOME" bash "$HOOK" 2>/dev/null; code=$?
set -e
assert_exit_code "empty input exits 0" "0" "$code"

set +e
echo '{"transcript_path":"/no/such/file.jsonl"}' | HOME="$FAKE_HOME" bash "$HOOK" 2>/dev/null; code=$?
set -e
assert_exit_code "invalid transcript path exits 0" "0" "$code"

# 9c: Below threshold — should NOT send notification (we check exit 0 and no HTTP errors)
section "Hook — below threshold"
ts_recent=$(ts_ago 2)
transcript=$(make_transcript "recent.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_recent\",\"message\":{\"content\":\"do something quick\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

set +e
echo "{\"transcript_path\":\"$transcript\"}" | HOME="$FAKE_HOME" bash "$HOOK" 2>/dev/null; code=$?
set -e
assert_exit_code "below threshold exits 0" "0" "$code"

# 9d: Empty transcript — should exit 0
transcript_empty=$(make_transcript "empty.jsonl")
set +e
echo "{\"transcript_path\":\"$transcript_empty\"}" | HOME="$FAKE_HOME" bash "$HOOK" 2>/dev/null; code=$?
set -e
assert_exit_code "empty transcript exits 0" "0" "$code"

# 9e: No external user message — should exit 0
transcript_no_user=$(make_transcript "nouser.jsonl" \
  "{\"type\":\"user\",\"userType\":\"internal\",\"timestamp\":\"$(ts_ago 60)\",\"message\":{\"content\":\"internal msg\"}}")
set +e
echo "{\"transcript_path\":\"$transcript_no_user\"}" | HOME="$FAKE_HOME" bash "$HOOK" 2>/dev/null; code=$?
set -e
assert_exit_code "no external user message exits 0" "0" "$code"

# ════════════════════════════════════════════════════════════════════
# PART 10: PYTHON LOGIC — unit tests via extracted Python
# ════════════════════════════════════════════════════════════════════
section "Python logic — transcript parsing & formatting"

# We test the Python logic by running it with a mock urllib that records
# the request instead of sending it.

run_python_hook() {
  local transcript_path="$1"
  local threshold="${2:-5}"
  local cwd="${3:-}"

  python3 << PYTEST
import sys
import json
import os
import socket
import re
from datetime import datetime, timezone, timedelta

# --- Mock urllib to capture the request ---
class MockResponse:
    def read(self): return b""
    def __enter__(self): return self
    def __exit__(self, *a): pass

captured = {}
class MockRequest:
    def __init__(self, url, data=None, headers=None, method=None):
        captured["url"] = url
        captured["body"] = data.decode("utf-8") if data else ""
        captured["headers"] = headers or {}
        captured["method"] = method

import unittest.mock
with unittest.mock.patch("urllib.request.Request", MockRequest), \
     unittest.mock.patch("urllib.request.urlopen", lambda req, **kw: MockResponse()):

    # Re-implement the Python part of the hook inline for testing
    transcript_path = "$transcript_path"
    topic = "test-topic"
    token = "tk_test"
    threshold = $threshold
    server = "https://ntfy.sh"
    log_file = "/dev/null"

    def log_error(msg):
        pass

    def scrub_sensitive(text):
        token_patterns = [
            r'\b(sk[_-]live[_-][\w-]{8,})',
            r'\b(sk[_-]test[_-][\w-]{8,})',
            r'\b(ghp_[a-zA-Z0-9]{36,})',
            r'\b(github_pat_[a-zA-Z0-9_]{20,})',
            r'\b(gho_[a-zA-Z0-9]{36,})',
            r'\b(glpat-[a-zA-Z0-9_-]{20,})',
            r'\b(tk_[a-zA-Z0-9]{8,})',
            r'\b(AIza[a-zA-Z0-9_-]{30,})',
            r'\b(ya29\.[a-zA-Z0-9_-]{50,})',
            r'\b(AKIA[A-Z0-9]{16})',
            r'\b(xox[bpsar]-[a-zA-Z0-9-]{10,})',
            r'(ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,})',
            r'\b(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,})',
        ]
        for pat in token_patterns:
            text = re.sub(pat, '[REDACTED]', text, flags=re.IGNORECASE)
        text = re.sub(
            r'(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|secret[_-]?key|conn(?:ection)?[_-]?string)\s*[=:]\s*)\S+',
            r'\1[REDACTED]',
            text
        )
        return text

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
        print("RESULT:NO_ENTRIES")
        sys.exit(0)

    last_user_msg = None
    last_user_msg_ts = None
    last_user_idx = -1

    for i, entry in enumerate(entries):
        if entry.get("type") == "user" and entry.get("userType") == "external":
            message = entry.get("message", {})
            content = message.get("content", "")
            if isinstance(content, list):
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
        print("RESULT:NO_USER_MSG")
        sys.exit(0)

    try:
        if isinstance(last_user_msg_ts, str):
            ts = datetime.fromisoformat(last_user_msg_ts.replace("Z", "+00:00"))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
        elif isinstance(last_user_msg_ts, (int, float)):
            ts = datetime.fromtimestamp(last_user_msg_ts / 1000 if last_user_msg_ts > 1e12 else last_user_msg_ts, tz=timezone.utc)
        else:
            print("RESULT:BAD_TS")
            sys.exit(0)
    except Exception:
        print("RESULT:BAD_TS")
        sys.exit(0)

    now = datetime.now(timezone.utc)
    duration_secs = (now - ts).total_seconds()

    if duration_secs < threshold:
        print("RESULT:BELOW_THRESHOLD")
        sys.exit(0)

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
                            m = re.search(r'<!--\s*NTFY:\s*(.+?)\s*-->', block.get("text", ""))
                            if m:
                                ntfy_summary = m.group(1)

    mins = int(duration_secs) // 60
    secs = int(duration_secs) % 60
    if mins > 0:
        duration_str = f"{mins}m {secs:02d}s"
    else:
        duration_str = f"{secs}s"

    tool_labels = {
        "Edit": "edits", "Write": "writes", "Bash": "commands",
        "Read": "reads", "Grep": "searches", "Glob": "globs",
        "Task": "tasks", "WebFetch": "fetches", "WebSearch": "web searches",
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

    hostname = socket.gethostname()
    cwd = "$cwd"
    project_name = os.path.basename(cwd) if cwd else hostname
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
        task_text = last_user_msg[:200].replace("\n", " ").strip()
        if task_text:
            task_text = task_text[0].upper() + task_text[1:]
        if len(last_user_msg) > 200:
            task_text += "..."
        title = f"Claude done: {project_name} ({duration_str})"
        body = f"📋 {task_text}\n🔧 {tool_summary} · 💻 {hostname}"

    body = scrub_sensitive(body)
    title = scrub_sensitive(title)

    import urllib.request
    req = urllib.request.Request(
        f"{server}/{topic}",
        data=body.encode("utf-8"),
        headers={
            "Authorization": f"Bearer {token}",
            "Title": title,
            "Tags": "robot,white_check_mark",
        },
        method="POST",
    )
    urllib.request.urlopen(req, timeout=15)

    # Output results for test assertions
    print(f"TITLE:{title}")
    print(f"BODY:{body}")
    print(f"URL:{captured.get('url','')}")
    print(f"TOOL_SUMMARY:{tool_summary}")
    print(f"NTFY_SUMMARY:{ntfy_summary}")
PYTEST
}

# 10a: NTFY marker parsing with tool counts
section "Python — NTFY marker + tool counts"
ts_old=$(ts_ago 120)
transcript=$(make_transcript "marker.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"fix the auth bug\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\"},{\"type\":\"tool_use\",\"name\":\"Edit\"},{\"type\":\"tool_use\",\"name\":\"Edit\"},{\"type\":\"tool_use\",\"name\":\"Bash\"},{\"type\":\"text\",\"text\":\"Done! <!-- NTFY: fix auth bug | Fixed null check in validate.ts, updated 2 tests -->\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "title has project name" "$output" "Claude done:"
assert_contains "title has duration" "$output" "m "
assert_contains "body has task from marker (capitalized)" "$output" "Fix auth bug"
assert_contains "body has outcome from marker (already capitalized)" "$output" "Fixed null check"
assert_contains "body has tools icon" "$output" "🔧"
assert_contains "tool summary has edits" "$output" "2 edits"
assert_contains "tool summary has reads" "$output" "1 reads"
assert_contains "tool summary has commands" "$output" "1 commands"
assert_contains "tool summary uses middle dot" "$output" "·"

# 10b: Fallback — no NTFY marker
section "Python — fallback (no marker)"
ts_old=$(ts_ago 45)
transcript=$(make_transcript "nomarker.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"refactor the database module\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"I refactored it.\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "fallback capitalizes user message" "$output" "Refactor the database module"
assert_contains "fallback has task icon" "$output" "📋"
assert_contains "fallback has tools icon" "$output" "🔧"
assert_contains "fallback has no tool usage" "$output" "no tool usage"

# 10c: Long user message truncation
section "Python — long message truncation"
ts_old=$(ts_ago 60)
long_msg=$(python3 -c "print('A' * 300)")
transcript=$(make_transcript "longmsg.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"$long_msg\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "long message is truncated" "$output" "..."
assert_not_contains "truncated to 200 chars" "$output" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

# 10d: Content blocks (list-style content)
section "Python — list-style content blocks"
ts_old=$(ts_ago 60)
transcript=$(make_transcript "blocks.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"add feature X\"},{\"type\":\"text\",\"text\":\"and feature Y\"}]}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "list content joins text blocks (capitalized)" "$output" "Add feature X"
assert_contains "list content includes second block" "$output" "and feature Y"

# 10e: Unix epoch timestamp (milliseconds)
section "Python — epoch timestamp (ms)"
ts_epoch_ms=$(python3 -c "from datetime import datetime, timezone, timedelta; print(int((datetime.now(timezone.utc) - timedelta(seconds=60)).timestamp() * 1000))")
transcript=$(make_transcript "epoch_ms.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":$ts_epoch_ms,\"message\":{\"content\":\"epoch ms test\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "epoch ms: notification sent" "$output" "TITLE:Claude done:"
assert_contains "epoch ms: has user message (capitalized)" "$output" "Epoch ms test"

# 10f: Unix epoch timestamp (seconds)
section "Python — epoch timestamp (seconds)"
ts_epoch_s=$(python3 -c "from datetime import datetime, timezone, timedelta; print(int((datetime.now(timezone.utc) - timedelta(seconds=60)).timestamp()))")
transcript=$(make_transcript "epoch_s.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":$ts_epoch_s,\"message\":{\"content\":\"epoch seconds test\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "epoch s: notification sent" "$output" "TITLE:Claude done:"

# 10g: Z-suffix ISO timestamp
section "Python — Z-suffix timestamp"
ts_z=$(python3 -c "from datetime import datetime, timezone, timedelta; print((datetime.now(timezone.utc) - timedelta(seconds=60)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
transcript=$(make_transcript "ts_z.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_z\",\"message\":{\"content\":\"Z timestamp test\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "Z timestamp: notification sent" "$output" "TITLE:Claude done:"

# 10h: Duration formatting
section "Python — duration formatting"
ts_short=$(ts_ago 45)
transcript=$(make_transcript "dur_short.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_short\",\"message\":{\"content\":\"short task\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")
output=$(run_python_hook "$transcript" 5)
# Under 60s: should show Ns format (no "m")
assert_not_contains "short duration has no minutes" "$output" "m 0"

ts_long=$(ts_ago 185)
transcript=$(make_transcript "dur_long.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_long\",\"message\":{\"content\":\"long task\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")
output=$(run_python_hook "$transcript" 5)
assert_contains "long duration has minutes" "$output" "3m"

# 10i: Below threshold check
section "Python — below threshold"
ts_recent=$(ts_ago 2)
transcript=$(make_transcript "threshold.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_recent\",\"message\":{\"content\":\"quick task\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 30)
assert_contains "below threshold skips notification" "$output" "BELOW_THRESHOLD"

# 10j: Multiple user messages — uses the LAST one
section "Python — last user message wins"
ts_first=$(ts_ago 300)
ts_second=$(ts_ago 60)
transcript=$(make_transcript "multiuser.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_first\",\"message\":{\"content\":\"first message\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_second\",\"message\":{\"content\":\"second message\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "uses last user message (capitalized)" "$output" "Second message"
assert_not_contains "ignores first user message" "$output" "first message"

# 10k: Tool counting — various tools
section "Python — tool counting"
ts_old=$(ts_ago 60)
transcript=$(make_transcript "tools.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"do stuff\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Grep\"},{\"type\":\"tool_use\",\"name\":\"Grep\"},{\"type\":\"tool_use\",\"name\":\"Grep\"},{\"type\":\"tool_use\",\"name\":\"Glob\"},{\"type\":\"tool_use\",\"name\":\"Write\"},{\"type\":\"tool_use\",\"name\":\"WebSearch\"},{\"type\":\"tool_use\",\"name\":\"CustomTool\"},{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "counts Grep" "$output" "3 searches"
assert_contains "counts Glob" "$output" "1 globs"
assert_contains "counts Write" "$output" "1 writes"
assert_contains "counts WebSearch" "$output" "1 web searches"
assert_contains "counts unknown tools" "$output" "1 CustomTool"

# ════════════════════════════════════════════════════════════════════
# PART 11: SCRUB SENSITIVE DATA
# ════════════════════════════════════════════════════════════════════
section "Scrub sensitive data"

test_scrub() {
  local desc="$1" input="$2" expected_contains="$3"
  local result
  result=$(python3 -c "
import re

def scrub_sensitive(text):
    token_patterns = [
        r'\b(sk[_-]live[_-][\w-]{8,})',
        r'\b(sk[_-]test[_-][\w-]{8,})',
        r'\b(ghp_[a-zA-Z0-9]{36,})',
        r'\b(github_pat_[a-zA-Z0-9_]{20,})',
        r'\b(gho_[a-zA-Z0-9]{36,})',
        r'\b(glpat-[a-zA-Z0-9_-]{20,})',
        r'\b(tk_[a-zA-Z0-9]{8,})',
        r'\b(AIza[a-zA-Z0-9_-]{30,})',
        r'\b(ya29\.[a-zA-Z0-9_-]{50,})',
        r'\b(AKIA[A-Z0-9]{16})',
        r'\b(xox[bpsar]-[a-zA-Z0-9-]{10,})',
        r'(ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,})',
        r'\b(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,})',
    ]
    for pat in token_patterns:
        text = re.sub(pat, '[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(
        r'(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|secret[_-]?key|conn(?:ection)?[_-]?string)\s*[=:]\s*)\S+',
        r'\1[REDACTED]',
        text
    )
    return text

print(scrub_sensitive($(python3 -c "import json; print(json.dumps('$input'))")))
")
  assert_contains "$desc" "$result" "$expected_contains"
}

test_scrub_no_secret() {
  local desc="$1" input="$2" forbidden="$3"
  local result
  result=$(python3 -c "
import re

def scrub_sensitive(text):
    token_patterns = [
        r'\b(sk[_-]live[_-][\w-]{8,})',
        r'\b(sk[_-]test[_-][\w-]{8,})',
        r'\b(ghp_[a-zA-Z0-9]{36,})',
        r'\b(github_pat_[a-zA-Z0-9_]{20,})',
        r'\b(gho_[a-zA-Z0-9]{36,})',
        r'\b(glpat-[a-zA-Z0-9_-]{20,})',
        r'\b(tk_[a-zA-Z0-9]{8,})',
        r'\b(AIza[a-zA-Z0-9_-]{30,})',
        r'\b(ya29\.[a-zA-Z0-9_-]{50,})',
        r'\b(AKIA[A-Z0-9]{16})',
        r'\b(xox[bpsar]-[a-zA-Z0-9-]{10,})',
        r'(ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,})',
        r'\b(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,})',
    ]
    for pat in token_patterns:
        text = re.sub(pat, '[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(
        r'(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|secret[_-]?key|conn(?:ection)?[_-]?string)\s*[=:]\s*)\S+',
        r'\1[REDACTED]',
        text
    )
    return text

print(scrub_sensitive($(python3 -c "import json; print(json.dumps('$input'))")))
")
  assert_not_contains "$desc" "$result" "$forbidden"
}

# Token patterns
test_scrub "scrubs Stripe live key" "Updated sk-live-abc123def456 in config" "[REDACTED]"
test_scrub "scrubs GitHub PAT" "Used ghp_abcdefghijklmnopqrstuvwxyz1234567890 for auth" "[REDACTED]"
test_scrub "scrubs ntfy token" "Set tk_abcdefgh12345678 as token" "[REDACTED]"
test_scrub "scrubs AWS key" "Key is AKIAIOSFODNN7EXAMPLE" "[REDACTED]"
test_scrub "scrubs Slack token" "xoxb-abc123def456-ghi" "[REDACTED]"
test_scrub "scrubs GitLab PAT" "glpat-abcdefghijklmnopqrst" "[REDACTED]"

# Key=value patterns
test_scrub "scrubs password=value" "Set password=mysecret123 in env" "password=[REDACTED]"
test_scrub "scrubs api_key=value" "Using api_key=abc123secret" "api_key=[REDACTED]"
test_scrub "scrubs secret: value" "secret: verysecretvalue" "secret: [REDACTED]"
test_scrub "scrubs connection_string=" "connection_string=Server=db;Password=x" "connection_string=[REDACTED]"

# Verify secrets are actually gone
test_scrub_no_secret "Stripe key removed" "sk-live-abc123def456" "sk-live-abc123def456"
test_scrub_no_secret "password value removed" "password=mysecret123" "mysecret123"

# Safe text should pass through unchanged
safe_result=$(python3 -c "
import re
def scrub_sensitive(text):
    token_patterns = [
        r'\b(sk[_-]live[_-][\w-]{8,})',r'\b(sk[_-]test[_-][\w-]{8,})',
        r'\b(ghp_[a-zA-Z0-9]{36,})',r'\b(github_pat_[a-zA-Z0-9_]{20,})',
        r'\b(gho_[a-zA-Z0-9]{36,})',r'\b(glpat-[a-zA-Z0-9_-]{20,})',
        r'\b(tk_[a-zA-Z0-9]{8,})',r'\b(AIza[a-zA-Z0-9_-]{30,})',
        r'\b(ya29\.[a-zA-Z0-9_-]{50,})',r'\b(AKIA[A-Z0-9]{16})',
        r'\b(xox[bpsar]-[a-zA-Z0-9-]{10,})',
        r'(ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+/=]{20,})',
        r'\b(eyJ[a-zA-Z0-9_-]{20,}\.eyJ[a-zA-Z0-9_-]{20,})',
    ]
    for pat in token_patterns:
        text = re.sub(pat, '[REDACTED]', text, flags=re.IGNORECASE)
    text = re.sub(
        r'(?i)((?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential|private[_-]?key|access[_-]?key|secret[_-]?key|conn(?:ection)?[_-]?string)\s*[=:]\s*)\S+',
        r'\1[REDACTED]',
        text
    )
    return text
text = 'Fixed 3 tests in auth/validate.ts, updated config.json'
result = scrub_sensitive(text)
print('MATCH' if result == text else 'CHANGED')
")
assert_eq "safe text passes through unchanged" "MATCH" "$safe_result"

# ════════════════════════════════════════════════════════════════════
# PART 12: SPECIAL CHARACTERS IN CONFIG VALUES
# ════════════════════════════════════════════════════════════════════
section "Special characters in config values"

FAKE_HOME="$SANDBOX/home_special"
mkdir -p "$FAKE_HOME"

run_setup --topic 'my topic with spaces 42' --token 'tk_has$pecial&chars"here' >/dev/null

# Config should be sourceable without errors
set +e
source "$FAKE_HOME/.claude/hooks/ntfy-config.env" 2>/dev/null; code=$?
set -e
assert_exit_code "config is sourceable" "0" "$code"

# ════════════════════════════════════════════════════════════════════
# PART 13: NOTIFICATION URL CONSTRUCTION
# ════════════════════════════════════════════════════════════════════
section "Notification URL construction"

ts_old=$(ts_ago 60)
transcript=$(make_transcript "url_test.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"test url\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "URL is server/topic" "$output" "URL:https://ntfy.sh/test-topic"

# ════════════════════════════════════════════════════════════════════
# PART 14: PROJECT NAME IN TITLES (from cwd)
# ════════════════════════════════════════════════════════════════════
section "Python — project name from cwd"

ts_old=$(ts_ago 60)
transcript=$(make_transcript "projname.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"test project name\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

# With cwd set, title should use folder basename
output=$(run_python_hook "$transcript" 5 "/home/user/projects/my-cool-app")
assert_contains "title uses folder basename" "$output" "TITLE:Claude done: my-cool-app"
title_line=$(echo "$output" | grep "^TITLE:")
assert_not_contains "title does not use hostname" "$title_line" "$(hostname)"
assert_contains "body includes hostname" "$output" "💻 $(hostname)"

# Without cwd, falls back to hostname
output=$(run_python_hook "$transcript" 5 "")
assert_contains "no cwd falls back to hostname" "$output" "TITLE:Claude done: $(hostname)"
assert_contains "body includes hostname without cwd" "$output" "💻 $(hostname)"

# Nested path extracts only the last component
output=$(run_python_hook "$transcript" 5 "/mnt/c/Users/dev/OneDrive/Claude ntfy.sh")
assert_contains "nested path uses basename" "$output" "TITLE:Claude done: Claude ntfy.sh"

# ════════════════════════════════════════════════════════════════════
# PART 15: --idle FLAG (disabled by default)
# ════════════════════════════════════════════════════════════════════
section "Idle notifications disabled by default"

FAKE_HOME="$SANDBOX/home_no_idle"
mkdir -p "$FAKE_HOME"

# Default: should NOT have Notification hook
run_setup --topic idle-test-9z1 --token tk_idle >/dev/null
settings_content=$(cat "$FAKE_HOME/.claude/settings.json")
assert_not_contains "no Notification hook by default" "$settings_content" '"Notification"'
assert_contains "has Stop hook" "$settings_content" '"Stop"'
assert_contains "has PermissionRequest hook" "$settings_content" '"PermissionRequest"'

section "Idle notifications enabled with --idle"

FAKE_HOME="$SANDBOX/home_with_idle"
mkdir -p "$FAKE_HOME"

# With --idle: should have Notification hook
run_setup --topic idle-test-9z2 --token tk_idle2 --idle >/dev/null
settings_content=$(cat "$FAKE_HOME/.claude/settings.json")
assert_contains "Notification hook with --idle" "$settings_content" '"Notification"'
assert_contains "Notification has idle_prompt matcher" "$settings_content" "idle_prompt"

# ════════════════════════════════════════════════════════════════════
# PART 16: AUTO-CAPITALIZATION
# ════════════════════════════════════════════════════════════════════
section "Auto-capitalization of notification text"

# 16a: NTFY marker with lowercase task and outcome
ts_old=$(ts_ago 60)
transcript=$(make_transcript "cap_marker.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"do something\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<!-- NTFY: update config file | changed timeout to 60s -->\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "marker task part capitalized" "$output" "Update config file"
assert_not_contains "marker task part not lowercase" "$output" "📋 update config"
assert_contains "marker outcome part capitalized" "$output" "Changed timeout to 60s"
assert_not_contains "marker outcome part not lowercase" "$output" "✅ changed timeout"

# 16b: Already-capitalized marker passes through unchanged
transcript=$(make_transcript "cap_already.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"do something\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<!-- NTFY: Fix auth bug | Added null check in validate.ts -->\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "already-capitalized task unchanged" "$output" "Fix auth bug"
assert_contains "already-capitalized outcome unchanged" "$output" "Added null check"

# 16c: Fallback (no marker) capitalizes user message
transcript=$(make_transcript "cap_fallback.jsonl" \
  "{\"type\":\"user\",\"userType\":\"external\",\"timestamp\":\"$ts_old\",\"message\":{\"content\":\"refactor the login flow\"}}" \
  "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}")

output=$(run_python_hook "$transcript" 5)
assert_contains "fallback text capitalized" "$output" "Refactor the login flow"
assert_not_contains "fallback text not lowercase" "$output" "📋 refactor the"

# ════════════════════════════════════════════════════════════════════
# SUMMARY
# ════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════"
printf "Tests: %d passed, %d failed, %d total\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN"
echo "════════════════════════════════════════════════"

if [[ $TESTS_FAILED -gt 0 ]]; then
  printf "\nFailures:%b\n" "$FAILURES"
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
