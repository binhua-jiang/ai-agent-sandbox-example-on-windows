# AI Agent 安全沙箱参考实现

在 Docker/Podman 容器中运行 GitHub Copilot Agent & Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

沙箱的价值在于**为 AI Agent 划定可触达的资源边界**，采用双层防护：
- **容器层**：宿主机未挂载到容器的目录，agent 天然无法触及；
- **沙箱层**：对已挂载进容器的敏感文件（如 `.env`、`core/src/`），由 bubblewrap 通过内核 namespace 用 tmpfs / `/dev/null` 覆盖，使其在 agent 视野中物理消失。

"看不到"即"动不了"，从而在保留 AI 编码能力的同时，避免核心源码泄漏、密钥外泄和危险命令对宿主机的影响。

> ⚠️ **沙箱层的强度因 agent 而异，差距巨大：**
> - **Claude Code CLI**：bubblewrap 在内核 namespace 层做隔离，对 CLI 进程及其所有子进程、syscall 一视同仁，强度高。
> - **GitHub Copilot Agent**：其内置的 `chat.agent.sandbox.*` 实际只是"**终端沙箱**"，仅约束 `run_in_terminal` 工具；`readFile` / `grepSearch` 等内建文件工具走扩展进程的文件系统 API，**完全绕过** `denyRead` 规则。也就是说，仅靠 VS Code 原生设置**无法**阻止 Copilot Agent 读取 `.env`。
>
> 因此，**容器层（决定"挂不挂"）才是真正可靠的边界**；沙箱层是纵深防御。详见下文 [Claude Code CLI 沙箱 vs GitHub Copilot Agent 沙箱](#claude-code-cli-沙箱-vs-github-copilot-agent-沙箱)。

## 快速开始

### 前置条件

- Docker 20.10+ 或 Podman 4.0+
- VS Code + Dev Containers 扩展
- WSL2（Windows 用户）

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
| **覆盖** | bwrap 用 tmpfs 空目录覆盖；`/dev/null` 绑定 | ★★★★☆ 物理上不可见 | 必须留在仓库里的敏感文件（`.env`、`core/src/`） |
| **网络隔离** | 容器网络策略；bwrap `--unshare-net` | ★★★★☆ | 阻止数据外发 |
| **应用层 deny 规则** | `.claude/settings.json`、VS Code 配置 | ★★☆☆☆ 可绕过 | 防误操作的纵深防御，不可作为唯一防线 |

**举例：**
- 保护 `~/.ssh/id_rsa`：✅ 容器层不挂载主目录（强保护）。❌ 挂载主目录 + denyRead（弱）。
- 保护 `.env`（必须留在仓库内）：✅ bwrap 用 `/dev/null` 绑定覆盖（强保护）；settings.json deny 仅兜底。
- 保护 `core/src/`：✅ bwrap 用 tmpfs 空目录覆盖，让 CLI 在沙箱里看不到任何内容（强保护）；settings.json deny 兜底。

### Claude Code CLI 沙箱 vs GitHub Copilot Agent 沙箱

两者都叫"沙箱"，但**隔离层级和作用范围差异巨大**，理解这点才能避免误判安全边界。

| 维度 | Claude Code CLI | GitHub Copilot Agent |
|------|--------------------|--------------------|
| 实现层级 | Linux 内核 namespace（bubblewrap） | VS Code 扩展进程的命令拦截 |
| 作用范围 | 整个 CLI 进程 + 所有子进程 + 所有 syscall | 仅 `run_in_terminal` 工具 |
| 内建工具（`readFile`/`grepSearch`/`listDir` 等） | ✅ 受 namespace 约束 | ❌ 完全绕过沙箱 |
| 文件隐藏 | tmpfs / `/dev/null` 物理覆盖，真正不可见 | 仅靠 `denyRead` 配置，工具不遵守 |
| 网络隔离 | 容器层 + bwrap namespace | `chat.agent.networkFilter` 仅约束 fetch 工具与内置浏览器 |
| 配置位置 | `.claude/settings.json` + wrapper 脚本 | `.vscode/settings.json` 的 `chat.agent.sandbox.*` |
| 绕过难度 | 需突破内核 namespace | 调用任意非终端工具即可 |

**结论：**
- **Claude Code CLI**：真正的隔离来自 bwrap（决定 CLI "看不看得到"）；`settings.json` 的 deny 规则只是兜底，用于防误操作和纵深防御。
- **GitHub Copilot Agent**：`chat.agent.sandbox.*` 实际是"**终端沙箱**"而非"**工具沙箱**"——`readFile` 等内建工具走扩展进程的文件系统 API，**完全绕过** `denyRead`。仅靠它**无法阻止** Agent 读取 `.env`。

## 实现细节

### 架构概览

本示例采用 **容器 + bubblewrap** 的双层隔离：
- **容器层**（Docker/Podman）：限定挂载到容器的宿主机目录，约束 VS Code Server、Copilot Agent 及 Claude Code CLI 的整体可达范围。
- **沙箱层**（bubblewrap）：在容器内进一步包裹 Claude Code CLI 进程，用 namespace 把已挂载但敏感的路径物理隐藏。

bubblewrap 依赖 Linux 内核的 namespace 特性；Windows 内核没有 namespace，需通过 WSL2 + Docker/Podman 容器获得 Linux 环境：

```
Windows → WSL2 (Linux 内核) → 容器 → bubblewrap 沙箱 → Claude Code CLI
```

**架构图：**

```
┌───────────────────────────────────────────────────────────┐
│ 宿主机 (Host)                                              │
│ ┌───────────────────────────────────────────────────────┐ │
│ │ VS Code + Dev Containers 扩展                          │ │
│ │        ↓ Dev Containers: Reopen in Container          │ │
│ │ Docker / Podman                                        │ │
│ └───────────────────────────────────────────────────────┘ │
│                          ↓                                 │
│ ┌───────────────────────────────────────────────────────┐ │
│ │ 容器 (Container) --cap-add=SYS_ADMIN                   │ │
│ │ ┌───────────────────────────────────────────────────┐ │ │
│ │ │ VS Code Server + Claude Code for VS Code            │ │ │
│ │ │        ↓                                          │ │ │
│ │ │ /usr/local/bin/claude (wrapper script)            │ │ │
│ │ │        ↓                                          │ │ │
│ │ │ ┌───────────────────────────────────────────────┐ │ │ │
│ │ │ │ bubblewrap 沙箱 (namespace 隔离)               │ │ │ │
│ │ │ │ ├── 挂载项目目录 (可读写)                      │ │ │ │
│ │ │ │ ├── tmpfs 覆盖 core/src (不可见)               │ │ │ │
│ │ │ │ └── /dev/null 绑定 .env (屏蔽密钥)             │ │ │ │
│ │ │ │        ↓                                       │ │ │ │
│ │ │ │ claude-real (真实 CLI)                         │ │ │ │
│ │ │ └───────────────────────────────────────────────┘ │ │ │
│ │ └───────────────────────────────────────────────────┘ │ │
│ └───────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

### 隔离策略

本项目通过 bubblewrap 在内核 namespace 层做物理隔离，对所有进程（包括 CLI 子进程及未来可能新增的工具）一视同仁。下表"隔离方式"按强度排序，**强保护**是真正的边界，**兜底**仅用于纵深防御：

| 路径 | 读权限 | 写权限 | 隔离方式 |
|------|--------|--------|----------|
| `core/src/**` | ❌ 不可见 | ❌ 禁止 | **强**：tmpfs 空目录覆盖；**兜底**：settings.json deny |
| `core/include/**` | ✅ 可读 | ✅ 可写 | 正常挂载 |
| `.env`, `.env.*` | ❌ 不可读 | ❌ 禁止 | **强**：`/dev/null` 绑定覆盖；**兜底**：settings.json deny |
| `.claude/settings.json` | ✅ 可读 | ❌ 禁止 | **弱**：仅 settings.json denyWrite（防误改） |
| `.git/config`, `.git/credentials` | ❌ 不可读 | ❌ 禁止 | settings.json deny（建议配合 bwrap 用 `/dev/null` 绑定覆盖） |
| 工作区外路径（如 `~/.ssh`） | ❌ 不可见 | ❌ 不可见 | **强**：容器层本就不会挂载这些宿主机目录 |
| 其他工作区文件 | ✅ 正常访问 | ✅ 正常访问 | 正常挂载 |

容器需要 `--cap-add=SYS_ADMIN` 以支持 bubblewrap 命名空间隔离。

### 项目结构

```
core/
├── src/        # 源码（沙箱隔离：不可读写）
└── include/    # 头文件（可读写）
demo/           # 可执行程序
.claude/
└── settings.json    # Claude Code CLI 沙箱配置（权限与隔离规则）
.vscode/
└── settings.json    # GitHub Copilot Agent 终端沙箱配置
.devcontainer/
├── devcontainer.json    # 容器配置
├── setup.sh             # 容器创建时初始化
└── claude-wrapper.sh    # Claude CLI 沙箱包装器
images/
└── Dockerfile           # 容器镜像构建配置
```

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
| `bwrap: permission denied` | 容器缺少 SYS_ADMIN 能力 | 检查 `devcontainer.json` 的 `runArgs` 包含 `--cap-add=SYS_ADMIN` |
| `bwrap: create namespace failed` | 内核不支持 user namespace | 确认使用 WSL2 + Docker/Podman，不是原生 Windows |
| `claude: command not found` | CLI 未安装或 wrapper 配置失败 | 检查容器构建日志，确认 `npm install -g @anthropic-ai/claude-code` 成功 |
| wrapper 未生效 | setup.sh 执行失败 | 检查 `postCreateCommand` 输出，确认 wrapper 安装成功 |
| `.env` 仍可读取 | bwrap 回退到权限沙箱 | 检查 bwrap 是否可用，settings.json 应仍提供保护 |
| SELinux 阻止访问 | Fedora/RHEL/CentOS SELinux 策略 | 确认 `--security-opt=label=disable` 已配置 |
| 权限不足 (非 root 用户) | devuser 无法修改系统路径 | wrapper 安装需要 sudo/root，setup.sh 会尝试使用 sudo |

#### 诊断命令

```bash
# 检查 bwrap 是否可用
bwrap --version
bwrap --die-with-parent --bind / / --true && echo "bwrap OK" || echo "bwrap FAILED"

# 检查 claude wrapper 是否安装
which claude
ls -la $(which claude)
ls -la $(dirname $(which claude))/claude-real 2>/dev/null && echo "wrapper installed"

# 检查环境变量
echo "WORKSPACE_ROOT: ${WORKSPACE_ROOT:-not set}"
echo "ANTHROPIC_AUTH_TOKEN: ${ANTHROPIC_AUTH_TOKEN:+set}"

# 测试隔离效果（应该失败或返回空）
cat .env 2>/dev/null && echo "WARNING: .env readable!" || echo "OK: .env blocked"
ls core/src/ 2>/dev/null && echo "WARNING: core/src visible!" || echo "OK: core/src blocked"
```

#### 重置沙箱

如果 wrapper 配置出现问题，可以手动重置：

```bash
sudo mv /usr/local/bin/claude-real /usr/local/bin/claude
bash .devcontainer/setup.sh
```

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code CLI | 2.1.161 | 锁定版本，确保一致性 |
| Ubuntu | 24.04 | LTS 版本 |
| Node.js | 22.x | LTS 版本 |
| bubblewrap | 系统 package | Ubuntu 24.04 版本 |