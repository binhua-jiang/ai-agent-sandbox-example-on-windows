#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(dirname "$SCRIPT_DIR")}"
ENV_FILE="$WORKSPACE_ROOT/.env"

# Load workspace credentials automatically when shell env is empty.
if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" && -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# ============================================
# Environment Checks
# ============================================
# Runs as the non-root devuser (postCreateCommand honours remoteUser).
# The wrapper and claude-real are installed at image build time, so no
# privileged operations are needed here.

echo "Running as: $(id -un) (uid=$(id -u), gid=$(id -g))"

echo "Checking claude shim..."
if ! command -v claude >/dev/null 2>&1; then
    echo "claude: not found in PATH; image build is broken." >&2
    exit 1
fi
claude_path="$(command -v claude)"
if [[ ! -x /usr/local/bin/claude-real ]]; then
    echo "claude-real not found at /usr/local/bin/claude-real; image build is broken." >&2
    exit 1
fi
echo "  shim:      $claude_path"
echo "  real bin:  /usr/local/bin/claude-real"
/usr/local/bin/claude-real --version

echo "Checking bwrap..."
# Setup never hard-fails on bwrap problems: the dev container must remain
# usable for general development even when bwrap isolation is unavailable
# (typical on macOS Docker Desktop / Podman libkrun, where the Linux VM
# does not expose user namespaces). The claude wrapper itself will detect
# the same condition at invocation time and either degrade with a loud
# warning, or hard-fail when CLAUDE_SANDBOX_STRICT=1.
if ! command -v bwrap >/dev/null 2>&1; then
    echo "WARNING: bwrap not installed; sandbox layer 1 (namespace isolation) will be UNAVAILABLE." >&2
    echo "   Claude will run with only settings.json permission rules (bypassable)." >&2
    echo "   To enforce strict mode and refuse to run, set CLAUDE_SANDBOX_STRICT=1 in .env" >&2
else
    bwrap --version
    if bwrap_test_output="$(bwrap --die-with-parent --bind / / --true 2>&1)"; then
        echo "bwrap namespace test: OK"
    else
        echo "WARNING: bwrap namespace test FAILED" >&2
        if [[ -n "$bwrap_test_output" ]]; then
            echo "   ${bwrap_test_output}" >&2
        fi
        echo "   This VM does not allow bwrap to create user namespaces" >&2
        echo "   (common on macOS Docker Desktop / Podman libkrun)." >&2
        echo "   Sandbox layer 1 (namespace isolation) will be UNAVAILABLE;" >&2
        echo "   Claude will run with only settings.json permission rules (bypassable)." >&2
        echo "   To enforce strict mode and refuse to run, set CLAUDE_SANDBOX_STRICT=1 in .env" >&2
    fi
fi

if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    echo "Auth env detected: non-interactive login ready"
else
    echo "Auth env missing in container env; scripts will also try workspace .env"
fi

if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
    echo "Gateway endpoint: ${ANTHROPIC_BASE_URL}"
else
    echo "Gateway endpoint not set in container env (workspace .env may still provide it at runtime)"
fi

# ============================================
# Claude Plugin Bootstrap
# ============================================

if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    echo "No Claude API credential found, skip plugin bootstrap to avoid interactive login"
    exit 0
fi

add_marketplace() {
    local source="$1"
    if claude plugin marketplace add "$source" --scope user; then
        return 0
    fi

    # Marketplace may already exist or network may be unavailable.
    echo "warning: failed to add marketplace ${source}; continuing"
    return 0
}

install_plugin() {
    local plugin="$1"
    if claude plugin install "$plugin" --scope user; then
        return 0
    fi

    # Plugin may already be installed or temporarily unavailable.
    echo "warning: failed to install plugin ${plugin}; continuing"
    return 0
}

echo "Bootstrapping Claude marketplaces..."
add_marketplace "anthropics/skills"
add_marketplace "obra/superpowers-marketplace"

echo "Installing Claude plugins..."
install_plugin "document-skills@anthropic-agent-skills"
install_plugin "superpowers@superpowers-marketplace"

echo "Setup complete"
