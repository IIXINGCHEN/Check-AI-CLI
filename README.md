# Check-AI-CLI

跨平台检查并更新常用 AI 编程 CLI（**仅 npm 全局安装**）：

| 工具 | npm 包 |
|---|---|
| Claude Code | `@anthropic-ai/claude-code@latest` |
| OpenAI Codex | `@openai/codex@latest` |
| Gemini CLI | `@google/gemini-cli@latest` |
| Grok Build | `@xai-official/grok@latest` |
| OpenCode | `opencode-ai@latest` |

项目负责版本发现（npm registry）、PATH 偏好修复、安装/更新与结果复核。  
**不支持** Factory CLI、远程官方安装脚本、`claude update`、scoop/choco/brew、OpenCode self-upgrade 等非 npm 通道。

不收集用户数据。

## 快速开始

### Windows：远程安装

默认安装到 `%LOCALAPPDATA%\Programs\Tools\Check-AI-CLI`，并写入当前用户 PATH。

```powershell
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

固定到不可变 commit：

```powershell
$env:CHECK_AI_CLI_REF = '63ba8d5467b6fa2a2be42450d16adc8ae1769e5e'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

安装完成后重新打开 PowerShell：

```powershell
check-ai-cli
```

### Windows：本地 ZIP 或源码

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

全机安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Machine
```

### macOS / Linux：远程安装

```bash
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

### 卸载

卸载器只删除带有有效 `.check-ai-cli-installed` 标记的目录，并要求输入 `DELETE`。

```powershell
.\uninstall.ps1
```

```bash
./uninstall.sh
```

## 检查与更新

```powershell
.\Check-AI-CLI-Versions.ps1
```

```bash
bash ./check-ai-cli-versions.sh
```

菜单：单个工具、全部检查、全部检查并更新（`U`）、退出。

自动模式：

```powershell
.\Check-AI-CLI-Versions.ps1 -Auto
```

```bash
CHECK_AI_CLI_AUTO=1 ./check-ai-cli-versions.sh --yes
```

更新语义等价于：

```bash
npm i -g @anthropic-ai/claude-code@latest
npm i -g @openai/codex@latest
npm i -g @google/gemini-cli@latest
npm i -g @xai-official/grok@latest
npm i -g opencode-ai@latest
```

前置依赖：**Node.js / npm**。无 npm 时更新会失败并提示安装 Node。

更新后会重新读取本地版本；无法验证新版本时返回失败状态。

## 支持工具与版本来源

| 工具 | 版本发现 | 更新方式 |
|---|---|---|
| Claude Code | npm `latest` | 仅 `npm i -g @anthropic-ai/claude-code@latest` |
| OpenAI Codex | npm `latest` | 仅 npm；镜像缺 optional 二进制时回退官方 registry |
| Gemini CLI | npm `latest` | 仅 npm |
| Grok Build | npm `latest` | 仅 npm；不可运行时回退官方 registry |
| OpenCode | npm `latest` | 仅 npm |

发现与安装使用同一套 registry 策略：区域镜像优先，失败再试 `https://registry.npmjs.org`。

## 安全模型

- **AI CLI 更新路径不执行远程脚本**（无 `irm \| iex` / `curl \| bash` 更新第三方 CLI）。
- 本工具自身的远程安装仍走 immutable Release tag / 40 位 commit SHA + `checksums.sha256`。
- 可设置 `CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256` 锚定清单。
- 安装器拒绝路径穿越、绝对路径、重复清单项、非法 SHA256 和空清单。
- 第三方 raw 镜像默认拒绝；`CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1` 才允许并警告。

## 配置

| 变量 | 作用 | 示例 |
|---|---|---|
| `CHECK_AI_CLI_AUTO` | 自动安装/更新，不询问确认 | `1` |
| `CHECK_AI_CLI_REGION` | 覆盖网络区域判断 | `China` / `Global` |
| `CHECK_AI_CLI_RETRY` | 下载重试次数，范围 1-10 | `3` |
| `CHECK_AI_CLI_REF` | 安装本工具时 pin tag/commit/`main` | `v1.3.0` |
| `CHECK_AI_CLI_RAW_BASE` | 自定义原始文件源 | `https://mirror.example/repo` |
| `CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR` | 允许非官方 raw 源（仅本工具安装） | `1` |
| `CHECK_AI_CLI_INSTALL_DIR` | 安装目录 | `E:\Tools\Check-AI-CLI` |
| `CHECK_AI_CLI_PATH_SCOPE` | PATH 范围 | `CurrentUser` / `Machine` |
| `CHECK_AI_CLI_RUN` | 安装完成后启动 checker | `1` |

已移除（不再影响 AI CLI 更新）：`CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT`、`CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS`、`CHECK_AI_CLI_OPENCODE_VERSION` 等非 npm 通道开关。

## 依赖

### Windows

- Windows 10/11
- PowerShell 5.1+ 或 PowerShell 7+
- **Node.js / npm**（更新 AI CLI 必需）
- 安装本工具时：`Invoke-WebRequest`、`Get-FileHash` 或 `certutil`

### macOS / Linux

- Bash 3.2+
- curl 或 wget
- **Node.js / npm**
- sha256sum 或 shasum（安装本工具时）

## 项目结构

| 路径 | 作用 |
|---|---|
| `scripts/` | Windows 与 POSIX 主逻辑（npm-only） |
| `bin/` | PATH 入口 |
| `install.ps1` / `install.sh` | 安装 **Check-AI-CLI 自身** |
| `uninstall.ps1` / `uninstall.sh` | 安全卸载器 |
| `distribution-files.txt` | 分发载荷清单 |
| `checksums.sha256` | 清单载荷 SHA256 |
| `tools/` | checksum、发布工具 |
| `tests/` | 契约与回归测试 |

## 开发与验证

```powershell
.\run-all-tests.ps1
```

```bash
bash ./run-all-tests.sh
```

```bash
bash -n install.sh uninstall.sh scripts/check-ai-cli-versions.sh
```

```powershell
.\tools\Update-Checksums.ps1 -Check
```

修改分发载荷后：

```powershell
git add distribution-files.txt install.ps1 install.sh uninstall.ps1 uninstall.sh bin scripts tools/PSModulePath.ps1 Check-FactoryCLI-Version.ps1
.\tools\Update-Checksums.ps1
git add checksums.sha256
```

## 发布

推送 `main` 上的 `vX.Y.Z` tag 触发 Release 工作流（校验 tag、checksum、资产）。

## 常见问题

### 更新失败：npm not found

安装 Node.js，确保 `npm` 在 PATH 中。

### 装完版本仍偏旧

```powershell
npm prefix -g
where.exe claude codex gemini grok opencode
```

把 npm global bin 放到 PATH 最前，重开终端。

### 镜像装了不能跑（Codex / Grok）

```powershell
npm i -g @openai/codex@latest --registry https://registry.npmjs.org
npm i -g @xai-official/grok@latest --registry https://registry.npmjs.org
```

### Factory CLI？

已移除。请使用 Factory 官方安装方式；本工具不再编排 Droid/Factory。
