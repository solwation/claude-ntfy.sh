#!/usr/bin/env bash
# test-topic-validation.sh — Tests for topic validation in setup-claude-ntfy.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-claude-ntfy.sh"

PASS=0
FAIL=0
TOKEN="tk_testtoken1234"

# ── Helpers ─────────────────────────────────────────────────────────

run_setup() {
  # Run setup script with given topic; pipe "n" to reject any interactive prompt
  echo "n" | bash "$SETUP_SCRIPT" --topic "$1" --token "$TOKEN" 2>&1
}

expect_fail() {
  local topic="$1"
  local match="$2"
  local desc="$3"

  output=$(run_setup "$topic") && rc=0 || rc=$?

  if [[ $rc -eq 0 ]]; then
    echo "FAIL: $desc"
    echo "      Expected failure but script succeeded"
    echo "      Output: $output"
    ((FAIL++))
  elif echo "$output" | grep -qi "$match"; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      Expected output to contain '$match'"
    echo "      Output: $output"
    ((FAIL++))
  fi
}

expect_pass() {
  local topic="$1"
  local desc="$2"

  # Use a temp HOME so we don't modify real ~/.claude
  local tmp_home
  tmp_home=$(mktemp -d)
  mkdir -p "$tmp_home/.claude/hooks"

  output=$(HOME="$tmp_home" bash "$SETUP_SCRIPT" --topic "$topic" --token "$TOKEN" 2>&1) && rc=0 || rc=$?

  rm -rf "$tmp_home"

  if [[ $rc -eq 0 ]]; then
    echo "PASS: $desc"
    ((PASS++))
  else
    echo "FAIL: $desc"
    echo "      Expected success but got exit code $rc"
    echo "      Output: $output"
    ((FAIL++))
  fi
}

# ── Tests: too short ────────────────────────────────────────────────

echo "── Too short topics ──"
expect_fail "abc"        "too short" "Reject 3-char topic"
expect_fail "short"      "too short" "Reject 5-char topic"
expect_fail "123456789"  "too short" "Reject 9-char topic (exactly under limit)"

# ── Tests: blocklisted common names ─────────────────────────────────

echo ""
echo "── Blocklisted common topics ──"
expect_fail "notifications" "too common" "Reject 'notifications'"
expect_fail "claude-code"   "too common" "Reject 'claude-code'"
expect_fail "my-notifications" "too common" "Reject 'my-notifications'"
expect_fail "CLAUDE-CODE"   "too common" "Reject 'CLAUDE-CODE' (case insensitive)"
expect_fail "Claude-Notify" "too common" "Reject 'Claude-Notify' (mixed case)"

# Note: some blocklisted words are <10 chars and hit the length check first.
# That's fine — they're still rejected. Let's verify they fail either way:
expect_fail "test"    "too short\|too common" "Reject 'test' (short or common)"
expect_fail "claude"  "too short\|too common" "Reject 'claude' (short or common)"
expect_fail "alerts"  "too short\|too common" "Reject 'alerts' (short or common)"
expect_fail "notify"  "too short\|too common" "Reject 'notify' (short or common)"
expect_fail "topic"   "too short\|too common" "Reject 'topic' (short or common)"
expect_fail "mytopic" "too short\|too common" "Reject 'mytopic' (short or common)"

# ── Tests: low entropy (no digits, no mixed separators) ─────────────

echo ""
echo "── Low entropy topics (interactive warning, answer 'n') ──"
expect_fail "abcdefghijklmno"    "aborted\|warning" "Reject all-alpha topic when user says no"
expect_fail "longwordnodashes"   "aborted\|warning" "Reject long single-word topic when user says no"

# ── Tests: valid topics that should pass ────────────────────────────

echo ""
echo "── Valid topics (should succeed) ──"
expect_pass "anna-claude-x7f9q2"    "Accept topic with digits and separators"
expect_pass "dev-notis-kJm82nXp"    "Accept topic with mixed case and digits"
expect_pass "myproject-12345"        "Accept topic with digits"
expect_pass "foo-bar_baz-qux"       "Accept topic with mixed separators (entropy)"
expect_pass "simple-topic-name"     "Accept multi-segment topic (multiple separators = entropy)"
expect_pass "user1234567890"         "Accept long topic with digits"

# ── Summary ─────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════"

if (( FAIL > 0 )); then
  exit 1
fi
