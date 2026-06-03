# Windows 环境下 Claude Code CLI 沙箱示例

在 Docker/Podman 容器中运行 Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

## 为什么需要沙箱

沙箱为 AI 辅助开发提供了安全边界：防止意外或不当操作修改敏感源码、泄露环境变量中的密钥、执行危险命令。同时保留 AI 助手的开发能力——可读写项目其他文件、运行构建和测试。这种"最小权限"原则让团队更放心地将 Claude Code 集成到工作流中。

## 容器运行时支持

本示例支持 **Docker** 和 **Podman** 两种容器运行时。

### Docker

Docker 是最常用的容器运行时，VS Code Dev Containers 默认使用 Docker。

**要求：**
- Docker Engine 20.10+
- VS Code 已安装 Dev Containers 扩展

**配置步骤：**

1. **确保 Docker 正在运行**

   ```bash
   docker --version
   docker info
   ```

2. **验证权限**

   确保 当前用户在 `docker` 组中（Linux），或使用管理员权限（Windows/macOS）：

   ```bash
   # Linux: 添加用户到 docker 组
   sudo usermod -aG docker $USER
   ```

**无需额外配置**：VS Code 默认使用 Docker，`devcontainer.json` 中的配置对 Docker 完全兼容。

### Podman

Podman 是 Docker 的开源替代品，无需守护进程，支持 rootless 模式。

**要求：**
- Podman 4.0+
- VS Code 已安装 Dev Containers 扩展

**配置步骤：**

1. **配置 VS Code 使用 Podman**

   打开 VS Code 设置 (Ctrl+,)，搜索 `dev.containers.dockerPath`，设置为 `podman`：

   ```json
   // settings.json
   {
     "dev.containers.dockerPath": "podman"
   }
   ```

   或者在工作区 `.vscode/settings.json` 中添加此配置，团队成员共享。

2. **验证 Podman 安装**

   ```bash
   podman --version
   podman info
   ```

3. **Rootless 模式配置（如适用）**

   如果使用 rootless Podman，确保用户有足够权限：

   ```bash
   # 检查是否启用了 cgroup v2
   cat /proc/version

   # 启用用户 lingering（systemd 会话持久化）
   loginctl enable-linger $USER
   ```

4. **SELinux 配置（仅 Fedora/RHEL/CentOS）**

   `devcontainer.json` 已包含 `--security-opt=label=disable`，无需额外配置。如遇权限问题，可手动测试：

   ```bash
   podman run --rm --security-opt=label=disable alpine echo "SELinux OK"
   ```

5. **验证 SYS_ADMIN 能力**

   Bubblewrap 沙箱需要此能力：

   ```bash
   podman run --rm --cap-add=SYS_ADMIN alpine echo "CAP_SYS_ADMIN OK"
   ```

**常见问题：**

| 问题 | 解决方案 |
|------|----------|
| `bwrap: permission denied` | 确保容器有 `SYS_ADMIN` 能力 |
| SELinux 阻止访问 | 确认 `--security-opt=label=disable` 已配置 |
| rootless 无法启动 | 检查 `loginctl enable-linger` 是否已启用 |
| VS Code 找不到容器运行时 | 检查 `dev.containers.dockerPath` 设置 |

**Podman vs Docker 兼容性：**

| 功能 | Docker | Podman |
|------|--------|--------|
| `--cap-add=SYS_ADMIN` | ✅ | ✅ |
| `--security-opt=label=disable` | ✅ (忽略) | ✅ (SELinux) |
| Rootless 模式 | 需配置 rootless-kit | 原生支持 |
| 守护进程 | 需要 dockerd | 无需守护进程 |
| Socket 路径 | `/var/run/docker.sock` | `XDG_RUNTIME_DIR/podman/podman.sock` |

## 项目结构

```
core/
├── src/        # 源码（沙箱隔离）
└── include/    # 头文件（可读）
demo/           # 可执行程序
.claude/
└── settings.json    # Claude Code 沙箱配置（权限与隔离规则）
.devcontainer/
├── devcontainer.json    # 容器配置
├── setup.sh             # 容器创建时初始化（环境测试 + 沙箱包装器 + 插件安装）
└── claude-wrapper.sh    # Claude CLI 沙箱包装器（自动安装）
```

## 快速开始

1. **配置认证**（在仓库根目录创建 `.env`）：

```bash
ANTHROPIC_AUTH_TOKEN=your-key      # 或 ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL=your-api-base-url
ANTHROPIC_MODEL=your-model-name
```

2. **在 VS Code 中打开容器**：执行 "Dev Containers: Reopen in Container"

3. **使用 Claude Code**：容器启动后自动配置沙箱，直接使用 Claude Code for VS Code 扩展即可

## 沙箱架构

```
┌─────────────────────────────────────────┐
│  VS Code + Claude Code 扩展             │
│         ↓                               │
│  /usr/local/bin/claude (wrapper)        │
│         ↓                               │
│  bubblewrap 沙箱                         │
│  ├── 隔离 core/src (tmpfs 空目录)        │
│  └── 屏蔽 .env (绑定 /dev/null)          │
│         ↓                               │
│  claude-real (真实 CLI)                 │
└─────────────────────────────────────────┘
```

## 隔离策略

| 路径 | 访问 |
|------|------|
| `core/src/**` | ❌ 不可见（tmpfs 空目录） |
| `core/include/**` | ✅ 可读 |
| `.env` | ❌ 不可读（绑定到 /dev/null） |
| 其他文件 | ✅ 正常访问 |

容器需要 `--cap-add=SYS_ADMIN` 以支持 bubblewrap 命名空间隔离。

## 构建 Demo

```bash
cmake -S . -B build && cmake --build build
./build/demo/demo
```