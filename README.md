# Windows 环境下 Claude Code CLI 沙箱示例

在 Docker/Podman 容器中运行 Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

## 为什么需要沙箱

沙箱为 AI 辅助开发提供了安全边界：防止意外或不当操作修改敏感源码、泄露环境变量中的密钥、执行危险命令。同时保留 AI 助手的开发能力——可读写项目其他文件、运行构建和测试。这种"最小权限"原则让团队更放心地将 Claude Code 集成到工作流中。

## 为什么 Windows 需要容器来实现沙箱

本示例使用 **bubblewrap** (`bwrap`) 构建沙箱，它依赖 Linux 内核的 namespace 特性实现文件系统隔离。Windows 内核没有 namespace，无法直接运行 bubblewrap。

**解决方案**：通过 WSL2 + Docker/Podman 容器获得 Linux 环境，在容器内使用 bubblewrap：

```
Windows → WSL2 (Linux 内核) → 容器 → bubblewrap 沙箱 → Claude Code
```

**容器化的好处**：

- **双重隔离**：容器提供项目级边界，bubblewrap 提供文件级控制
- **工具链统一**：项目自定义基础镜像，团队成员环境一致，CI/CD 对齐

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
├── src/        # 源码（沙箱隔离：不可读写）
└── include/    # 头文件（可读写）
demo/           # 可执行程序
.claude/
└── settings.json    # Claude Code 沙箱配置（权限与隔离规则）
.devcontainer/
├── devcontainer.json    # 容器配置
├── setup.sh             # 容器创建时初始化（环境测试 + 沙箱包装器 + 插件安装）
└── claude-wrapper.sh    # Claude CLI 沙箱包装器（自动安装）
images/
└── Dockerfile           # 容器镜像构建配置
```

## 快速开始

1. **配置认证**（在仓库根目录创建 `.env`）：

   ```bash
   ANTHROPIC_AUTH_TOKEN=your-key      # 或 ANTHROPIC_API_KEY
   ANTHROPIC_BASE_URL=your-api-base-url  # 可选，用于代理/网关
   ANTHROPIC_MODEL=your-model-name    # 可选，强制指定模型
   ```

2. **在 VS Code 中打开容器**：执行 "Dev Containers: Reopen in Container"

3. **使用 Claude Code**：容器启动后自动配置沙箱，直接使用 Claude Code for VS Code 扩展即可

## 沙箱架构

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

**安全边界说明：**

| 层级 | 隔离机制 | 作用 |
|------|----------|------|
| 宿主机 ↔ 容器 | Docker/Podman 容器隔离 | 限制对宿主机资源的访问 |
| 容器 ↔ 沙箱 | bubblewrap namespace | 在容器内进一步限制文件系统访问 |

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

## 构建 Demo

```bash
cmake -S . -B build && cmake --build build
./build/demo/demo
```

## 错误排查

### 常见问题与解决方案

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

在容器内运行以下命令诊断问题：

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
# 恢复原始 claude 二进制
sudo mv /usr/local/bin/claude-real /usr/local/bin/claude

# 重新运行 setup
bash .devcontainer/setup.sh
```

## 安全建议

1. **定期更新 CLI 版本**：修改 `images/Dockerfile` 中的版本号
2. **审计 settings.json**：根据项目需求调整隔离策略
3. **保护 .env 文件**：确保 `.gitignore` 包含 `.env`
4. **使用非 root 用户**：容器以 `devuser` 运行，减少风险

### 关于 SYS_ADMIN 能力

容器配置中的 `--cap-add=SYS_ADMIN` 是 **bubblewrap 沙箱必需的**，不是 Podman 必需的。

```
Windows → WSL2 → 容器 → bubblewrap 沙箱 → Claude Code
                         ↑
                    需要 SYS_ADMIN 创建 namespace
```

bubblewrap 使用 Linux namespace 特性（`clone()`, `unshare()`, `mount()` 系统调用），这些都需要 `CAP_SYS_ADMIN` 能力。**没有它，沙箱将降级到仅容器隔离**。

### 关于 SELinux 配置

`--security-opt=label=disable` 的作用：

| 容器运行时 | 行为 |
|------------|------|
| Docker | 忽略此选项（Docker 不使用 SELinux） |
| Podman (Fedora/RHEL) | 禁用 SELinux 标签，避免权限冲突 |

这是 Docker/Podman 兼容性的最优解。更精细的 SELinux 策略需要根据宿主机发行版定制，会增加维护复杂度。

## 版本信息

| 组件 | 版本 | 说明 |
|------|------|------|
| Claude Code CLI | 2.1.161 | 锁定版本，确保一致性 |
| Ubuntu | 24.04 | LTS 版本 |
| Node.js | 22.x | LTS 版本 |
| bubblewrap | 系统 package | Ubuntu 24.04 版本 |