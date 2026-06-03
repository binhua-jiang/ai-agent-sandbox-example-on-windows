FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Base tooling for a development sandbox.
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

# Install Claude Code CLI (best effort, do not fail image build).
RUN npm install -g @anthropic-ai/claude-code || echo "Warning: failed to install Claude Code CLI"

# Build-time smoke checks should not fail the image build.
RUN (claude --version || true) \
	&& (bwrap --version || true)

WORKDIR /workspaces

# Keep container alive for devcontainer attach; interactive shells are opened via exec.
CMD ["sleep", "infinity"]
