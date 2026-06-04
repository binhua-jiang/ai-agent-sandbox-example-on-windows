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

# Bwrap availability check.
# Default behaviour: degrade with a loud, repeated warning when bwrap cannot
# create user namespaces (common on macOS Docker Desktop / Podman libkrun).
# This keeps the dev container usable across platforms.
# Strict mode: when CLAUDE_SANDBOX_STRICT=1, refuse to run if bwrap is not
# fully functional. Intended for deployments that require namespace isolation
# as a security gate.
BWRAP_OK=false
BWRAP_FAIL_REASON=""
if ! command -v bwrap >/dev/null 2>&1; then
    BWRAP_FAIL_REASON="bwrap binary not installed in the image"
elif ! bwrap --die-with-parent --bind / / --true 2>/dev/null; then
    BWRAP_FAIL_REASON="bwrap cannot create user namespaces in this VM (no userns support)"
else
    BWRAP_OK=true
fi

if [[ "$BWRAP_OK" == "false" ]]; then
    if [[ "${CLAUDE_SANDBOX_STRICT:-0}" == "1" ]]; then
        echo "claude-wrapper: CLAUDE_SANDBOX_STRICT=1 set and bwrap unavailable." >&2
        echo "  Reason: $BWRAP_FAIL_REASON" >&2
        echo "  Refusing to run." >&2
        exit 1
    fi
    # Degraded mode: warn loudly on every invocation, log to file, then
    # exec the real claude without bwrap. Application-level deny rules in
    # .claude/settings.json are still in effect, but are bypassable.
    cat >&2 <<EOF
================================================================================
  WARNING: bwrap sandbox UNAVAILABLE — running with REDUCED isolation.
  Reason: $BWRAP_FAIL_REASON
  Disabled protections:
    - bubblewrap namespace isolation
    - core/src tmpfs hiding
    - .env / .env.* /dev/null masking
    - .git ro-bind-self write protection
  Still active:
    - .claude/settings.json permission rules (BYPASSABLE)
    - Container-level filesystem boundary (host paths not mounted)
  To enforce strict mode and refuse to run instead of degrading,
  set CLAUDE_SANDBOX_STRICT=1 in your shell or .env file.
================================================================================
EOF
    mkdir -p "$WORKSPACE_ROOT/.claude" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] claude invoked in degraded mode: $BWRAP_FAIL_REASON" \
        >> "$WORKSPACE_ROOT/.claude/sandbox.log" 2>/dev/null || true
    exec "$REAL_CLAUDE" "$@"
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
