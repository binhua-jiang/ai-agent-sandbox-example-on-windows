FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling for a development sandbox.
# Install bubblewrap with CAP_SYS_ADMIN capability so non-root users can create namespaces.
# Also includes C++ build toolchain (gcc + clang).
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bubblewrap \
		ca-certificates \
		curl \
		git \
		gnupg \
		less \
		libcap2-bin \
		socat \
		unzip \
		zsh \
		gcc \
		g++ \
		clang \
		cmake \
		make \
		gdb \
	&& setcap cap_sys_admin+ep /usr/bin/bwrap \
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
# Version 2.1.161 is known stable; adjust as needed.
RUN npm install -g @anthropic-ai/claude-code@2.1.161 || echo "Warning: failed to install Claude Code CLI"

# Create a non-root user for better security.
# Note: bubblewrap requires CAP_SYS_ADMIN capability (provided via --cap-add=SYS_ADMIN at container level)
# Adding user to root group is NOT required and would be a security risk
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN set -eux; \
	if ! getent group "$USER_GID" >/dev/null; then \
		groupadd --gid "$USER_GID" "$USERNAME"; \
	fi; \
	if ! id -u "$USERNAME" >/dev/null 2>&1; then \
		if getent passwd "$USER_UID" >/dev/null; then \
			useradd --gid "$USER_GID" -m "$USERNAME"; \
		else \
			useradd --uid "$USER_UID" --gid "$USER_GID" -m "$USERNAME"; \
		fi; \
	fi; \
	mkdir -p /workspaces; \
	chown -R "$USERNAME:$USER_GID" /workspaces

# Build-time smoke checks should not fail the image build.
RUN (claude --version || true) \
	&& (bwrap --version || true)

WORKDIR /workspaces

# Keep container alive for devcontainer attach; interactive shells are opened via exec.
CMD ["sleep", "infinity"]