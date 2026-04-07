# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Single bash script (`setup-claude-ntfy.sh`) that installs Claude Code hooks for push notifications via ntfy.sh. When a Claude Code session completes a task, needs permission, or is idle waiting for input — and the task has exceeded a configurable duration threshold — a notification is sent to the user's device.

## Usage

```bash
bash setup-claude-ntfy.sh --topic "my-topic" --token "tk_xxx" [--threshold 30] [--server "https://ntfy.sh"] [--idle] [--no-permission] [--no-remind]
bash setup-claude-ntfy.sh --version
bash setup-claude-ntfy.sh --history
```

## Architecture

The script performs four operations in sequence:

1. **Config generation** — Writes `~/.claude/hooks/ntfy-config.env` (chmod 600) with topic, token, threshold, and server settings.

2. **Hook script generation** — Creates `~/.claude/hooks/ntfy-notify.sh` with a two-layer design:
   - **Bash layer**: Reads JSON from stdin (Claude Code hook input), extracts `transcript_path`, sources config, passes the full JSON input to Python.
   - **Embedded Python layer**: Parses `hook_event_name` from input to branch on event type. Shared logic: parses the JSONL transcript to find the last external user message, calculates task duration, checks against threshold. Per-event logic:
     - **Stop**: Counts tool usage, extracts `<!-- NTFY: task | outcome -->` markers, sends detailed completion notification.
     - **Notification** (idle_prompt): Sends the `message` field from the hook input as-is.
     - **PermissionRequest**: Sends `tool_name` and description from `tool_input`.

3. **Settings integration** — Merges hooks into `~/.claude/settings.json` under `hooks.Stop`, `hooks.Notification` (with `idle_prompt` matcher), `hooks.PermissionRequest`, and `hooks.UserPromptSubmit` (NTFY marker reminder). Idempotent — updates existing entries or appends new ones, removes disabled events. Hook runs async with 30s timeout.

4. **CLAUDE.md update** — Appends instructions to `~/.claude/CLAUDE.md` telling Claude to include `<!-- NTFY: ... -->` summary markers in responses.

## Key Design Decisions

- Hook always exits 0 on errors to avoid interrupting Claude Code.
- Errors are logged to `~/.claude/hooks/ntfy-errors.log`.
- Timestamps can be ISO strings or Unix epoch (ms or seconds).
- Notification falls back to raw user message (truncated to 200 chars) when no NTFY marker is found.
- Notification titles include the project folder name (from `cwd` in hook input) to identify which Claude session sent the notification.
- Notification (idle_prompt) hook is disabled by default — it fires redundantly after Stop events. Enable with `--idle`.
- UserPromptSubmit reminder hook is enabled by default — injects a one-line NTFY marker reminder each turn to prevent Claude from forgetting in long sessions. Disable with `--no-remind`.
- When no NTFY marker is found, the fallback notification extracts the last assistant text as an outcome summary instead of only showing the raw user prompt.
- The script is idempotent and safe to run multiple times.
- Topic validation rejects short (<10 chars), common/obvious, and low-entropy names with a blocklist + entropy check. Weak-but-long topics get an interactive warning prompt.
- Notification text is auto-capitalized: the first letter of both NTFY marker parts (task and outcome) and fallback user messages are uppercased before sending.

## Security — Sensitive Data Scrubbing

Notifications are sent to an external server, so two layers prevent secret leakage:

1. **CLAUDE.md instructions** — Claude is told never to include passwords, API keys, tokens, secrets, or credentials in `<!-- NTFY: ... -->` markers.

2. **Python `scrub_sensitive()` function** — Defence-in-depth regex filter applied to notification title and body before sending. Catches:
   - Platform-specific token formats (Stripe, GitHub, GitLab, ntfy, Google, AWS, Slack, JWTs, SSH keys)
   - Generic `key=value` / `key: value` patterns where the key name suggests a secret (password, token, api_key, secret, credential, connection_string, etc.)
   - Matched tokens are replaced with `[REDACTED]`; key=value patterns preserve the label (e.g. `password=[REDACTED]`)

## Testing

**Always run both test suites after making changes.** Add or update tests for any new or modified functionality.

```bash
bash test-setup-claude-ntfy.sh    # Integration tests (setup, hooks, Python logic, scrubbing)
bash test-topic-validation.sh     # Topic name validation tests
```

Tests run in a sandboxed `HOME` directory (`mktemp -d`) and never touch the real `~/.claude/` directory.

Manual testing against a real ntfy server:

```bash
# Stop event
echo '{"hook_event_name":"Stop","cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh

# Notification (idle) event
echo '{"hook_event_name":"Notification","message":"Claude is waiting","cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh

# PermissionRequest event
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf node_modules"},"cwd":"/path/to/project","transcript_path":"/path/to/transcript.jsonl"}' | ~/.claude/hooks/ntfy-notify.sh
```

## Workflow

After making changes:
1. **Always run both test suites** — `bash test-setup-claude-ntfy.sh` and `bash test-topic-validation.sh`. All tests must pass.
2. **Update this CLAUDE.md** if the change affects architecture, design decisions, or developer workflow.
3. **Bump version** if the change is functional (see Versioning below).

## Versioning

The script uses semver (`MAJOR.MINOR.PATCH`):
- **PATCH** (1.0.x): Bug fixes, cosmetic tweaks, small behavioural improvements (e.g. capitalization, wording changes, minor format adjustments).
- **MINOR** (1.x.0): New features, new flags, new hook events, or significant behaviour changes.
- **MAJOR** (x.0.0): Breaking changes to config format, hook interface, or CLI arguments.

When making functional changes:
1. Bump `VERSION` near the top of `setup-claude-ntfy.sh`.
2. Add a one-liner to the `HISTORY` heredoc in `setup-claude-ntfy.sh`.

If changes are made shortly after the previous release (same session or same day), fold them into the current version candidate rather than creating a new version number.

## Dependencies

Runtime: `bash`, `python3`. External service: ntfy.sh (or compatible server).
