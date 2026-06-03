#!/usr/bin/env bash
# Claude Code CLI wrapper with sandbox isolation
# This script wraps the real claude binary with bubblewrap sandbox

set -euo pipefail

# Dynamically detect workspace root from script location or environment
# Priority: 1. WORKSPACE_ROOT env var, 2. Script's parent directory's parent
if [[ -n "${WORKSPACE_ROOT:-}" ]]; then
    WORKSPACE_ROOT="$WORKSPACE_ROOT"
else
    # Script is at .devcontainer/claude-wrapper.sh, workspace is two levels up
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WORKSPACE_ROOT="$(dirname "$SCRIPT_DIR")"
fi
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
    # Build bwrap arguments for .env.* files (glob expansion needed)
    BWRAP_ENV_ARGS=()
    for env_file in "$WORKSPACE_ROOT"/.env.*; do
        if [[ -f "$env_file" ]]; then
            BWRAP_ENV_ARGS+=(--ro-bind /dev/null "$env_file")
        fi
    done

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
        "${BWRAP_ENV_ARGS[@]}" \
        --chdir "$WORKSPACE_ROOT" \
        "$REAL_CLAUDE" "$@"
else
    # Fallback: run without bwrap (container isolation only)
    # The .claude/settings.json still provides permission-based sandbox
    echo "⚠️  WARNING: Bubblewrap sandbox unavailable, running with reduced isolation" >&2
    echo "   Namespace isolation disabled. Only settings.json permissions are active." >&2
    echo "   This may happen if container lacks CAP_SYS_ADMIN capability." >&2
    # Log to a file for debugging (if writable)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] bwrap unavailable, sandbox degraded" >> "$WORKSPACE_ROOT/.claude/sandbox.log" 2>/dev/null || true
    exec "$REAL_CLAUDE" "$@"
fi