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
# claude-real lives wherever npm's prefix put it (typically /usr/bin on
# NodeSource Ubuntu, /usr/local/bin on macOS/manual installs). Look it up
# via PATH rather than hardcoding.
if ! command -v claude-real >/dev/null 2>&1; then
    echo "claude-real not found in PATH; image build is broken." >&2
    echo "  PATH=$PATH" >&2
    exit 1
fi
claude_real_path="$(command -v claude-real)"
echo "  shim:      $claude_path"
echo "  real bin:  $claude_real_path"
"$claude_real_path" --version

echo "Checking bwrap (used by Claude's built-in Bash sandbox)..."
# bwrap status is informational only. Claude Code's built-in sandbox uses it
# to isolate Bash subprocesses (L2), configured in .claude/settings.json
# under "sandbox". Some Docker Desktop backends expose bwrap but still block
# the namespace/capability operations it needs; in that case L2 degrades.
BWRAP_USABLE=0
if ! command -v bwrap >/dev/null 2>&1; then
    echo "  bwrap: NOT installed (image build issue)" >&2
elif bwrap_test_output="$(bwrap --die-with-parent --bind / / --true 2>&1)"; then
    echo "  bwrap: available. Claude's built-in Bash sandbox (L2) should be active."
    BWRAP_USABLE=1
else
    echo "  bwrap: installed but cannot create user namespaces in this VM"
    echo "         (common on macOS Docker Desktop / Podman libkrun)."
    echo "         Claude's built-in Bash sandbox (L2) may silently degrade."
    if [[ -n "$bwrap_test_output" ]]; then
        echo "         Test output: ${bwrap_test_output}"
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

# ============================================
# Sandbox layer status summary
# ============================================
echo ""
echo "=== Sandbox layer status ==="
echo "  L1 container:        ✓ active (devuser, mounts limited by devcontainer.json)"
if [[ "$BWRAP_USABLE" -eq 1 ]]; then
    echo "  L2 Claude bwrap:     ✓ active (Bash subprocesses isolated via bwrap)"
else
    echo "  L2 Claude bwrap:     ⚠ degraded (bwrap unusable; Bash commands NOT isolated)"
fi
echo "  L2 Copilot terminal: ✓ active (VS Code extension level; only run_in_terminal)"
echo "  L3 deny rules:       ✓ active (.claude/settings.json + .vscode/settings.json)"
echo ""
echo "Setup complete"
