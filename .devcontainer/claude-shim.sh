#!/usr/bin/env bash
# Shim installed at /usr/local/bin/claude during image build.
# Defers to the workspace wrapper so that the bwrap policy/logic can be
# edited without rebuilding the image. WORKSPACE_ROOT is provided by
# devcontainer.json's containerEnv.

set -euo pipefail

if [[ -z "${WORKSPACE_ROOT:-}" ]]; then
    echo "claude: WORKSPACE_ROOT is not set." >&2
    echo "  This shim requires WORKSPACE_ROOT to point at the workspace root." >&2
    echo "  In devcontainers it is set via containerEnv; outside, set it manually." >&2
    exit 1
fi

WRAPPER="$WORKSPACE_ROOT/.devcontainer/claude-wrapper.sh"

if [[ ! -x "$WRAPPER" ]]; then
    echo "claude: wrapper not found or not executable at $WRAPPER" >&2
    echo "  Refusing to run without the sandbox wrapper." >&2
    exit 1
fi

exec "$WRAPPER" "$@"
