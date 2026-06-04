# Windows 的 AI Agent 安全沙箱配置案例

在 Docker/Podman 容器中运行 **GitHub Copilot Agent** 与 **Claude Code CLI** 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

沙箱采用 **L1–L4 四层模型**：越外层越接近"内核硬隔离"，越内层越是"应用自律"。**每层对两个 agent 的覆盖强度不同**——这是理解整个项目的关键。

## 沙箱 4 层模型总览

| 层 | 实现 | 默认状态 | Claude Code CLI | GitHub Copilot Agent |
|----|------|---------|-----------------|---------------------|
| **L1 容器层** | Docker/Podman 限定挂载、能力、网络 | ✅ 始终生效 | ★★★★★ 内核级 | ★★★★★ 内核级 |
| **L2 内置 Bash/终端沙箱** | agent 自身实现 | ✅ 默认 | ★★★★☆ 内核级 bwrap 包 Bash 子进程 | ★★☆☆☆ 扩展进程级命令拦截 |
| **L3 内置 deny/read/write 规则** | `.claude/settings.json` / `.vscode/settings.json` | ✅ 默认 | ★★★☆☆ 覆盖**所有内置工具** | ★★☆☆☆ **仅约束终端**，内置文件工具完全绕过 |
| **L4 外层 bwrap**（可选） | `.devcontainer/claude-wrapper.sh` | 🔘 `CLAUDE_USE_BWRAP=1` | ★★★★☆ 包整个 claude 进程，syscall 级 | ❌ 不适用（Copilot 跑在 VS Code 扩展进程） |

**两条关键结论：**

1. **只有 L1 对两个 agent 是平等的强保护**。L2/L3 在 Copilot 上明显弱化，L4 完全不覆盖 Copilot。对必须防 Copilot 的敏感内容，唯一可靠手段是**L1 不挂载**。
2. **默认 L1+L2+L3 三层够用**：对 Claude，`Read`/`Edit`/`Write` 走 L3，`Bash` 走 L2，已覆盖常见威胁。**L4 是给"装外部 MCP 服务器、要求文件存在性隐藏、syscall 级强约束"等场景的额外保险**，仅 Linux/WSL2 可用。

## 快速开始

### 前置条件

- Docker 20.10+ 或 Podman 4.0+
- VS Code + Dev Containers 扩展
- **平台兼容性**：默认配置（L1+L2+L3）在 Linux / WSL2 / macOS Docker Desktop 上**都能正常运行**
- **L4 仅在 Linux/WSL2 可用**：
  - Linux 宿主：原生支持 user namespace
  - Windows：WSL2 + Docker/Podman
  - **macOS**：Docker Desktop / Podman libkrun 的 Linux VM 不开放 user namespace，即便加了 `CAP_SYS_ADMIN` 也跑不起来 bwrap——在 macOS 上**不要**设 `CLAUDE_USE_BWRAP=1`，否则 claude 启动会直接 hard-fail
  - **Ubuntu 24.04+ 宿主**：宿主默认 `kernel.apparmor_restrict_unprivileged_userns=1` 会阻止非特权 userns。本仓库已在镜像层（setuid bwrap）+ 容器层（`apparmor=unconfined`）规避，无需改宿主配置

### 步骤

1. **配置认证**（`cp .env.example .env` 后填值）：

   ```bash
   ANTHROPIC_AUTH_TOKEN=your-key      # 或 ANTHROPIC_API_KEY
   # ANTHROPIC_BASE_URL=...           # 可选，自定义 API 端点 / 网关
   # ANTHROPIC_MODEL=...              # 可选，固定模型
   # CLAUDE_USE_BWRAP=1               # 可选，启用 L4 外层 bwrap（仅 Linux/WSL2）
   ```
   完整模板见仓库根目录的 `.env.example`。

2. **在 VS Code 中打开容器**：执行 "Dev Containers: Reopen in Container"

3. **使用 agent**：容器启动后 Claude Code CLI 和 Copilot Agent 都自动按各自的 L2/L3 规则受约束；直接使用即可

4. **构建 Demo**（可选）：

   ```bash
   cmake -S . -B build && cmake --build build
   ./build/demo/demo
   ```

## L1：容器层

**作用**：限定从宿主到容器的挂载、网络、能力。**对两个 agent 平等强保护**——这是 4 层中唯一一条真正无歧视的边界，也是最可靠的一道。

**实现位置**：`.devcontainer/devcontainer.json` + `images/Dockerfile`

**关键约束**：
- 工作区目录是唯一被挂载进来的宿主路径——`~/.ssh`、`~/.aws`、`~/.gitconfig` 等都**没挂**，agent 看不见
- 容器以非特权用户 `devuser`（UID 1000）运行，不是 root
- 加了 `--cap-add=SYS_ADMIN` 与 `--security-opt=apparmor=unconfined`——这两个是给 **L2 的 Claude 内置 Bash 沙箱**（也用 bwrap）放行 user namespace 需要的，不是给 agent 自己用的

**为什么 L1 才是真正的边界**：一旦某文件挂进容器，无论 L2/L3/L4 做什么文章，理论上都可能被绕过；唯一不可绕的是"**这个路径在容器里根本不存在**"。设计敏感数据保护时，**第一选择永远是不挂载**。

| 路径 | L1 状态 | 后果 |
|------|---------|------|
| `~/.ssh`、宿主主目录、宿主任意 | ❌ 不挂载 | agent 看不见，无从读写——这是最强保护 |
| 工作区目录 | ✅ 挂载（读写） | 后续靠 L2/L3/L4 细分 |

## L2：内置 Bash/终端沙箱

**作用**：限制 agent 执行的 shell 命令能访问哪些文件/网络。两个 agent 都有这一层，但实现机制完全不同。

### L2 在 Claude Code CLI：内核级 bwrap

Claude Code CLI 在 Linux 上**内部就用 bubblewrap** 包裹每次 `Bash` 工具调用及其所有子进程，做 mount namespace + 网络过滤的隔离。这是 Claude 官方文档明确的实现机制，不依赖我们这个仓库的 L4。

- **生效范围**：`Bash` 工具及其所有子进程、syscall
- **不覆盖**：`Read`/`Edit`/`Write` 等不通过 shell 的工具——这些走 L3
- **配置**：`.claude/settings.json` 的 `sandbox` 块（`filesystem.denyRead/denyWrite/allowWrite`、`network.allowedDomains` 等）
- **依赖**：bubblewrap + socat（镜像已装）、`CAP_SYS_ADMIN`、user namespace 支持

参考：[Claude Code Sandboxing 文档](https://code.claude.com/docs/en/sandboxing)

### L2 在 GitHub Copilot Agent：扩展进程级命令拦截

Copilot 的 `chat.agent.sandbox.*` 是 **VS Code 扩展进程**层面的命令字符串拦截——不创建 namespace，不进入内核。仅约束 `run_in_terminal` 工具，强度比 Claude 的 L2 低一个数量级。

- **生效范围**：仅 `run_in_terminal`
- **配置**：`.vscode/settings.json` 的 `chat.agent.sandbox.*`、`chat.agent.networkFilter`
- **绕过方式**：调用非终端工具即可——见 L3 一节

### L2 强度对比

| 维度 | Claude L2 | Copilot L2 |
|------|-----------|------------|
| 实现 | Linux 内核 bubblewrap namespace | VS Code 扩展进程命令拦截 |
| 覆盖范围 | `Bash` + 所有子进程 + 所有 syscall | 仅 `run_in_terminal` |
| 文件隔离 | 内核 mount namespace | 命令前置检查 |
| 网络隔离 | 内置代理 + 域名 allowlist | 扩展层 fetch 拦截 |
| 绕过难度 | 需突破 namespace | 改用非终端工具 |

## L3：内置 deny/read/write 规则

**作用**：在 agent **决定调用某个工具之前**，由 agent 自身评估权限规则、决定放行/拒绝/询问。两个 agent 都有，但覆盖范围天差地别。

### L3 在 Claude Code CLI：覆盖所有内置工具

`.claude/settings.json` 的 `permissions.deny` / `permissions.allow` 应用于**所有内置工具**：`Read`、`Edit`、`Write`、`Bash`、`Glob`、`Grep`、`WebFetch`、`MCP` 调用。`sandbox.filesystem.*` 同时也被 L2（Claude 内置 Bash 沙箱）用作 bwrap 的 deny 列表。

- **生效范围**：所有内置工具的调用入口
- **MCP 工具**：是否走这套规则取决于具体 MCP 实现——大多数走，但不保证
- **配置**：`.claude/settings.json` 的 `permissions.deny` + `sandbox.filesystem.*`

本仓库 L3 配置示例：

| 路径 | L3 配置 | 效果 |
|------|--------|------|
| `.env`、`.env.*` | `Read(./.env*)` deny + `sandbox.filesystem.denyRead` | 内置工具读不到 |
| `core/src/**` | `Read(./core/src/**)` deny + denyRead/denyWrite | 内置工具读写不到 |
| `.git/**` | `Edit(./.git/**)` deny + denyWrite | 可读不可写 |
| `.claude/settings.json` 自身 | `Edit(./.claude/settings.json)` deny | 防 agent 修改自己规则 |

### L3 在 GitHub Copilot Agent：仅约束终端，内置文件工具完全绕过

这是 Copilot 沙箱**最大的认知陷阱**：`chat.agent.sandbox.fileSystem.linux.denyRead/denyWrite` **只在 `run_in_terminal` 工具上生效**。Copilot 的 `readFile`、`grepSearch`、`listDir` 等内置文件工具走 VS Code 扩展进程的文件系统 API，**完全不过这套规则**。

**也就是说：仅靠 `.vscode/settings.json` 的 `denyRead`，根本拦不住 Copilot 读 `.env`**。

- **生效范围**：仅 `run_in_terminal` 工具
- **绕过方式**：Copilot 默认调用 `readFile` 而不是 `cat`——天然绕过
- **配置**：`.vscode/settings.json` 的 `chat.agent.sandbox.fileSystem.*`

### L3 强度对比

| 内置工具 | Claude L3 | Copilot L3 |
|---------|-----------|------------|
| 读文件 | ✅ `Read` 走 `permissions.deny` | ❌ `readFile` 绕过 sandbox 规则 |
| 写文件 | ✅ `Edit`/`Write` 走 `permissions.deny` | ❌ `applyPatch` 等绕过 |
| 跑 shell | ✅ `Bash` 受 L3 检查 + L2 bwrap 双层 | ⚠️ `run_in_terminal` 受 L3 检查 |
| 搜索 | ✅ `Grep`/`Glob` 走 `permissions.deny` | ❌ `grepSearch` 绕过 |

**结论**：对 Copilot 而言，L3 几乎只是个**反垃圾命令机制**，不是数据保护机制。**Copilot 的敏感数据保护必须靠 L1。**

## L4：外层 bwrap（可选，仅 Claude）

**作用**：把整个 `claude` 进程包进 bubblewrap 的 mount namespace，按 `.devcontainer/bwrap-policy.conf` 做路径级覆盖。补足 L2/L3 在 MCP 工具、未知工具、文件存在性隐藏方面的盲区。

**默认关闭**。需要时在 `.env` 加：

```bash
CLAUDE_USE_BWRAP=1
```

**关键限制**：**仅 Claude，仅 Linux/WSL2**。Copilot 跑在 VS Code 扩展进程，不在我们包的 `claude` 进程里，L4 完全不覆盖它。

### L4 行为

| 状态 | 行为 |
|------|------|
| `CLAUDE_USE_BWRAP` 未设 / `0`（默认） | wrapper 直接 exec claude-real，跳过 bwrap |
| `CLAUDE_USE_BWRAP=1` + bwrap 可用 | wrapper 走完整 bwrap 策略 |
| `CLAUDE_USE_BWRAP=1` + bwrap 不可用（如 macOS） | wrapper hard-fail 拒绝运行，明确报错——不静默降级 |

### L4 策略（`.devcontainer/bwrap-policy.conf`）

| 路径 | bwrap 动作 | 效果 |
|------|------------|------|
| `core/src/**` | `tmpfs core/src` | namespace 内目录变空，**ls 都看不到内容** |
| `.env`、`.env.*` | `ro-bind /dev/null .env*` | 任何读 syscall 返回空 |
| `.git/**` | `ro-bind-self .git` | 可读（`git log/diff/blame` 正常），任何写 syscall 返回 `EROFS` |

### L4 解决什么 L1+L2+L3 解决不了的问题

| 威胁 | L1+L2+L3（默认 3 层） | L4（追加） |
|------|---------------------|-----------|
| Claude `Read`/`Edit`/`Write` 读敏感文件 | ✅ L3 `permissions.deny` | ✅ 重复保护 |
| Claude `Bash("cat .env")` | ✅ L2 内置 Bash 沙箱 | ✅ 重复保护 |
| **外部 MCP 服务器**用自己的方式读 `.env` | ⚠️ 取决于 MCP 是否走 L3 | ✅ namespace 内 `/dev/null` 强制 |
| **未来添加的工具**未走 L3 | ❌ 漏过 | ✅ syscall 级强制 |
| 让 agent 完全感知不到敏感文件**存在** | ❌ L3 拒绝时仍能 `ls` 看见 | ✅ tmpfs / `/dev/null` 让目录/文件视图为空 |
| 防 Copilot 读 `.env` | ❌ Copilot L3 不约束文件工具 | ❌ L4 不覆盖 Copilot |

**何时打开 L4**：
- 装了**外部 MCP 服务器**且不完全信任其权限实现
- 想做"文件存在性隐藏"（连 `ls` 都看不到敏感目录）
- 严格威胁建模要求 syscall 级隔离

**何时不要打开 L4**：
- macOS Docker Desktop / Podman libkrun（VM 不开放 userns，设了直接 hard-fail）
- 没装外部 MCP、Claude 自带工具够用的常规场景——L1+L2+L3 已足够

### L4 实现细节

链路：

```
/usr/local/bin/claude (shim, 构建期 COPY)
  ↓ exec
.devcontainer/claude-wrapper.sh
  ↓ source .env, 判定 CLAUDE_USE_BWRAP
  ├─ 未设/0  → exec claude-real
  └─ =1      → 加载 bwrap-policy.conf → exec bwrap [...] claude-real
                                          ↑ tmpfs / ro-bind / ro-bind-self
```

`bwrap-policy.conf` 支持三种动作：

- `tmpfs <path>` — 空 tmpfs 覆盖目录
- `ro-bind <src> <path>` — 绑定 `<path>` 到外部源（如 `/dev/null`）
- `ro-bind-self <path>` — 绑定 `<path>` 到自身，可读不可写

修改策略文件**无需重建镜像**，下次 claude 调用即生效。

> 关于 `.git` 选 `ro-bind-self` 而非 `tmpfs`：agent 常需 `git log/diff/blame` 辅助理解代码。允许读、禁止写（`config`、`hooks`、`HEAD` 都不能改）是兼顾可用性与安全的折中。若 `.git` 含敏感凭据（如 token 写在 `.git/config`），把这行改成 `tmpfs .git` 即可。
>
> 关于网络：bwrap 自身支持 `--unshare-net`，但本仓库**没启用**——Claude Code CLI 需要访问 `api.anthropic.com`。网络层的边界靠 L1（容器）和 L2（Claude 内置代理），不靠 L4。

## 架构图

```
┌──────────────────────────────────────────────────────────┐
│ 宿主机 (Host)                                            │
│  └─ VS Code + Dev Containers → Docker/Podman             │
│                          ↓                               │
│ ┌────────────────────────────────────────────────────┐   │
│ │ L1 容器层：--cap-add=SYS_ADMIN                       │   │
│ │             --security-opt=apparmor=unconfined      │   │
│ │             以 devuser (UID 1000) 运行              │   │
│ │                                                     │   │
│ │  ┌── GitHub Copilot Agent ────────────────────┐    │   │
│ │  │  VS Code 扩展进程                            │    │   │
│ │  │   L2: chat.agent.sandbox.*                  │    │   │
│ │  │       (扩展进程级，仅 run_in_terminal)        │    │   │
│ │  │   L3: chat.agent.sandbox.fileSystem.*       │    │   │
│ │  │       (仅约束 run_in_terminal,              │    │   │
│ │  │        readFile/grepSearch 等绕过)          │    │   │
│ │  │   L4: ✗ 不适用                              │    │   │
│ │  └────────────────────────────────────────────┘    │   │
│ │                                                     │   │
│ │  ┌── Claude Code CLI ─────────────────────────┐    │   │
│ │  │  /usr/local/bin/claude (shim)               │    │   │
│ │  │   ↓ exec                                    │    │   │
│ │  │  .devcontainer/claude-wrapper.sh            │    │   │
│ │  │   ↓ 判定 CLAUDE_USE_BWRAP                    │    │   │
│ │  │   ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄                   │    │   │
│ │  │   L4 (可选): bubblewrap 包裹                 │    │   │
│ │  │     ├── tmpfs        core/src               │    │   │
│ │  │     ├── ro-bind-self .git (可读不可写)        │    │   │
│ │  │     └── ro-bind /dev/null .env, .env.*      │    │   │
│ │  │   ↓                                         │    │   │
│ │  │  claude-real (/usr/local/bin/claude-real)   │    │   │
│ │  │   L2: 内置 Bash 沙箱 (bwrap)                 │    │   │
│ │  │   L3: .claude/settings.json                  │    │   │
│ │  │       permissions.deny + sandbox.filesystem  │    │   │
│ │  └────────────────────────────────────────────┘    │   │
│ └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

## 项目结构

```
core/
├── src/        # 源码（L3 deny + L4 tmpfs 覆盖）
└── include/    # 头文件（可读写）
demo/           # 可执行程序
.claude/
└── settings.json         # L3：Claude permissions.deny + L2：Claude 内置 Bash 沙箱配置
.vscode/
└── settings.json         # L2 + L3：Copilot 终端沙箱与 deny 规则
.devcontainer/
├── devcontainer.json     # L1：容器配置（runArgs、cap、apparmor、mounts）
├── bwrap-policy.conf     # L4：bubblewrap 路径策略
├── setup.sh              # 容器创建期检查（信息提示，不再 hard-fail）
├── claude-shim.sh        # 镜像构建期植入 /usr/local/bin/claude
└── claude-wrapper.sh     # 判定 CLAUDE_USE_BWRAP 并选择 L4 路径
images/
└── Dockerfile            # L1 镜像构建（bubblewrap setuid、devuser、Node、Claude CLI）
.env.example              # 环境变量模板（含 CLAUDE_USE_BWRAP 注释）
```

## 运行身份：devuser（非 root）

容器内 agent 一律以非特权 `devuser`（UID 1000）运行，这是 L1 的一部分。原因：

- **限制误操作爆炸半径**：root 下一条危险命令可能毁掉容器并污染宿主挂载目录；非 root 把破坏面限制在 devuser 家目录与可写工作区
- **容器逃逸防御纵深**：root-in-container 遇到内核漏洞时往往等价于 root-on-host，非 root 多一层缓冲
- **文件权限对齐宿主**：`devcontainer.json` 的 `updateRemoteUserUID: true` 让 devuser UID 在首次 attach 时自动对齐宿主用户
- **匹配工具链假设**：`npm`、`pip` 等在 root 下要么警告要么拒绝

### 设计取舍

| 决策 | 说明 |
|------|------|
| 不安装 `sudo` | 最小信任面。需要新增系统包请改 Dockerfile 重建镜像 |
| `claude` shim 在镜像构建期植入 | 避免运行时切换权限。`/usr/local/bin/claude` 是构建期 COPY 的 shim，工作区里的 `claude-wrapper.sh` 可热改 |
| UID/GID 固定为 1000 | Ubuntu 24.04 自带的 `ubuntu` 用户被 Dockerfile 显式删除让出 1000；`updateRemoteUserUID` 再按宿主调整 |
| 不挂 `~/.ssh`、`~/.gitconfig` 等宿主凭据 | 这是 L1 的一部分，避免凭据穿透 |

### 何时会感到不便

- `apt install` 临时工具 → 改 Dockerfile 重建镜像
- 绑定 80/443 端口 → 用 1024 以上端口，或在镜像里 `setcap`
- L4 开启时 `.git` 写操作 → bwrap ro-bind-self 拦截，需从宿主或非 sandboxed shell 操作

## 运维与排错

### 容器运行时：Docker vs Podman

| 功能 | Docker | Podman |
|------|--------|--------|
| `--cap-add=SYS_ADMIN` | ✅ | ✅ |
| `--security-opt=label=disable` | ✅（忽略） | ✅（SELinux） |
| `--security-opt=apparmor=unconfined` | ✅ | ✅ |
| Rootless 模式 | 需配置 rootless-kit | 原生支持 |
| 守护进程 | 需要 dockerd | 无需 |
| Socket 路径 | `/var/run/docker.sock` | `$XDG_RUNTIME_DIR/podman/podman.sock` |

**配置 VS Code 使用 Podman：**

```json
// VS Code settings.json
{
  "dev.containers.dockerPath": "podman"
}
```

### 故障排查

| 问题 | 所属层 | 原因与解决 |
|------|-------|-----------|
| `claude-wrapper: CLAUDE_USE_BWRAP=1 but bwrap cannot create user namespaces` | L4 | 当前 VM 不支持 userns（典型 macOS Docker Desktop）。删除或注释 `.env` 里的 `CLAUDE_USE_BWRAP`，或迁到 Linux/WSL2。L1+L2+L3 仍正常 |
| `claude-wrapper: CLAUDE_USE_BWRAP=1 but bwrap is not installed` | L4 | 镜像构建异常。重建镜像；检查 Dockerfile 是否被改坏 |
| `bwrap: permission denied`（Claude 内置 sandbox 报） | L2 | 容器缺 SYS_ADMIN。检查 `devcontainer.json` runArgs 含 `--cap-add=SYS_ADMIN` |
| `bwrap: setting up uid map: Permission denied`（Ubuntu 24.04+ 宿主） | L2 | 宿主 `kernel.apparmor_restrict_unprivileged_userns=1`。本仓库已通过 ① Dockerfile 给 bwrap 加 setuid，② runArgs 加 `--security-opt=apparmor=unconfined` 规避；若仍失败，宿主侧 `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` 验证 |
| Claude 内置 sandbox `Bubblewrap fails to start inside a container` | L2 | 嵌套 bwrap 无法挂载新 `/proc`。`.claude/settings.json` 的 `sandbox` 块加 `"enableWeakerNestedSandbox": true` |
| Copilot 仍能读 `.env` | L3（Copilot） | **设计上的预期行为**：Copilot 的 L3 不约束 `readFile` 等内置工具。要防 Copilot 读，唯一可靠手段是 L1（不挂载） |
| `.git` 写操作报 Read-only file system | L4 | 仅在 `CLAUDE_USE_BWRAP=1` 时发生，是 ro-bind-self 拦截。需要写 `.git` 从宿主或非 sandboxed shell 操作 |
| `claude: command not found` | L1 | 镜像构建未完成。检查容器构建日志 |
| `claude: WORKSPACE_ROOT is not set` | L4 | shim 在非 devcontainer 环境被调用。在 shell 里手动 `export WORKSPACE_ROOT=$(pwd)` |
| SELinux 阻止访问 | L1 | Fedora/RHEL/CentOS 的 SELinux。确认 `--security-opt=label=disable` 已配置 |

### 诊断命令

```bash
# L1 身份与挂载
id                                          # 应为 devuser，UID 与宿主对齐
echo "WORKSPACE_ROOT=${WORKSPACE_ROOT:-unset}"
mount | grep -E "workspaces|/home"          # 看挂载结构

# L2 / L4 的 bwrap 可用性
bwrap --version
bwrap --die-with-parent --bind / / --true && echo "bwrap OK" || echo "bwrap FAILED"

# L4 开关
echo "CLAUDE_USE_BWRAP=${CLAUDE_USE_BWRAP:-(unset, L4 disabled)}"

# Shim / 真二进制布局
ls -l /usr/local/bin/claude /usr/local/bin/claude-real
head -1 /usr/local/bin/claude              # 应为 #!/usr/bin/env bash (shim)

# 认证
echo "ANTHROPIC_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:+set}"

# 真正的 L2/L3/L4 隔离测试需要从 agent 内部调用（外部 shell 不受任何 agent 沙箱约束）
```

### 重建沙箱

shim 与 `claude-real` 在镜像构建期植入，不存在"运行时安装失败"状态。行为异常时：

```bash
# 1) 验证二进制布局
ls -l /usr/local/bin/claude /usr/local/bin/claude-real
/usr/local/bin/claude-real --version

# 2) 验证 L2/L4 依赖的 bwrap
bwrap --die-with-parent --bind / / --true && echo OK

# 3) 都没问题但行为不对 → 从宿主重建镜像
#    VS Code: Dev Containers: Rebuild Container
```

容器内 devuser **不具备 sudo 权限**（最小信任面）。新增系统包请改 Dockerfile 后重建。

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code CLI | 2.1.161 | 锁定版本，确保一致性 |
| Ubuntu | 24.04 | LTS 基础镜像 |
| Node.js | 22.x | LTS |
| bubblewrap | 系统 package | Ubuntu 24.04 版本，setuid root |
| socat | 系统 package | Claude 内置 Bash 沙箱网络代理依赖 |
