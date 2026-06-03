# Claude Code 沙箱配置指南

沙箱（Sandbox）是一种安全机制，用于隔离 bash 命令的执行环境，保护您的文件系统和网络免受潜在的安全威胁。

## 概述

启用沙箱后，bash 命令将在受限环境中运行，限制其对文件系统和网络的访问权限。这为命令执行提供了一个额外的安全层。

**支持平台**：macOS、Linux 和 WSL2

## 核心配置选项

| 配置项 | 描述 | 示例值 |
|:--|:--|:--|
| `enabled` | 启用 bash 沙箱（macOS、Linux 和 WSL2）。默认值：`false` | `true` |
| `failIfUnavailable` | 如果沙箱已启用但无法启动（缺少依赖或不支持的平台），启动时退出并报错。当设置为 `false`（默认值）时，会显示警告并继续在非沙箱环境中运行命令。此选项适用于需要强制沙箱的托管设置 | `true` |
| `autoAllowBashIfSandboxed` | 当启用沙箱时，自动批准 bash 命令。默认值：`true` | `true` |
| `excludedCommands` | 应在沙箱外运行的命令列表 | `["docker *"]` |
| `allowUnsandboxedCommands` | 是否允许通过 `dangerouslyDisableSandbox` 参数在沙箱外运行命令。当设置为 `false` 时，逃生通道完全禁用，所有命令必须在沙箱中运行（或在 `excludedCommands` 中）。适用于需要严格沙箱的企业策略。默认值：`true` | `false` |

## 文件系统限制

| 配置项 | 描述 | 示例值 |
|:--|:--|:--|
| `filesystem.allowWrite` | 沙箱命令可写入的额外路径。数组会跨所有设置范围（用户、项目、托管）**合并**。也会与 `Edit(...)` 允许权限规则中的路径合并 | `["/tmp/build", "~/.kube"]` |
| `filesystem.denyWrite` | 沙箱命令不可写入的路径。数组会跨所有设置范围合并。也会与 `Edit(...)` 拒绝权限规则中的路径合并 | `["/etc", "/usr/local/bin"]` |
| `filesystem.denyRead` | 沙箱命令不可读取的路径。数组会跨所有设置范围合并。也会与 `Read(...)` 拒绝权限规则中的路径合并 | `["~/.aws/credentials"]` |
| `filesystem.allowRead` | 在 `denyRead` 区域内重新允许读取的路径。优先级高于 `denyRead`。数组会跨所有设置范围合并。用于创建仅工作区读取访问模式 | `["."]` |
| `filesystem.allowManagedReadPathsOnly` | （仅托管设置）仅尊重托管设置中的 `filesystem.allowRead` 路径。`denyRead` 仍从所有来源合并。默认值：`false` | `true` |

## 网络限制

| 配置项 | 描述 | 示例值 |
|:--|:--|:--|
| `network.allowUnixSockets` | （仅 macOS）沙箱中可访问的 Unix socket 路径。在 Linux/WSL2 上忽略，因为 seccomp 过滤器无法检查 socket 路径 | `["~/.ssh/agent-socket"]` |
| `network.allowAllUnixSockets` | 允许所有 Unix socket 连接。在 Linux/WSL2 上，这是允许 Unix socket 的唯一方式，因为它会跳过阻止 `socket(AF_UNIX, ...)` 调用的 seccomp 过滤器。默认值：`false` | `true` |
| `network.allowLocalBinding` | 允许绑定到本地端口（仅 macOS）。默认值：`false` | `true` |
| `network.allowMachLookup` | （仅 macOS）沙箱可以查找的额外 XPC/Mach 服务名称。支持单个尾部 `*` 进行前缀匹配。iOS 模拟器或 Playwright 等工具需要此选项 | `["com.apple.coresimulator.*"]` |
| `network.allowedDomains` | 允许出站网络流量的域名数组。支持通配符（例如 `*.example.com`） | `["api.example.com", "*.internal.com"]` |

## 配置示例

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker *", "kubectl *"],
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "allowWrite": ["/tmp/build", "~/.kube"],
      "denyWrite": ["/etc", "/usr/local/bin"],
      "denyRead": ["~/.aws/credentials", "~/.ssh"],
      "allowRead": ["."],
      "allowManagedReadPathsOnly": false
    },
    "network": {
      "allowUnixSockets": ["~/.ssh/agent-socket"],
      "allowAllUnixSockets": false,
      "allowLocalBinding": true,
      "allowMachLookup": ["com.apple.coresimulator.*"],
      "allowedDomains": ["api.example.com", "*.internal.com"]
    }
  }
}
```

## 配置文件位置

沙箱配置可以设置在不同的配置文件中，按优先级排序：

| 位置 | 文件路径 | 说明 |
|:--|:--|:--|
| 托管设置 | `/etc/claude-code/managed-settings.json` 或 `/etc/claude-code/managed-settings.d/` | 最高优先级，由系统管理员管理 |
| 用户设置 | `~/.claude/settings.json` | 用户级别的全局设置 |
| 项目设置 | `<project>/.claude/settings.json` 或 `<project>/.claude/settings.local.json` | 项目特定设置 |

## 重要说明

### 1. 平台支持

沙箱功能在以下平台上可用：
- macOS
- Linux
- WSL2（Windows Subsystem for Linux 2）

### 2. 数组合并行为

文件系统路径相关的数组配置（如 `allowWrite`、`denyWrite`、`denyRead`、`allowRead`）会跨所有设置范围（用户、项目、托管）进行**合并**，而不是替换。这意味着：

- 用户设置的路径会与项目设置的路径合并
- 托管设置的路径会与用户和项目设置的路径合并
- 最终结果是所有设置中路径的并集

### 3. 托管设置专属选项

某些选项（如 `allowManagedReadPathsOnly`）仅在托管设置中有效。这些选项通常用于企业环境中实施更严格的安全策略。

### 4. 与权限规则的集成

文件系统设置与 Claude Code 的权限规则集成：
- `filesystem.allowWrite` 和 `filesystem.denyWrite` 与 `Edit(...)` 权限规则合并
- `filesystem.denyRead` 和 `filesystem.allowRead` 与 `Read(...)` 权限规则合并

### 5. 严格模式

要防止通过 `dangerouslyDisableSandbox` 参数绕过沙箱，可以设置：
```json
{
  "sandbox": {
    "allowUnsandboxedCommands": false
  }
}
```

这将完全禁用逃生通道，确保所有命令都在沙箱中运行（除非在 `excludedCommands` 中明确排除）。

## 最佳实践

### 企业安全策略

对于需要严格安全控制的企业环境，推荐以下配置：

```json
{
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "denyRead": ["~/.aws/credentials", "~/.ssh", "~/.config"],
      "allowRead": ["."],
      "allowManagedReadPathsOnly": true
    },
    "network": {
      "allowedDomains": ["api.company.com", "*.company.internal"]
    }
  }
}
```

### 开发环境

对于开发环境，可以选择更宽松的配置：

```json
{
  "sandbox": {
    "enabled": true,
    "autoAllowBashIfSandboxed": true,
    "excludedCommands": ["docker *", "kubectl *"],
    "filesystem": {
      "allowWrite": ["/tmp"]
    }
  }
}
```

### 保护敏感信息

使用 `denyRead` 保护敏感凭据文件：

```json
{
  "sandbox": {
    "enabled": true,
    "filesystem": {
      "denyRead": [
        "~/.aws/credentials",
        "~/.ssh/id_rsa",
        "~/.config/gcloud",
        "~/.kube/config"
      ]
    }
  }
}
```

## 故障排除

### 沙箱无法启动

如果沙箱启用但无法启动，检查以下情况：
1. 确认运行在支持的平台上（macOS、Linux 或 WSL2）
2. 检查是否有必要的系统依赖
3. 根据需求调整 `failIfUnavailable` 设置

### 命令执行失败

如果命令在沙箱中执行失败：
1. 检查命令是否需要访问被限制的文件路径
2. 考虑将必要的路径添加到 `allowWrite` 或 `allowRead`
3. 对于特定工具（如 Docker、kubectl），考虑添加到 `excludedCommands`

### 网络连接问题

如果遇到网络连接问题：
1. 检查 `allowedDomains` 是否包含所需域名
2. 对于 Unix socket 连接问题，检查 `allowUnixSockets` 设置
3. 在 Linux/WSL2 上，可能需要启用 `allowAllUnixSockets`

## 参考资源

- [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code/settings)
- [Claude Code 设置详解](https://code.claude.com/docs/en/settings)