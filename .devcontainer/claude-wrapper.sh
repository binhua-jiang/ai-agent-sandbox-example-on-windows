#!/usr/bin/env bash
# Claude Code CLI wrapper with sandbox isolation.
# Invoked by the shim at /usr/local/bin/claude. WORKSPACE_ROOT is set by
# devcontainer.json's containerEnv and validated by the shim.

set -euo pipefail

if [[ -z "${WORKSPACE_ROOT:-}" ]]; then
    echo "claude-wrapper: WORKSPACE_ROOT is not set; aborting." >&2
    exit 1
fi

ENV_FILE="$WORKSPACE_ROOT/.env"

# Load workspace credentials if not already in env. The wrapper itself
# reads .env via bash before bwrap takes over, so this is unaffected by
# the /dev/null bind that hides .env from the sandboxed claude process.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# claude-real is placed at /usr/local/bin/claude-real by the image build.
REAL_CLAUDE="/usr/local/bin/claude-real"
if [[ ! -x "$REAL_CLAUDE" ]]; then
    echo "claude-wrapper: real claude binary not found at $REAL_CLAUDE" >&2
    exit 1
fi

# Bubblewrap is mandatory. If it is unavailable, refuse to run rather than
# silently dropping the namespace isolation layer.
if ! command -v bwrap >/dev/null 2>&1; then
    echo "claude-wrapper: bwrap not installed; refusing to run without sandbox." >&2
    exit 1
fi
if ! bwrap --die-with-parent --bind / / --true 2>/dev/null; then
    echo "claude-wrapper: bwrap cannot create namespaces in this environment." >&2
    echo "  Likely the container/VM lacks user-namespace support (common on macOS" >&2
    echo "  Docker Desktop / Podman libkrun). Refusing to run without sandbox." >&2
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
