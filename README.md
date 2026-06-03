# Windows 环境下 Claude Code CLI 沙箱示例

在 Podman 容器中运行 Claude Code CLI 的沙箱隔离示例，支持 Claude Code for VS Code 扩展集成。

## 为什么需要沙箱

沙箱为 AI 辅助开发提供了安全边界：防止意外或不当操作修改敏感源码、泄露环境变量中的密钥、执行危险命令。同时保留 AI 助手的开发能力——可读写项目其他文件、运行构建和测试。这种"最小权限"原则让团队更放心地将 Claude Code 集成到工作流中。

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