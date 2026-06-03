# Windows 环境下 Claude Code CLI 沙箱示例

在 Docker/Podman 容器中运行 Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

沙箱为 AI 辅助开发提供安全边界：防止意外修改敏感源码、泄露环境变量密钥、执行危险命令，同时保留 AI 助手的开发能力。

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

3. **使用 Claude Code**：容器启动后自动配置沙箱，直接使用 Claude Code for VS Code 扩展即可

4. **构建 Demo**（可选）：

   ```bash
   cmake -S . -B build && cmake --build build
   ./build/demo/demo
   ```

## 架构概览

本示例使用 **bubblewrap** (`bwrap`) 构建沙箱，它依赖 Linux 内核的 namespace 特性实现文件系统隔离。Windows 内核没有 namespace，需通过 WSL2 + Docker/Podman 容器获得 Linux 环境：

```
Windows → WSL2 (Linux 内核) → 容器 → bubblewrap 沙箱 → Claude Code
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

**双重隔离：**
- **容器层**：Docker/Podman 限制对宿主机资源的访问
- **沙箱层**：bubblewrap 在容器内进一步限制文件系统访问

## 项目结构

```
core/
├── src/        # 源码（沙箱隔离：不可读写）
└── include/    # 头文件（可读写）
demo/           # 可执行程序
.claude/
└── settings.json    # Claude Code 沙箱配置（权限与隔离规则）
.devcontainer/
├── devcontainer.json    # 容器配置
├── setup.sh             # 容器创建时初始化
└── claude-wrapper.sh    # Claude CLI 沙箱包装器
images/
└── Dockerfile           # 容器镜像构建配置
```

## 隔离策略

| 路径 | 读权限 | 写权限 | 隔离方式 |
|------|--------|--------|----------|
| `core/src/**` | ❌ 不可见 | ❌ 禁止 | tmpfs 空目录覆盖 + settings.json deny |
| `core/include/**` | ✅ 可读 | ✅ 可写 | 正常挂载 |
| `.env`, `.env.*` | ❌ 不可读 | ❌ 禁止 | /dev/null 绑定 + settings.json deny |
| `.claude/settings.json` | ✅ 可读 | ❌ 禁止 | settings.json denyWrite |
| `.git/config`, `.git/credentials` | ❌ 不可读 | ❌ 禁止 | settings.json deny |
| `.ssh/**` | ❌ 不可读 | ❌ 禁止 | settings.json deny |
| `**/*.pem`, `**/*.key`, `**/*.p12` | ❌ 不可读 | ❌ 禁止 | settings.json deny |
| `.npmrc`, `.pypirc`, `.netrc` | ❌ 不可读 | ❌ 禁止 | settings.json deny |
| 其他文件 | ✅ 正常访问 | ✅ 正常访问 | 正常挂载 |

容器需要 `--cap-add=SYS_ADMIN` 以支持 bubblewrap 命名空间隔离。

## 容器运行时

### Docker vs Podman

| 功能 | Docker | Podman |
|------|--------|--------|
| `--cap-add=SYS_ADMIN` | ✅ | ✅ |
| `--security-opt=label=disable` | ✅ (忽略) | ✅ (SELinux) |
| Rootless 模式 | 需配置 rootless-kit | 原生支持 |
| 守护进程 | 需要 dockerd | 无需守护进程 |
| Socket 路径 | `/var/run/docker.sock` | `XDG_RUNTIME_DIR/podman/podman.sock` |

### 验证

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

## 故障排查

### 常见问题

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| `bwrap: permission denied` | 容器缺少 SYS_ADMIN 能力 | 检查 `devcontainer.json` 的 `runArgs` 包含 `--cap-add=SYS_ADMIN` |
| `bwrap: create namespace failed` | 内核不支持 user namespace | 确认使用 WSL2 + Docker/Podman，不是原生 Windows |
| `claude: command not found` | CLI 未安装或 wrapper 配置失败 | 检查容器构建日志，确认 `npm install -g @anthropic-ai/claude-code` 成功 |
| wrapper 未生效 | setup.sh 执行失败 | 检查 `postCreateCommand` 输出，确认 wrapper 安装成功 |
| `.env` 仍可读取 | bwrap 回退到权限沙箱 | 检查 bwrap 是否可用，settings.json 应仍提供保护 |
| SELinux 阻止访问 | Fedora/RHEL/CentOS SELinux 策略 | 确认 `--security-opt=label=disable` 已配置 |
| 权限不足 (非 root 用户) | devuser 无法修改系统路径 | wrapper 安装需要 sudo/root，setup.sh 会尝试使用 sudo |

### 诊断命令

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

### 重置沙箱

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