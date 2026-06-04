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

echo "Checking bwrap (used by Claude's built-in Bash sandbox, and optionally by the outer wrapper)..."
# bwrap status is informational only. It is used by:
#   1) Claude Code's built-in sandbox to isolate Bash subprocesses (L2)
#      (configured in .claude/settings.json under "sandbox"). This is the
#      default protection and does not require any opt-in.
#   2) Our outer wrapper (L4), but ONLY when the user sets CLAUDE_USE_BWRAP=1
#      in .env. The outer wrapper is OFF by default so the devcontainer
#      works uniformly on macOS / Linux / WSL2.
BWRAP_USABLE=0
if ! command -v bwrap >/dev/null 2>&1; then
    echo "  bwrap: NOT installed (image build issue)" >&2
elif bwrap_test_output="$(bwrap --die-with-parent --bind / / --true 2>&1)"; then
    echo "  bwrap: available. Set CLAUDE_USE_BWRAP=1 in .env to also enable the outer sandbox layer (L4)."
    BWRAP_USABLE=1
else
    echo "  bwrap: installed but cannot create user namespaces in this VM"
    echo "         (common on macOS Docker Desktop / Podman libkrun)."
    echo "         Claude's built-in Bash sandbox (L2) may silently degrade."
    echo "         Do NOT set CLAUDE_USE_BWRAP=1 in this environment."
    if [[ -n "$bwrap_test_output" ]]; then
        echo "         Test output: ${bwrap_test_output}"
    fi
fi

# F7 guard: if CLAUDE_USE_BWRAP=1 is set but bwrap is unusable, the
# plugin bootstrap below would hard-fail (claude → wrapper → bwrap exit 1)
# and abort container initialisation. Unset it locally with a clear warning;
# the user must fix .env before the next interactive `claude` invocation.
if [[ "${CLAUDE_USE_BWRAP:-0}" == "1" && "$BWRAP_USABLE" -eq 0 ]]; then
    echo "" >&2
    echo "WARNING: CLAUDE_USE_BWRAP=1 is set but bwrap is not functional here." >&2
    echo "  Subsequent 'claude' invocations would HARD-FAIL." >&2
    echo "  Remove or comment out CLAUDE_USE_BWRAP=1 in your .env before using claude." >&2
    echo "  Unsetting CLAUDE_USE_BWRAP locally so this setup script can complete." >&2
    unset CLAUDE_USE_BWRAP
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
if [[ "${CLAUDE_USE_BWRAP:-0}" == "1" && "$BWRAP_USABLE" -eq 1 ]]; then
    echo "  L4 outer bwrap:      ✓ active (CLAUDE_USE_BWRAP=1, bwrap functional)"
else
    echo "  L4 outer bwrap:      ○ disabled (set CLAUDE_USE_BWRAP=1 in .env to enable; Linux/WSL2 only)"
fi
echo ""
echo "Setup complete"
