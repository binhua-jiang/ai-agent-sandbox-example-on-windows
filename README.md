# Windows 的 AI Agent 安全沙箱配置案例

在 Docker/Podman 容器中运行 GitHub Copilot Agent & Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

沙箱的价值在于**为 AI Agent 划定可触达的资源边界**，采用多层防护：
- **容器层**：宿主机未挂载到容器的目录，agent 天然无法触及；
- **沙箱层 1**（内核级，仅 Claude Code CLI）：bubblewrap 在进程外层创建独立 namespace，用 tmpfs 和 `/dev/null` 物理覆盖敏感路径——文件在沙箱内不存在，任何 syscall 都无法触及。GitHub Copilot Agent 不受此层保护（其工具运行在 VS Code 扩展进程内，不在 bwrap namespace 中）。
- **沙箱层 2**（应用级，兜底）：两个 agent 各自的 deny 规则，防误操作而非防攻击。Claude Code CLI 靠 `.claude/settings.json` sandbox 规则；Copilot 靠 `.vscode/settings.json` 的 `chat.agent.sandbox.*`，但该规则仅约束终端工具，`readFile`/`grepSearch` 等内建工具不走这套检查，不可依赖。

"看不到"即"动不了"，从而在保留 AI 编码能力的同时，避免核心源码泄漏、密钥外泄和危险命令对宿主机的影响。

三层之中，**容器层（决定"挂不挂"）才是真正可靠的边界**；沙箱层 1/2 是纵深防御。两个 agent 的沙箱强度差异巨大，详见下文 [Claude Code CLI 沙箱 vs GitHub Copilot Agent 沙箱](#claude-code-cli-沙箱-vs-github-copilot-agent-沙箱)。

## 快速开始

### 前置条件

- Docker 20.10+ 或 Podman 4.0+
- VS Code + Dev Containers 扩展
- **Linux 内核必须支持 user namespace**：
  - Linux 宿主：原生支持（绝大多数发行版默认开启）
  - Windows：必须走 WSL2 + Docker/Podman
  - **macOS：Docker Desktop / Podman libkrun 提供的 Linux VM 通常不开放 user namespace，即使加了 `CAP_SYS_ADMIN` 也跑不起来 bwrap**。本仓库的 `setup.sh` 检测到 bwrap 不能创建 namespace 时会直接中止初始化，避免静默降级。详见 [故障排查](#故障排查)。

### 步骤

1. **配置认证**（在仓库根目录创建 `.env`）：

   ```bash
   ANTHROPIC_AUTH_TOKEN=your-key      # 或 ANTHROPIC_API_KEY
   ANTHROPIC_BASE_URL=your-api-base-url  # 可选，用于代理/网关
   ANTHROPIC_MODEL=your-model-name    # 可选，强制指定模型
   ```

2. **在 VS Code 中打开容器**：执行 "Dev Containers: Reopen in Container"

3. **使用 Claude Code CLI**：容器启动后自动配置沙箱，直接使用 Claude Code for VS Code 扩展即可

4. **构建 Demo**（可选）：

   ```bash
   cmake -S . -B build && cmake --build build
   ./build/demo/demo
   ```

## 核心理念

**沙箱的本质是为 AI Agent 划定可触达的资源边界，而不是在边界内部做细粒度的访问控制。**

一旦某个文件已经被挂载/暴露进沙箱，再用应用层的 "deny 规则" 去禁止读写就很脆弱：
任何使用底层 syscall、子进程，或不遵守该规则的工具，都能绕过它。
真正可靠的隔离是**从一开始就让敏感内容在沙箱里"不存在"**——agent 看不到，就无从读写。

### 强保护 vs 弱保护

| 层级 | 实现方式 | 强度 | 适用场景 |
|------|----------|------|----------|
| **不挂载** | 容器层不挂载宿主机其他目录 | ★★★★★ 内核级 | 工作区外的敏感内容（`~/.ssh`、宿主机文件等） |
| **tmpfs 覆盖** | bwrap 用 tmpfs 空目录覆盖，目录内容在沙箱中完全不可见 | ★★★★☆ 物理上不可见 | 必须留在仓库里的敏感目录（`core/src/`） |
| **/dev/null 绑定** | bwrap 将文件绑定到 `/dev/null`，读取内容为空 | ★★★★☆ 物理上不可读 | 必须留在仓库里的敏感文件（`.env`） |
| **ro-bind-self 只读绑定** | bwrap 将路径绑定到自身只读，可读但任何写操作均失败 | ★★★★☆ 物理上不可写 | 必须可读但禁止改动的目录（`.git/`） |
| **容器网络限制** | 容器层的 network policy 或镜像层 firewall | ★★★☆☆ | 阻止数据外发 |
| **应用层 deny 规则** | `.claude/settings.json`、VS Code 配置 | ★★☆☆☆ 可绕过 | Claude Code 自身权限兜底与防误操作 |

> 注：bwrap 自身支持 `--unshare-net` 隔离网络，但本仓库**没有启用**——Claude Code CLI 需要访问 `api.anthropic.com` 才能工作，整段链路一旦断网就不可用。网络层的边界靠**容器**而不是 bwrap。

**举例：**
- 保护 `~/.ssh/id_rsa`：✅ 容器层不挂载主目录（强保护）。❌ 挂载主目录 + denyRead（弱）。
- 保护 `.env`（必须留在仓库内）：✅ bwrap 用 `/dev/null` 绑定覆盖（强保护）；同时 `.claude/settings.json` 里保留 deny 规则做兜底。
- 保护 `core/src/`：✅ bwrap 用 tmpfs 空目录覆盖，让 CLI 在沙箱里看不到任何内容（强保护）；同时 `.claude/settings.json` 里保留 deny 规则做兜底。
- 保护 `.git/`：✅ bwrap 用 `ro-bind-self` 把 `.git` 自身只读绑定，agent 可以读（`git log/status/diff` 正常）但任何写操作会被内核拦截（强保护）；同时 `.claude/settings.json` 里保留 `denyWrite` 兜底。

### Claude Code CLI 沙箱 vs GitHub Copilot Agent 沙箱

两者都叫"沙箱"，但**隔离层级和作用范围差异巨大**，理解这点才能避免误判安全边界。

| 维度 | Claude Code CLI | GitHub Copilot Agent |
|------|--------------------|--------------------|
| 实现层级 | Linux 内核 namespace（bubblewrap） | VS Code 扩展进程的命令拦截 |
| 作用范围 | 整个 CLI 进程 + 所有子进程 + 所有 syscall | 仅 `run_in_terminal` 工具 |
| 内建工具（`readFile`/`grepSearch`/`listDir` 等） | ✅ 受 namespace 约束 | ❌ 完全绕过沙箱 |
| 文件隐藏 | tmpfs / `/dev/null` 物理覆盖，真正不可见 | 仅靠 `denyRead` 配置，工具不遵守 |
| 网络隔离 | 容器层 + bwrap namespace | `chat.agent.networkFilter` 仅约束 fetch 工具与内置浏览器 |
| 配置位置 | **沙箱层 1**（物理隔离）：`.devcontainer/bwrap-policy.conf` + wrapper 脚本<br>**沙箱层 2**（权限兜底）：`.claude/settings.json` | `.vscode/settings.json` 的 `chat.agent.sandbox.*` |
| 绕过难度 | 需突破内核 namespace | 调用任意非终端工具即可 |

**结论：**
- **Claude Code CLI**：真正的隔离来自 bwrap（决定 CLI "看不看得到"）；`.devcontainer/bwrap-policy.conf` 管理 bubblewrap 的物理隔离路径，`.claude/settings.json` 保留 Claude Code 自身 deny 规则。
- **GitHub Copilot Agent**：`chat.agent.sandbox.*` 实际是"**终端沙箱**"而非"**工具沙箱**"——`readFile` 等内建工具走扩展进程的文件系统 API，**完全绕过** `denyRead`。仅靠它**无法阻止** Agent 读取 `.env`。

## 实现细节

### 架构概览

本示例采用 **容器 + bubblewrap + 应用层规则** 的多层隔离：
- **容器层**（Docker/Podman）：限定挂载到容器的宿主机目录，约束 VS Code Server、Copilot Agent 及 Claude Code CLI 的整体可达范围。
- **沙箱层 1**（bubblewrap）：在容器内进一步包裹 Claude Code CLI 进程，用 namespace 把已挂载但敏感的路径物理隐藏。
- **沙箱层 2**（settings.json）：Claude Code CLI 自身的 deny 规则，在工具调用层面兜底，防误操作。

bubblewrap 依赖 Linux 内核的 namespace 特性；Windows 内核没有 namespace，需通过 WSL2 + Docker/Podman 容器获得 Linux 环境：

```
Windows → WSL2 (Linux 内核) → 容器层 → 沙箱层 1 (bwrap) → 沙箱层 2 (settings.json) → Claude Code CLI
```

**架构图：**

```
┌──────────────────────────────────────────────────────────┐
│ 宿主机 (Host)                                            │
│  └─ VS Code + Dev Containers → Docker/Podman             │
│                          ↓                               │
│ ┌──────────────────────────────────────────────────────┐ │
│ │ 容器层  --cap-add=SYS_ADMIN   以 devuser (非 root) 运行 │ │
│ │                                                       │ │
│ │  ┌── GitHub Copilot Agent ──────────────────────┐    │ │
│ │  │  VS Code 扩展进程                              │    │ │
│ │  │                                               │    │ │
│ │  │  沙箱层 1: ✗ 无                               │    │ │
│ │  │    bwrap 无法包裹扩展进程，不受 namespace 保护  │    │ │
│ │  │                                               │    │ │
│ │  │  沙箱层 2: .vscode/settings.json              │    │ │
│ │  │    chat.agent.sandbox.* (仅约束终端工具)       │    │ │
│ │  └──────────────────────────────────────────────┘    │ │
│ │                                                       │ │
│ │  ┌── Claude Code CLI ───────────────────────────┐    │ │
│ │  │  /usr/local/bin/claude (shim, 构建期植入)      │    │ │
│ │  │  ↓ exec                                       │    │ │
│ │  │  .devcontainer/claude-wrapper.sh              │    │ │
│ │  │  ↓                                           │    │ │
│ │  │  沙箱层 1: ✓ bubblewrap                       │    │ │
│ │  │    ├── tmpfs        core/src                  │    │ │
│ │  │    ├── ro-bind-self .git (可读不可写)          │    │ │
│ │  │    └── ro-bind /dev/null  .env, .env.*        │    │ │
│ │  │  ↓                                           │    │ │
│ │  │  claude-real (/usr/local/bin/claude-real)     │    │ │
│ │  │  ↓                                           │    │ │
│ │  │  沙箱层 2: .claude/settings.json              │    │ │
│ │  │    sandbox 规则 (所有工具)                     │    │ │
│ │  └──────────────────────────────────────────────┘    │ │
│ └──────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 隔离策略

对 Claude Code CLI 而言，bubblewrap 通过 mount namespace 在文件系统层做路径级覆盖（tmpfs / ro-bind / ro-bind-self），对该进程及其所有子进程、所有 syscall 一视同仁——无论用 `cat`、`open(2)` 还是其他工具都看到同一份视图。注意 bwrap 没有启用 `--unshare-net`，网络仍走容器层。下表"隔离方式"按强度排序，**强保护**是真正的边界，**兜底**仅用于纵深防御：

| 路径 | 读权限 | 写权限 | bwrap 层（沙箱层 1） | 应用层（沙箱层 2） |
|------|--------|--------|---------------------|-------------------|
| `core/src/**` | ❌ 不可见 | ❌ 禁止 | **强**：tmpfs 空目录覆盖 | settings.json denyRead + denyWrite |
| `core/include/**` | ✅ 可读 | ✅ 可写 | 正常挂载 | — |
| `.env`, `.env.*` | ❌ 不可读 | ❌ 禁止 | **强**：`/dev/null` 绑定覆盖 | settings.json denyRead + denyWrite |
| `.claude/settings.json` | ✅ 可读 | ❌ 禁止 | 正常挂载 | settings.json denyWrite（防误改） |
| `.git/**` | ✅ 可读 | ❌ 禁止 | **强**：`ro-bind-self` 自身只读绑定 | settings.json denyWrite |
| 工作区外路径（如 `~/.ssh`） | ❌ 不可见 | ❌ 不可见 | **强**：容器层不挂载 | — |
| 其他工作区文件 | ✅ 正常访问 | ✅ 正常访问 | 正常挂载 | — |

> 关于 `.git`：选择"可读不可写"而不是完全隐藏，是因为 agent 经常需要 `git log/diff/blame` 这类只读操作辅助理解代码。允许读、禁止写（`config`、`hooks`、`HEAD` 都不能改）是兼顾可用性与安全的折中。如果你的场景里 `.git` 含敏感凭据（如 `.git/config` 写了 token），改成 `tmpfs .git` 即可。

容器需要 `--cap-add=SYS_ADMIN` 以支持 bubblewrap 命名空间隔离。

### 项目结构

```
core/
├── src/        # 源码（沙箱隔离：不可读写）
└── include/    # 头文件（可读写）
demo/           # 可执行程序
.claude/
└── settings.json         # Claude Code CLI 内置 deny / sandbox 配置
.vscode/
└── settings.json    # GitHub Copilot Agent 终端沙箱配置
.devcontainer/
├── devcontainer.json    # 容器配置
├── bwrap-policy.conf    # bubblewrap 路径隔离策略（沙箱层 1）
├── setup.sh             # 容器创建时初始化（仅做检查与插件 bootstrap）
├── claude-shim.sh       # 镜像构建期植入 /usr/local/bin/claude，转发到 wrapper
└── claude-wrapper.sh    # Claude CLI 沙箱包装器（实际执行 bwrap）
images/
└── Dockerfile           # 容器镜像构建配置
```

### 运行身份：devuser（非 root）

容器内 AI agent 一律以非特权用户 `devuser` 身份运行，不使用 root。原因：

- **限制误操作爆炸半径**：AI agent 推理失误或受提示注入时，root 下一条危险命令可能毁掉容器并污染宿主挂载目录；非 root 把破坏面限制在 devuser 家目录与可写工作区
- **容器逃逸防御纵深**：万一遇到内核或 runtime 漏洞，root-in-container 往往等价于 root-on-host，非 root 多一层缓冲
- **文件权限对齐宿主**：`devcontainer.json` 的 `updateRemoteUserUID: true` 让 devuser 的 UID 在首次 attach 时自动对齐宿主用户 UID，避免挂载卷里出现 root 拥有的文件污染宿主
- **匹配工具链假设**：`npm`、`pip` 等在 root 下要么警告要么拒绝；以非 root 运行更接近真实开发与生产环境

**设计取舍：**

| 决策 | 说明 |
|------|------|
| 不安装 `sudo` | 最小信任面。需要新增系统包请改 Dockerfile 后重建镜像 |
| `claude` wrapper 在镜像构建期植入 | 避免运行时切换权限。`/usr/local/bin/claude` 是构建期 COPY 的 shim，工作区里的 `claude-wrapper.sh` 可热改 |
| UID/GID 在 Dockerfile 里固定为 1000 | Ubuntu 24.04 基础镜像自带的 `ubuntu` 用户会被显式删除，让 devuser 取 1000；`updateRemoteUserUID` 再在 attach 时按宿主调整 |
| 不挂 `~/.ssh`、`~/.gitconfig` 等宿主凭据 | devuser 干净启动，避免凭据穿透 |

**何时会感到不便：**

- 想 `apt install` 临时工具 → 改 Dockerfile 重建镜像
- 想绑定 80/443 端口 → 用 1024 以上端口，或在镜像里 `setcap`
- `.git` 写操作（commit/push）→ 在 bwrap 内拦截（见上文）；从宿主或非 sandboxed shell 操作

## 运维与排错

### 容器运行时

#### Docker vs Podman

| 功能 | Docker | Podman |
|------|--------|--------|
| `--cap-add=SYS_ADMIN` | ✅ | ✅ |
| `--security-opt=label=disable` | ✅ (忽略) | ✅ (SELinux) |
| Rootless 模式 | 需配置 rootless-kit | 原生支持 |
| 守护进程 | 需要 dockerd | 无需守护进程 |
| Socket 路径 | `/var/run/docker.sock` | `XDG_RUNTIME_DIR/podman/podman.sock` |

#### 验证

**Docker：**

```bash
docker --version
docker info
```

**Podman：**

```bash
podman --version
podman info
```

**配置 VS Code 使用 Podman：**

```json
// settings.json
{
  "dev.containers.dockerPath": "podman"
}
```

### 故障排查

#### 常见问题

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| `bwrap namespace test: FAILED`（setup 中止） | 容器/VM 不支持 user namespace | Linux 宿主：检查 `sysctl kernel.unprivileged_userns_clone`。Windows：必须用 WSL2 而不是原生 Hyper-V。macOS：Docker Desktop / Podman libkrun 的 VM 通常不支持，没有官方解；可考虑在 Linux 服务器或 Linux 虚拟机里跑此沙箱 |
| `bwrap: permission denied` | 容器缺少 SYS_ADMIN 能力 | 检查 `devcontainer.json` 的 `runArgs` 包含 `--cap-add=SYS_ADMIN` |
| `claude: command not found` | 镜像构建未完成或损坏 | 检查容器构建日志，确认 `npm install -g @anthropic-ai/claude-code` 与 `COPY .devcontainer/claude-shim.sh` 都成功 |
| `claude: WORKSPACE_ROOT is not set` | shim 在非 devcontainer 环境下被调用 | 在 shell 里手动 `export WORKSPACE_ROOT=$(pwd)` 再运行 |
| `claude-wrapper: wrapper not found or not executable` | 工作区里的 `.devcontainer/claude-wrapper.sh` 丢失或权限错乱 | 确认仓库完整、文件有 +x 权限：`chmod +x .devcontainer/claude-wrapper.sh` |
| `.git` 写操作报 Read-only file system | 正常现象 | bwrap 的 ro-bind-self 物理上拦截写。如确需写 `.git`，从宿主或非 sandboxed shell 操作 |
| SELinux 阻止访问 | Fedora/RHEL/CentOS SELinux 策略 | 确认 `--security-opt=label=disable` 已配置 |

#### 诊断命令

```bash
# 1) 运行身份
id                                # 应为 devuser，UID 与宿主对齐
echo "WORKSPACE_ROOT=${WORKSPACE_ROOT:-not set}"

# 2) bwrap 可用性
bwrap --version
bwrap --die-with-parent --bind / / --true && echo "bwrap OK" || echo "bwrap FAILED"

# 3) shim / 真二进制布局
ls -l /usr/local/bin/claude /usr/local/bin/claude-real
head -1 /usr/local/bin/claude     # 应为 #!/usr/bin/env bash (shim)

# 4) 认证
echo "ANTHROPIC_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:+set}"

# 5) 测试沙箱隔离效果（在 claude 进程内执行才有意义；以下从外部测试 ro-bind 是否生效）
cat .env 2>/dev/null && echo "WARNING: .env readable from shell (this is expected outside bwrap)"
ls core/src/ 2>/dev/null | head  # 同上，外部 shell 不受 bwrap 约束
# 真正的隔离测试需要让 claude 自己尝试读这些路径。
```

#### 重建沙箱

wrapper 和 `claude-real` 在镜像构建期就已经装好（见 `images/Dockerfile`），不存在"运行时安装失败"的状态。如果 sandbox 行为异常：

```bash
# 1) 验证镜像内的二进制布局是否正确
ls -l /usr/local/bin/claude /usr/local/bin/claude-real
/usr/local/bin/claude-real --version

# 2) 验证 bwrap 仍能创建 namespace
bwrap --die-with-parent --bind / / --true && echo OK

# 3) 如果都没问题但行为不对，从宿主重建镜像
#    VS Code: Dev Containers: Rebuild Container
```

容器内的 devuser **不具备 sudo 权限**（设计如此，最小信任面）。如果需要新增系统包，请修改 `images/Dockerfile` 后重建镜像，不要试图在运行时安装。

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code CLI | 2.1.161 | 锁定版本，确保一致性 |
| Ubuntu | 24.04 | LTS 版本 |
| Node.js | 22.x | LTS 版本 |
| bubblewrap | 系统 package | Ubuntu 24.04 版本 |