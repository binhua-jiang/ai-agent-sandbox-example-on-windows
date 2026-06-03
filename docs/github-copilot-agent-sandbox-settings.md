# GitHub Copilot Agent 设置参考手册

本文档全面总结了 VSCode 中 GitHub Copilot Agent 的所有相关设置，内容来源于 VSCode 官方文档。

> **说明**：标记为 `ORG` 的设置为组织级别管理，标记为 `Preview` 为预览功能，标记为 `Experimental` 为实验性功能。

---

## 目录

- [沙箱设置](#沙箱设置)
- [网络设置](#网络设置)
- [终端工具设置](#终端工具设置)
- [全局工具权限设置](#全局工具权限设置)
- [Agent 核心设置](#agent-核心设置)
- [Claude Agent 集成](#claude-agent-集成)
- [MCP 设置](#mcp-设置)
- [Memory 设置](#memory-设置)
- [Agent 规划设置](#agent-规划设置)
- [Agent 会话设置](#agent-会话设置)
- [自定义 Agent 设置](#自定义-agent-设置)
- [Agent Skills 设置](#agent-skills-设置)
- [Agent Plugins 设置](#agent-plugins-设置)
- [调试与可观测性设置](#调试与可观测性设置)

---

## 沙箱设置

沙箱功能用于限制 Agent 执行命令时的文件系统和网络访问权限。启用后，终端命令可以在受控环境中自动执行，无需用户确认。

> **注意**：沙箱功能仅支持 macOS 和 Linux 系统。如果所需的 OS 依赖未安装，VS Code 会提示安装必要组件。

### 核心设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.agent.sandbox.enabled` | `"off"` | 启用沙箱 (Preview, ORG)。可选值：`off`(禁用)、`on`(完整隔离)、`allowNetwork`(仅文件系统隔离) |
| `chat.agent.sandbox.FileSystem.linux` | `{}` | Linux 文件系统访问规则 (Preview) |
| `chat.agent.sandbox.FileSystem.mac` | `{}` | macOS 文件系统访问规则 (Preview) |
| `chat.agent.sandbox.retryWithAllowNetworkRequests` | `false` | 当命令被阻止时，是否提示用户使用无限制网络访问重试 |
| `chat.agent.sandbox.allowUnsandboxedCommands` | - | 是否允许在沙箱外运行命令的确认 (ORG) |

### `chat.agent.sandbox.enabled` 可选值

| 值 | 说明 |
|---|---|
| `off` (默认) | 禁用沙箱 |
| `on` | 启用完整沙箱，包含文件系统和网络隔离。所有出站网络访问被阻止，除非域名被明确允许 |
| `allowNetwork` | 仅启用文件系统隔离，允许所有出站网络流量，无需配置域名 |

### 文件系统访问规则

配置路径：`chat.agent.sandbox.FileSystem.linux` 或 `chat.agent.sandbox.FileSystem.mac`

**启用沙箱时的默认规则：**
- **读取权限**：工作区文件夹、沙箱运行时临时文件夹、每命令路径（git、node、npm、dotnet）。默认拒绝读取主目录。
- **写入权限**：仅当前工作目录及其子目录。

**配置属性：**

| 属性 | 说明 |
|---|---|
| `allowRead` | 允许读取的路径列表 |
| `allowWrite` | 允许写入的路径列表 |
| `denyRead` | 禁止读取的路径列表（优先级高于 allow） |
| `denyWrite` | 禁止写入的路径列表 |

> **注意**：路径规则不支持 glob 模式。

**配置示例：**

```json
{
  "chat.agent.sandbox.FileSystem.linux": {
    "allowWrite": ["."],
    "allowRead": ["/home/user/.config/myapp"],
    "denyWrite": ["./.git/", "./.env", "./secrets/"],
    "denyRead": ["./.env", "./.git/", "./secrets/"]
  }
}
```

---

## 网络设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.agent.networkFilter` | `false` | 启用网络域名过滤 (ORG)，用于 fetch 工具和集成浏览器 |
| `chat.agent.allowedNetworkDomains` | `[]` | 允许访问的域名列表 (ORG)，支持通配符如 `*.example.com` |
| `chat.agent.deniedNetworkDomains` | `[]` | 禁止访问的域名列表 (ORG)，优先级高于允许列表，支持通配符 |
| `workbench.browser.enableChatTools` | `true` | 启用浏览器工具，让 Agent 与页面交互 (Experimental, ORG) |

**配置示例：**

```json
{
  "chat.agent.networkFilter": true,
  "chat.agent.allowedNetworkDomains": [
    "api.github.com",
    "*.github.com",
    "npmjs.com"
  ],
  "chat.agent.deniedNetworkDomains": [
    "internal.company.com"
  ]
}
```

**规则说明：**
- 拒绝域名优先级高于允许域名
- 支持通配符，例如 `*.example.com`

---

## 终端工具设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.tools.terminal.autoApprove` | 见下方详情 | 控制哪些终端命令自动批准 |
| `chat.tools.terminal.enableAutoApprove` | `true` | 启用/禁用终端命令自动批准 (ORG) |
| `chat.tools.terminal.autoReplyToPrompts` | `false` | 自动使用默认答案回复终端提示 |
| `chat.tools.terminal.outputLocation` | `"chat"` | 终端输出显示位置 (Experimental)，可选 `chat` 或 `terminal` |
| `chat.tools.terminal.enforceTimeoutFromModel` | `true` | 强制执行 Agent 指定的终端命令超时 (Experimental) |
| `chat.tools.terminal.ignoreDefaultAutoApproveRules` | `false` | 忽略默认的自动批准规则 |
| `chat.tools.terminal.blockDetectedFileWrites` | `"outsideWorkspace"` | 对检测到的工作区外文件写入要求批准 (Experimental)，写入 `/tmp`/`%TEMP%` 豁免 |

### `chat.tools.terminal.autoApprove` 默认值

```json
{
  "rm": false,
  "rmdir": false,
  "del": false,
  "kill": false,
  "curl": false,
  "wget": false,
  "eval": false,
  "chmod": false,
  "chown": false,
  "/^Remove-Item\\b/i": false
}
```

- 值可以是 `true` 或 `false`
- 支持使用 `/` 分隔符的正则表达式

### `chat.tools.terminal.blockDetectedFileWrites` 可选值

| 值 | 说明 |
|---|---|
| `"never"` | 不阻止任何文件写入 |
| `"outsideWorkspace"` | 阻止工作区外的文件写入 |
| `"all"` | 阻止所有检测到的文件写入 |

---

## 全局工具权限设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.tools.global.autoApprove` | `false` | 自动批准所有工具 (ORG)，禁用关键安全保护 |
| `chat.tools.edits.autoApprove` | `{}` | 配置哪些文件在编辑前需要批准，使用 glob 模式 |
| `chat.tools.urls.autoApprove` | `[]` | 控制哪些 URL 请求/响应自动批准 |
| `chat.tools.eligibleForAutoApproval` | `[]` | 配置哪些工具在使用前需要手动批准 (Experimental, ORG) |
| `chat.tools.riskAssessment.enabled` | `true` | 在终端命令确认时显示 AI 生成的风险徽章 (Experimental) |
| `chat.tools.compressOutput.enabled` | `false` | 发送到模型前压缩大型终端输出 (Preview) |

### 权限级别设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.autopilot.enabled` | `true` | 控制权限选择器中是否显示 Autopilot 权限级别 (Experimental) |
| `chat.permissions.default` | `"default"` | 新会话的默认权限级别 (Experimental) |

**`chat.permissions.default` 可选值：**

| 值 | 说明 |
|---|---|
| `"default"` | 默认批准模式 |
| `"autoApprove"` | 跳过批准流程 |
| `"autopilot"` | 自动驾驶模式 |

---

## Agent 核心设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.agent.enabled` | `true` | 启用或禁用 Agent 功能 (ORG，需要 VS Code 1.99+) |
| `chat.agent.maxRequests` | `25` | Agent 可执行的最大请求数 |
| `github.copilot.chat.agent.autoFix` | `true` | 自动诊断并修复生成的代码更改中的问题 |

---

## Claude Agent 集成

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `github.copilot.chat.claudeAgent.enabled` | `true` | 启用/禁用由 Anthropic SDK 驱动的 Claude Agent 会话 (ORG) |
| `github.copilot.chat.claudeAgent.allowDangerouslySkipPermissions` | `false` | 跳过 Claude Agent 的所有权限检查。仅在沙箱环境中启用 |

> **警告**：`allowDangerouslySkipPermissions` 会跳过所有权限检查，仅建议在隔离环境中使用。

---

## MCP 设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.mcp.access` | `true` | 管理哪些 MCP 服务器可在 VS Code 中使用 (ORG) |
| `chat.mcp.discovery.enabled` | `false` | 配置是否自动发现其他应用的 MCP 服务器配置 |
| `chat.mcp.serverSampling` | `{}` | 配置哪些模型暴露给 MCP 服务器进行采样 |
| `chat.mcp.apps.enabled` | `true` | 启用 MCP Apps - MCP 服务器提供的丰富 UI (Experimental) |
| `chat.mcp.autoStart` | `"newAndOutdated"` | 检测到配置变更时自动启动 MCP 服务器 (Experimental) |

---

## Memory 设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `github.copilot.chat.tools.memory.enabled` | `true` | 启用/禁用内置记忆工具，用于跨对话保存/回忆笔记 (Preview) |
| `github.copilot.chat.copilotMemory.enabled` | `false` | 启用 Copilot Memory - GitHub 托管的仓库特定洞察 (Preview) |

---

## Agent 规划设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.planWidget.inlineEditor.enabled` | `true` | 在规划控件中使用内联编辑器而非单独的编辑器标签页 |
| `chat.planAgent.defaultModel` | `"Auto (Vendor Default)"` | 选择规划 Agent 的默认语言模型 |
| `github.copilot.chat.implementAgent.model` | `""` | 选择规划后实现步骤的语言模型 (Experimental) |
| `github.copilot.chat.planAgent.additionalTools` | `[]` | 在研究/规划期间给规划 Agent 额外工具访问权限 (Experimental) |

---

## Agent 会话设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.viewSessions.enabled` | `true` | 在 Chat 视图中显示 Agent 会话列表 |
| `chat.viewSessions.orientation` | `"sideBySide"` | 会话列表的布局方向 |
| `chat.editMode.hidden` | `true` | 恢复已弃用的编辑模式用于多文件编辑 (ORG) |
| `chat.agentsControl.enabled` | `true` | 在命令中心启用会话状态指示器 (Experimental) |
| `chat.agentsControl.clickBehavior` | `"cycle"` (Insiders) / `"default"` (Stable) | 点击 Agent 状态指示器中的聊天图标时的行为 |
| `chat.unifiedAgentsBar.enabled` | `false` | 用统一的聊天/搜索控件替换命令中心搜索 (Experimental) |
| `github.copilot.chat.cli.remote.enabled` | `true` | 从 github.com 或 GitHub Mobile 启用 Copilot CLI 会话的远程控制 |

---

## 自定义 Agent 设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.agentFilesLocations` | `{ ".github/agents": true }` | 搜索自定义 Agent 文件的位置，支持 `~` 表示主目录 |
| `github.copilot.chat.cli.customAgents.enabled` | `false` | 启用来自 GitHub 后台 Agent 会话的自定义 Agent |
| `github.copilot.chat.organizationCustomAgents.enabled` | `true` | 启用在 GitHub 组织级别发现自定义 Agent |
| `github.copilot.chat.additionalReadAccessFolders` | `[]` | 为内置 Agent 工具授予工作区外文件夹的只读访问权限 |

---

## Agent Skills 设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.useAgentSkills` | `true` | 启用 VS Code 中的 Agent Skills 支持 |
| `chat.agentSkillsLocations` | 见下方详情 | 搜索 Agent Skills 的位置 |
| `github.copilot.chat.skillTool.enabled` | `false` | 启用专用的 Skill 工具来调用 Agent Skills (Experimental) |

### `chat.agentSkillsLocations` 默认值

```json
{
  ".github/skills": true,
  ".claude/skills": true,
  "~/.copilot/skills": true,
  "~/.claude/skills": true
}
```

---

## Agent Plugins 设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `chat.plugins.enabled` | `false` | 启用/禁用 Agent Plugins 支持 (Preview, ORG) |
| `chat.plugins.marketplaces` | `["github/copilot-plugins", "github/awesome-copilot"]` | 配置额外的 Plugin 市场 Git 仓库 (Experimental) |
| `chat.pluginLocations` | `{}` | 通过映射目录路径注册本地 Agent Plugins (Experimental) |

---

## 调试与可观测性设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `github.copilot.chat.agentDebugLog.enabled` | `false` | 启用 Agent 调试日志和 `/troubleshoot` 斜杠命令 |
| `github.copilot.chat.agentDebugLog.fileLogging.enabled` | `false` | 启用 Agent 调试日志的文件日志 |
| `github.copilot.chat.otel.enabled` | `false` | 启用 Copilot Chat Agent 交互的 OpenTelemetry 发射 |
| `github.copilot.chat.otel.exporterType` | `"otlp-http"` | OTel 导出器类型 |
| `github.copilot.chat.otel.otlpEndpoint` | `"http://localhost:4318"` | OTLP 收集器端点 URL |
| `github.copilot.chat.otel.outfile` | `""` | 使用 `file` 导出器时的 JSON-lines 输出文件路径 |
| `github.copilot.chat.otel.captureContent` | `false` | 在 OTel spans 中捕获完整的提示/响应内容（可能包含敏感信息） |

### `chat.github.copilot.chat.otel.exporterType` 可选值

| 值 | 说明 |
|---|---|
| `"otlp-http"` | OTLP over HTTP |
| `"otlp-grpc"` | OTLP over gRPC |
| `"console"` | 输出到控制台 |
| `"file"` | 输出到文件 |

---

## 其他设置

| 设置 | 默认值 | 说明 |
|------|--------|------|
| `github.copilot.chat.newWorkspaceCreation.enabled` | `true` | 启用在 Chat 中创建新工作区的工具 (Experimental) |
| `chat.agent.thinking.collapsedTools` | `"always"` | 工具调用详情默认折叠/展开 (Experimental) |
| `chat.agent.thinkingStyle` | `"fixedScrolling"` | 思考令牌在 Chat 中的呈现方式 (Experimental) |

---

## 最佳实践

### 生产环境配置

```json
{
  "chat.agent.sandbox.enabled": "on",
  "chat.agent.networkFilter": true,
  "chat.agent.sandbox.FileSystem.linux": {
    "allowWrite": ["."],
    "denyWrite": ["./.git/", "./.env", "./secrets/"],
    "denyRead": ["./.env", "./secrets/"]
  },
  "chat.agent.allowedNetworkDomains": ["api.github.com"]
}
```

### 开发环境配置

```json
{
  "chat.agent.sandbox.enabled": "allowNetwork",
  "chat.agent.sandbox.FileSystem.linux": {
    "allowWrite": ["."],
    "denyWrite": ["./.git/", "./.env"]
  }
}
```

### 敏感项目配置

```json
{
  "chat.agent.sandbox.enabled": "on",
  "chat.agent.networkFilter": true,
  "chat.agent.sandbox.FileSystem.linux": {
    "allowWrite": ["."],
    "denyWrite": ["./.git/", "./.env", "./secrets/", "./credentials/"],
    "denyRead": ["./.env", "./secrets/", "./credentials/"]
  },
  "chat.agent.allowedNetworkDomains": []
}
```

---

## 参考链接

- [VSCode Copilot Agent Tools — Sandbox](https://code.visualstudio.com/docs/copilot/agents/agent-tools)
- [VSCode Copilot Settings Reference](https://code.visualstudio.com/docs/copilot/reference/copilot-settings)