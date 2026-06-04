#!/usr/bin/env bash
# Claude Code CLI wrapper.
#
# This wrapper keeps the image-level shim stable while delegating to the
# npm-installed Claude binary. The project no longer adds a process-wide
# sandbox around Claude; isolation is provided by L1 container boundaries
# plus Claude's built-in L2/L3 sandbox mechanisms.

set -euo pipefail

if [[ -z "${WORKSPACE_ROOT:-}" ]]; then
    echo "claude-wrapper: WORKSPACE_ROOT is not set; aborting." >&2
    exit 1
fi

ENV_FILE="$WORKSPACE_ROOT/.env"

# Source workspace .env so values like ANTHROPIC_AUTH_TOKEN are picked up
# even when the wrapper is invoked from a shell that inherited a stale env.
# devcontainer.json's --env-file already loads these at container start;
# this is the belt-and-suspenders pass.
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

exec "$REAL_CLAUDE" "$@"
