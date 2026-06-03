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
# Environment Tests (from post-create.sh)
# ============================================

echo "Testing claude..."
if command -v claude >/dev/null 2>&1; then
    claude --version
else
    echo "claude not available"
fi

echo "Testing bwrap..."
if command -v bwrap >/dev/null 2>&1; then
    bwrap --version
    # Test if bwrap can actually create namespaces
    if bwrap --die-with-parent --bind / / --true 2>/dev/null; then
        echo "bwrap namespace test: OK"
    else
        echo "bwrap namespace test: FAILED (may need CAP_SYS_ADMIN)"
    fi
else
    echo "bwrap not available"
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
# Workspace Permissions (for non-root user)
# ============================================

# Ensure workspace directory is writable by the devuser
if [[ -d "$WORKSPACE_ROOT" ]]; then
    # The container may have mounted the workspace with root ownership
    # We need to ensure the devuser can write to it
    echo "Ensuring workspace permissions for devuser..."
    # Check if we have sudo or are root (during initial container setup)
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo chown -R "$(id -u):$(id -g)" "$WORKSPACE_ROOT" 2>/dev/null || true
    elif [[ "$(id -u)" == "0" ]]; then
        chown -R devuser:devuser "$WORKSPACE_ROOT" 2>/dev/null || true
    fi
fi

# ============================================
# Sandbox Wrapper Setup
# ============================================

setup_sandbox_wrapper() {
    local claude_path
    claude_path="$(command -v claude 2>/dev/null || true)"

    if [[ -z "$claude_path" ]]; then
        echo "claude binary not found, skip wrapper setup"
        return 0
    fi

    local claude_dir="$(dirname "$claude_path")"
    local claude_real="$claude_dir/claude-real"
    local wrapper_src="$WORKSPACE_ROOT/.devcontainer/claude-wrapper.sh"

    # Check if already set up
    if [[ -x "$claude_real" ]]; then
        echo "Sandbox wrapper already installed"
        return 0
    fi

    if [[ ! -f "$wrapper_src" ]]; then
        echo "Warning: wrapper script not found at $wrapper_src"
        return 0
    fi

    # Rename original binary and install wrapper
    # This may require elevated permissions if installed in system path
    echo "Installing sandbox wrapper for claude..."
    if [[ "$(id -u)" == "0" ]] || command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        if [[ "$(id -u)" == "0" ]]; then
            mv "$claude_path" "$claude_real"
            cp "$wrapper_src" "$claude_path"
            chmod +x "$claude_path"
        else
            sudo mv "$claude_path" "$claude_real"
            sudo cp "$wrapper_src" "$claude_path"
            sudo chmod +x "$claude_path"
        fi
        echo "Sandbox wrapper installed: $claude_path -> claude-real"
    else
        echo "Warning: Cannot install wrapper (need root/sudo access)"
        echo "Claude will run without bubblewrap sandbox (settings.json sandbox still active)"
    fi
}

setup_sandbox_wrapper

# ============================================
# Claude Plugin Bootstrap
# ============================================

if ! command -v claude >/dev/null 2>&1; then
    echo "claude not found, skip plugin bootstrap"
    exit 0
fi

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