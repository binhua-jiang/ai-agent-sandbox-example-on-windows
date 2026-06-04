#!/usr/bin/env bash
# Claude Code CLI wrapper.
#
# Default behaviour (CLAUDE_USE_BWRAP unset or 0): pass through to the real
# claude binary. Container layer + Claude's built-in sandbox + the deny
# rules in .claude/settings.json are the standard isolation.
#
# Opt-in behaviour (CLAUDE_USE_BWRAP=1): wrap the entire claude process in
# bubblewrap as an extra kernel-level isolation layer (tmpfs / ro-bind /
# ro-bind-self per .devcontainer/bwrap-policy.conf). This defends against
# MCP tools or other in-process file accesses that bypass Claude's
# permission rules. Linux/WSL2 only. If bwrap is requested but cannot
# create user namespaces, the wrapper hard-fails rather than degrading.

set -euo pipefail

if [[ -z "${WORKSPACE_ROOT:-}" ]]; then
    echo "claude-wrapper: WORKSPACE_ROOT is not set; aborting." >&2
    exit 1
fi

ENV_FILE="$WORKSPACE_ROOT/.env"

# Source workspace .env so values like ANTHROPIC_AUTH_TOKEN and
# CLAUDE_USE_BWRAP are picked up even when the wrapper is invoked from a
# shell that inherited a stale env. devcontainer.json's --env-file already
# loads these at container start; this is the belt-and-suspenders pass.
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# Locate claude-real via PATH. The Dockerfile renames npm's `claude` binary
# to `claude-real` in the same directory, so wherever npm's prefix is (e.g.
# /usr/bin on NodeSource Ubuntu, /usr/local/bin on others), claude-real
# ends up next to it and reachable through PATH.
REAL_CLAUDE="$(command -v claude-real 2>/dev/null || true)"
if [[ -z "$REAL_CLAUDE" || ! -x "$REAL_CLAUDE" ]]; then
    echo "claude-wrapper: claude-real not found in PATH" >&2
    echo "  PATH=$PATH" >&2
    exit 1
fi

# Default path: no outer bwrap layer. Container + Claude's built-in
# sandbox + application-layer deny rules are the standard protection.
if [[ "${CLAUDE_USE_BWRAP:-0}" != "1" ]]; then
    exec "$REAL_CLAUDE" "$@"
fi

# ----- From here on: CLAUDE_USE_BWRAP=1 was set explicitly. -----
# We must successfully wrap claude in bwrap, or hard-fail. No silent
# fallback: the user opted in expecting a real isolation layer.

if ! command -v bwrap >/dev/null 2>&1; then
    echo "claude-wrapper: CLAUDE_USE_BWRAP=1 but bwrap is not installed." >&2
    exit 1
fi
if ! bwrap --die-with-parent --bind / / --true 2>/dev/null; then
    echo "claude-wrapper: CLAUDE_USE_BWRAP=1 but bwrap cannot create user namespaces." >&2
    echo "  Likely cause: VM/host kernel lacks userns support (common on macOS" >&2
    echo "  Docker Desktop / Podman libkrun). Either unset CLAUDE_USE_BWRAP or" >&2
    echo "  run this devcontainer on Linux/WSL2." >&2
    exit 1
fi

# Load bubblewrap policy from a simple config file.
# Format: <action> <args...>
#   tmpfs <path>             - hide directory with empty tmpfs
#   ro-bind <src> <path>     - bind <path> to <src> read-only (e.g. <src>=/dev/null)
#   ro-bind-self <path>      - bind <path> to itself read-only (visible but immutable)
# Paths are relative to WORKSPACE_ROOT; trailing glob patterns in <path>
# are expanded. Do not use whitespace inside paths.
POLICY_FILE="$WORKSPACE_ROOT/.devcontainer/bwrap-policy.conf"
BWRAP_ARGS=()

if [[ -f "$POLICY_FILE" ]]; then
    shopt -s nullglob
    while read -r action arg1 arg2; do
        [[ -z "$action" || "$action" =~ ^# ]] && continue

        case "$action" in
            tmpfs)
                for expanded in "$WORKSPACE_ROOT/"$arg1; do
                    [[ -d "$expanded" ]] && BWRAP_ARGS+=(--tmpfs "$expanded")
                done
                ;;
            ro-bind)
                for expanded in "$WORKSPACE_ROOT/"$arg2; do
                    BWRAP_ARGS+=(--ro-bind "$arg1" "$expanded")
                done
                ;;
            ro-bind-self)
                for expanded in "$WORKSPACE_ROOT/"$arg1; do
                    [[ -e "$expanded" ]] && BWRAP_ARGS+=(--ro-bind "$expanded" "$expanded")
                done
                ;;
            *)
                echo "claude-wrapper: unknown policy action '$action' in $POLICY_FILE" >&2
                exit 1
                ;;
        esac
    done < "$POLICY_FILE"
    shopt -u nullglob
fi

exec bwrap \
    --die-with-parent \
    --new-session \
    --bind / / \
    --dev-bind /dev /dev \
    --proc /proc \
    --tmpfs /tmp \
    --bind "$WORKSPACE_ROOT" "$WORKSPACE_ROOT" \
    "${BWRAP_ARGS[@]}" \
    --chdir "$WORKSPACE_ROOT" \
    "$REAL_CLAUDE" "$@"
