FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling for a development sandbox.
# Install bubblewrap for namespace isolation.
# NOTE: bwrap requires user namespace support in the host/VM kernel.
# On macOS (Docker Desktop, Podman/libkrun), user namespaces are often unavailable
# even with CAP_SYS_ADMIN. In that case setup.sh will hard-fail; see README
# "macOS 限制" section for details.
# Do not add file capabilities to bwrap; recent bwrap rejects that configuration
# with "Unexpected capabilities but not setuid, old file caps config?".
# Also includes C++ build toolchain (gcc + clang).
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bubblewrap \
		ca-certificates \
		curl \
		git \
		gnupg \
		less \
		socat \
		unzip \
		zsh \
		gcc \
		g++ \
		clang \
		cmake \
		make \
		gdb \
	&& rm -rf /var/lib/apt/lists/*

# Install Node.js (LTS) for CLI tooling distributed via npm.
RUN mkdir -p /etc/apt/keyrings \
	&& curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
		| gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
	&& echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
		> /etc/apt/sources.list.d/nodesource.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends nodejs \
	&& rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI with version lock for reproducibility.
# The npm-installed binary is renamed to claude-real; /usr/local/bin/claude
# becomes a thin shim (installed below) that delegates to the workspace
# wrapper at runtime. Doing this at build time avoids needing sudo / root
# during postCreateCommand under the non-root devuser.
RUN npm install -g @anthropic-ai/claude-code@2.1.161 \
	&& CLAUDE_BIN="$(command -v claude)" \
	&& mv "$CLAUDE_BIN" "$(dirname "$CLAUDE_BIN")/claude-real"

# Install the claude shim. It defers to the workspace wrapper so that the
# bwrap logic (in .devcontainer/claude-wrapper.sh) can be edited without
# rebuilding the image.
COPY .devcontainer/claude-shim.sh /usr/local/bin/claude
RUN chmod +x /usr/local/bin/claude

# Create a non-root user for better security.
# Ubuntu 24.04 base ships with a default `ubuntu` user/group at UID/GID 1000.
# We delete it first so devuser can take UID/GID 1000 cleanly, which is the
# common host UID on Linux and lines up with devcontainer.json's
# updateRemoteUserUID behaviour.
# Adding devuser to the root group is NOT required and would be a security risk.
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN set -eux; \
	if id ubuntu >/dev/null 2>&1; then \
		userdel --remove ubuntu 2>/dev/null || userdel ubuntu; \
	fi; \
	if ! getent group "$USER_GID" >/dev/null; then \
		groupadd --gid "$USER_GID" "$USERNAME"; \
	fi; \
	if ! id -u "$USERNAME" >/dev/null 2>&1; then \
		useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$USERNAME"; \
	fi; \
	mkdir -p /workspaces; \
	chown -R "$USERNAME:$USER_GID" /workspaces

# Build-time smoke checks. These run as root and should fail loudly if the
# tooling is broken, so we do NOT swallow errors with `|| true`.
# Note: `bwrap --version` only prints the version string and does not require
# user namespaces, so it is safe to run inside docker build.
RUN claude-real --version && bwrap --version

WORKDIR /workspaces

# Keep container alive for devcontainer attach; interactive shells are opened via exec.
CMD ["sleep", "infinity"]
