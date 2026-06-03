#!/usr/bin/env bash
# Claude Code CLI wrapper with sandbox isolation
# This script wraps the real claude binary with bubblewrap sandbox

set -euo pipefail

WORKSPACE_ROOT="/workspaces/sandbox"
ENV_FILE="$WORKSPACE_ROOT/.env"

# Load workspace credentials if not already in env
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# Find the real claude binary (this wrapper shadows it)
REAL_CLAUDE="$(dirname "$(readlink -f "$0")")/claude-real"
if [[ ! -x "$REAL_CLAUDE" ]]; then
    # Fallback: try to find in PATH with different name
    REAL_CLAUDE="$(which claude-real 2>/dev/null || true)"
fi
if [[ ! -x "$REAL_CLAUDE" ]]; then
    echo "Error: Cannot find claude-real binary" >&2
    exit 1
fi

# Check if bubblewrap is available and we have capabilities
BWRAP_AVAILABLE=false
if command -v bwrap >/dev/null 2>&1; then
    # Test if we can create namespaces (requires SYS_ADMIN capability)
    if bwrap --die-with-parent --bind / / --true 2>/dev/null; then
        BWRAP_AVAILABLE=true
    fi
fi

if [[ "$BWRAP_AVAILABLE" == "true" ]]; then
    # Run with bubblewrap sandbox
    exec bwrap \
        --die-with-parent \
        --new-session \
        --bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "$WORKSPACE_ROOT" "$WORKSPACE_ROOT" \
        --tmpfs "$WORKSPACE_ROOT/core/src" \
        --ro-bind /dev/null "$WORKSPACE_ROOT/.env" \
        --chdir "$WORKSPACE_ROOT" \
        "$REAL_CLAUDE" "$@"
else
    # Fallback: run without bwrap (container isolation only)
    # The .claude/settings.json still provides permission-based sandbox
    exec "$REAL_CLAUDE" "$@"
fi