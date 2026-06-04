# Windows 的 AI Agent 安全沙箱配置案例

在 Docker/Podman 容器中运行 **GitHub Copilot Agent** 与 **Claude Code CLI** 的沙箱隔离示例。

本项目现在采用 **L1-L3 三层模型**。外层 bwrap（旧 L4）已经移除：它在 Windows/WSL2/Podman Desktop 上 ROI 太低，不值得投入。

## 沙箱 3 层模型总览

| 层 | 实现 | 默认状态 | Claude Code CLI | GitHub Copilot Agent |
|----|------|---------|-----------------|---------------------|
| **L1 容器层** | Docker/Podman 限定挂载、能力、网络 | 始终生效 | 内核级强边界 | 内核级强边界 |
| **L2 内置 Bash/终端沙箱** | agent 自身实现 | 尽力启用 | bwrap 包 Bash 子进程；失败时降级 | VS Code 扩展进程级命令拦截 |
| **L3 内置 deny/read/write 规则** | `.claude/settings.json` / `.vscode/settings.json` | 默认启用 | 覆盖 Claude 内置工具入口 | 主要约束终端命令，内置文件工具可绕过 |

两条关键结论：

1. **L1 是唯一对两个 agent 都平等可靠的强保护**。对必须防 Copilot 或未知工具读取的敏感内容，最可靠手段是 L1 不挂载。
2. **L2 在 Podman Desktop 上必须按探针结果判断**。Claude 的 L2 依赖 bwrap；如果 `bwrap --die-with-parent --bind / / --true` 失败，Claude Bash 子进程不会获得内核级 bwrap 隔离，此时有效边界收敛为 L1 + L3。

## 快速开始

### 前置条件

- Podman 4.0+ 或 Docker 20.10+，大企业推荐使用 Podman，因为开源免费
- VS Code + Dev Containers 扩展
- Windows 推荐使用 Podman Desktop + WSL2 backend；但请注意，Podman Desktop 可能仍会让 Claude L2 bwrap 降级

### 步骤

1. **配置认证**（`cp .env.example .env` 后填值）：

   ```bash
   ANTHROPIC_AUTH_TOKEN=your-key      # 或 ANTHROPIC_API_KEY
   # ANTHROPIC_BASE_URL=...           # 可选，自定义 API 端点 / 网关
   # ANTHROPIC_MODEL=...              # 可选，固定模型
   ```

2. **在 VS Code 中打开容器**：执行 "Dev Containers: Reopen in Container"。镜像会安装 Claude Code CLI、bubblewrap、socat、C++ 工具链，并创建非 root 的 `devuser`。

3. **首次 attach 后**：`setup.sh` 会校验 claude/claude-real/bwrap 是否就位，安装 Claude 插件，并打印 L1-L3 状态。重点看 `L2 Claude bwrap` 是 `active` 还是 `degraded`。

4. **使用 agent**：直接用 Claude Code 或 Copilot。Claude 的 L3 规则来自 `.claude/settings.json`，Copilot 的终端沙箱规则来自 `.vscode/settings.json`。

5. **构建 Demo**（可选，由你在容器终端运行）：

   ```bash
   cmake -S . -B build && cmake --build build
   ./build/demo/demo
   ```

   不要让 agent 替你运行这个构建：`core/src/` 被 L3 `denyRead` 阻塞，agent 触发构建时编译器可能读不到源码。这正是本仓库想展示的隔离效果。

## L1：容器层

**作用**：限定从宿主到容器的挂载、网络、能力。L1 是三层里最可靠的一层，也是两个 agent 共享的强边界。

**实现位置**：`.devcontainer/devcontainer.json` + `images/Dockerfile`

关键约束：

- 工作区目录是唯一被挂载进来的宿主路径；`~/.ssh`、`~/.aws`、`~/.gitconfig` 等宿主凭据不挂载进容器
- 容器以非特权用户 `devuser` 运行，不是 root
- 镜像安装 `bubblewrap` 和 `socat`，供 Claude 内置 L2 Bash 沙箱使用
- `devcontainer.json` 保留 `SYS_ADMIN`、`apparmor=unconfined`、`seccomp=unconfined` 等配置，以尽量放行 Claude L2 bwrap；但 Podman Desktop 运行时仍可能让 bwrap 降级

为什么 L1 最重要：一旦文件被挂进容器，后续 L2/L3 都属于补充约束；唯一不可绕的事实是“这个路径在容器里根本不存在”。设计敏感数据保护时，第一选择永远是不挂载。

| 路径 | L1 状态 | 后果 |
|------|---------|------|
| `~/.ssh`、宿主主目录、云凭据目录 | 不挂载 | agent 看不见，无从读写 |
| 工作区目录 | 挂载读写 | 后续靠 L2/L3 细分 |

## L2：内置 Bash/终端沙箱

**作用**：限制 agent 执行的 shell 命令能访问哪些文件/网络。两个 agent 都有这一层，但实现强度差异很大。

### Claude Code CLI

Claude Code CLI 在 Linux 上会尝试用 bubblewrap 包裹 Bash 工具调用及其子进程，提供 mount namespace 和网络过滤隔离。

- 生效范围：`Bash` 工具及其子进程
- 不覆盖：`Read`、`Edit`、`Write` 等非 shell 工具，这些走 L3
- 配置：`.claude/settings.json` 的 `sandbox` 块
- 依赖：bubblewrap + socat + 容器运行时允许相关 namespace/capability 操作

本项目的 `setup.sh` 会执行这个最小探针：

```bash
bwrap --die-with-parent --bind / / --true
```

如果探针失败，`setup.sh` 会打印 `L2 Claude bwrap: degraded`。这在 macOS Podman Desktop、Podman libkrun，以及某些 Windows/WSL2/Podman Desktop 组合里都可能发生。 Windows/WSL2/Podman Desktop 组合里都可能发生。`.claude/settings.json` 设置了 `failIfUnavailable: false`，所以 Claude 仍可使用，但 Bash 子进程不再拥有 bwrap 隔离。

### GitHub Copilot Agent

Copilot 的 `chat.agent.sandbox.*` 是 VS Code 扩展进程层面的命令拦截，不创建 Linux namespace。

- 生效范围：主要是 `run_in_terminal`
- 配置：`.vscode/settings.json` 的 `chat.agent.sandbox.*` 和 `chat.agent.networkFilter`
- 绕过方式：调用非终端工具，例如内置读文件、搜索、编辑工具

| 维度 | Claude L2 | Copilot L2 |
|------|-----------|------------|
| 实现 | Linux bubblewrap namespace | VS Code 扩展进程命令拦截 |
| 覆盖范围 | Bash + 子进程 | 主要是 `run_in_terminal` |
| 降级风险 | Podman Desktop/VM 可能阻止 bwrap | 不依赖 bwrap |
| 安全强度 | active 时较强；degraded 时失去内核隔离 | 较弱，偏自动批准控制 |

## L3：内置 deny/read/write 规则

**作用**：agent 调用工具前，由 agent 自身根据权限规则决定放行、拒绝或询问。

### Claude Code CLI

`.claude/settings.json` 的 `permissions.deny` / `permissions.allow` 应用于 Claude 的内置工具入口，包括 `Read`、`Edit`、`Write`、`Bash`、`Glob`、`Grep`、`WebFetch` 等。`sandbox.filesystem.*` 同时会被 Claude L2 Bash 沙箱读取，用于生成 bwrap 约束。

本仓库 L3 配置示例：

| 路径 | L3 配置 | 效果 |
|------|--------|------|
| `.env`、`.env.*` | `Read(./.env*)` deny + `sandbox.filesystem.denyRead` | Claude 内置工具读不到 |
| `core/src/**` | `Read(./core/src/**)` deny + denyRead/denyWrite | Claude 内置工具读写不到 |
| `.git/**` | `Edit(./.git/**)` deny + denyWrite | 可读不可写 |
| `.claude/settings.json` | `Edit(./.claude/settings.json)` deny | 防 agent 修改自己规则 |

### GitHub Copilot Agent

Copilot 的 `chat.agent.sandbox.fileSystem.linux.denyRead/denyWrite` 主要约束终端命令，不约束 Copilot 的内置文件工具。也就是说，仅靠 `.vscode/settings.json` 的 `denyRead`，不能阻止 Copilot 通过内置工具读取工作区内文件。

| 内置工具 | Claude L3 | Copilot L3 |
|---------|-----------|------------|
| 读文件 | `Read` 走 `permissions.deny` | 内置读文件工具绕过 sandbox 规则 |
| 写文件 | `Edit`/`Write` 走 `permissions.deny` | 内置编辑工具绕过 sandbox 规则 |
| 跑 shell | L3 检查 + L2 bwrap（如果 active） | `run_in_terminal` 受 sandbox 规则约束 |
| 搜索 | `Grep`/`Glob` 走 `permissions.deny` | 内置搜索工具绕过 sandbox 规则 |

结论：对 Copilot 而言，敏感数据保护必须靠 L1。不要把不希望 Copilot 看到的内容挂进容器。

## Claude launcher：为什么还保留 wrapper

放弃 L4 后，wrapper 不再承担沙箱职责。它只是一个轻量 launcher：

```text
/usr/local/bin/claude (image shim)
  -> .devcontainer/claude-wrapper.sh
       -> source .env
       -> exec claude-real
```

保留它有两个原因：

- `claude-wrapper.sh` 位于工作区，可以热改 `.env` 加载逻辑而不用重建镜像
- Dockerfile 只需要在构建期植入稳定 shim，真实 Claude 二进制位置通过 PATH 查找，适配 `/usr/bin` 或 `/usr/local/bin` 的 npm prefix 差异

如果未来不需要从工作区 `.env` 加载认证，也可以把这层 wrapper 合并进镜像 shim；这不会影响 L1-L3 模型。

## 架构图

```text
Host
  -> VS Code + Dev Containers
      -> Docker/Podman container (L1)
          - devuser
          - limited host mounts
          - bwrap/socat installed for Claude L2

          GitHub Copilot Agent
            L2: VS Code extension terminal sandbox
            L3: terminal sandbox rules only; built-in file tools can bypass

          Claude Code CLI
            /usr/local/bin/claude -> .devcontainer/claude-wrapper.sh -> claude-real
            L2: built-in Bash sandbox via bwrap when probe passes
            L3: .claude/settings.json permissions and sandbox rules
```

## 项目结构

```text
core/
├── src/        # 示例敏感源码，Claude L3 deny
└── include/    # 示例公开头文件
demo/           # 示例可执行程序
.claude/
└── settings.json         # Claude L3 permissions + L2 Bash sandbox config
.vscode/
└── settings.json         # Copilot terminal sandbox and network settings
.devcontainer/
├── devcontainer.json     # L1 container config
├── setup.sh              # environment checks and L1-L3 status summary
├── claude-shim.sh        # image-level /usr/local/bin/claude shim
└── claude-wrapper.sh     # lightweight launcher, not an outer sandbox
images/
└── Dockerfile            # image build: tools, devuser, Claude CLI, bwrap/socat
.env.example              # credential template
```

## 运行身份：devuser（非 root）

容器内 agent 一律以非特权 `devuser` 运行，这是 L1 的一部分。

原因：

- 限制误操作影响面
- 避免 root-in-container 带来的额外风险
- 配合 `updateRemoteUserUID: true` 尽量对齐宿主文件权限
- 匹配 `npm`、`pip` 等工具链的常规使用方式

### devuser UID/GID 对齐

工作区是宿主目录 bind mount，文件归属由宿主决定。如果容器内 devuser 的 UID 与宿主不一致，VS Code 保存文件可能遇到 `EACCES`。

本仓库提供两条默认路径，任一生效即可：

| 路径 | 机制 | 说明 |
|------|------|------|
| `updateRemoteUserUID` | Dev Containers attach 时改 devuser UID | Linux/WSL2 上通常稳定 |
| `HOST_UID` / `HOST_GID` | 构建期显式传 UID/GID | 需要从继承 env 的终端启动 VS Code |

Windows 主机没有 `chmod`，因此不在 `initializeCommand` 中执行宿主侧 chmod。若纯 Linux/macOS 主机仍遇到 UID 不匹配导致的写入问题，可以在宿主终端手动执行 `chmod -R o+rwX .` 作为临时兜底；它会放宽工作区权限，不建议作为默认配置。

验证命令：

```bash
id
ls -la .claude/settings.json
echo "" >> .claude/settings.json
```

`echo` 成功即可，不必纠结具体是哪条路径生效。

## 运维与排错

### 容器运行时

| 功能 | Docker | Podman |
|------|--------|--------|
| `--cap-add=SYS_ADMIN` | 支持 | 支持 |
| `--security-opt=label=disable` | 通常忽略 | SELinux 环境有效 |
| `--security-opt=apparmor=unconfined` | 支持 | 支持 |
| Rootless 模式 | 需额外配置 | 原生支持 |

### 故障排查

| 问题 | 所属层 | 原因与处理 |
|------|-------|-----------|
| `L2 Claude bwrap: degraded` | L2 | 当前 VM/容器运行时阻止 bwrap 所需 namespace/capability 操作。Claude 仍可用，但 Bash 子进程没有 bwrap 隔离 |
| `bwrap: capset failed: Operation not permitted` | L2 | 常见于 Windows/WSL2/Podman Desktop，即使 `docker inspect` 显示 `seccomp=unconfined` 也可能发生。推荐接受 L2 降级，不为此单独维护 WSL2 原生 Docker |
| `bwrap: setting up uid map: Permission denied` | L2 | 宿主或容器运行时限制 user namespace。可用 `bwrap --die-with-parent --bind / / --true` 验证 |
| Claude 内置 sandbox 提示 `Bubblewrap fails to start inside a container` | L2 | 嵌套 bwrap 环境不兼容；本仓库已在 `.claude/settings.json` 设置 `enableWeakerNestedSandbox` |
| Copilot 仍能读 `.env` | L3（Copilot） | 预期行为：Copilot 内置文件工具不受终端 sandbox 规则约束。要防 Copilot 读，靠 L1 不挂载 |
| VS Code 保存仓库文件报 `EACCES` | L1 UID 对齐 | 旧容器或 UID 不匹配。重新 Rebuild Container，或显式设置 `HOST_UID` / `HOST_GID` 后重建 |
| `claude: command not found` | L1 | 镜像构建未完成或 PATH 异常。重建容器 |
| `claude: WORKSPACE_ROOT is not set` | launcher | 在非 devcontainer 环境调用 shim。手动 `export WORKSPACE_ROOT=$(pwd)`，或直接运行 `claude-real` |

### 诊断命令

以下命令均在容器内执行：

```bash
# L1 身份与挂载
id
echo "WORKSPACE_ROOT=${WORKSPACE_ROOT:-unset}"
mount | grep -E "workspaces|/home"

# L2 bwrap 可用性
bwrap --version
bwrap --die-with-parent --bind / / --true && echo "bwrap OK" || echo "bwrap FAILED"
grep -E 'Seccomp|NoNewPrivs|CapEff|CapBnd' /proc/self/status

# Claude launcher / 真二进制布局
ls -l "$(command -v claude)" "$(command -v claude-real)"
head -1 "$(command -v claude)"
claude-real --version

# 认证变量是否进入容器
echo "ANTHROPIC_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:+set}"
```

真正的 L2/L3 隔离测试需要从 agent 工具内部触发；普通人工终端不受 agent 的 L3 工具入口约束。

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code CLI | 2.1.161 | 锁定版本，确保一致性 |
| Ubuntu | 24.04 | LTS 基础镜像 |
| Node.js | 22.x | LTS |
| bubblewrap | 系统 package | Claude 内置 L2 Bash 沙箱依赖 |
| socat | 系统 package | Claude 内置 L2 网络代理依赖 |

## 关于旧 L4 的取舍

我们尝试过旧版 L4：用外层 bubblewrap 包住整个 `claude` 进程，再通过 `tmpfs`、`ro-bind`、`ro-bind-self` 做路径级 syscall 隔离。它理论上能补 MCP 工具、未来未知工具、文件存在性隐藏等空白。

实际验证后决定放弃，原因是 ROI 太低：

- Windows/WSL2/Podman Desktop 上，即使 `docker inspect` 显示 `SYS_ADMIN`、`apparmor=unconfined`、`seccomp=unconfined` 已下发，bwrap 仍可能在 `capset()` 阶段失败
- Claude 自带 L2 Bash 沙箱也依赖 bwrap；外层 L4 与 L2 会踩同一类运行时限制，并不能解决 Windows Podman Desktop 的核心问题
- L4 只覆盖 Claude 进程，不覆盖 Copilot 的 VS Code 扩展进程；对 Copilot 的敏感数据保护仍然必须靠 L1
- 为了 L4 迁移到 WSL2 原生 Docker Engine、开启 `--privileged` 或调整宿主内核策略，维护成本超过它带来的额外收益

所以本项目保留清晰、可维护的 L1-L3 模型：L1 作为可靠边界，L2 按探针结果启用或降级，L3 作为 agent 工具入口约束。对真正敏感的数据，结论保持不变：不要挂载进容器。
