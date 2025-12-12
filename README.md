# AI CLI 工具版本检查器

一键检查和更新四大 AI 编程助手的完整解决方案！

## 🎯 支持的工具

| 工具 | 描述 | 官网 |
|------|------|------|
| **Factory CLI (Droid)** | Factory.ai 的 AI 开发代理 | https://factory.ai |
| **Claude Code** | Anthropic 的终端 AI 编程工具 | https://code.claude.com |
| **OpenAI Codex** | OpenAI 的轻量级编程代理 | https://developers.openai.com/codex |
| **Gemini CLI** | Google 的 Gemini CLI 工具 | https://github.com/google-gemini/gemini-cli |

## 📦 脚本文件

- `Check-AI-CLI-Versions.ps1` - Windows PowerShell 版本
- `check-ai-cli-versions.sh` - macOS/Linux Bash 版本
- `Check-FactoryCLI-Version.ps1` - Windows 版本（仅 Factory CLI）

## 🚀 快速使用

### Windows
```powershell
# 方法 1: 直接运行
.\Check-AI-CLI-Versions.ps1

# 方法 2: 绕过执行策略
powershell -ExecutionPolicy Bypass -File ".\Check-AI-CLI-Versions.ps1"

# 方法 3: 从任意位置运行
powershell -ExecutionPolicy Bypass -File "G:\wwwroot\CRS\code\USA\droid2api-v3\shell\Check-AI-CLI-Versions.ps1"

# 自动模式: 未安装自动安装, 非最新自动更新
$env:CHECK_AI_CLI_AUTO = '1'
.\Check-AI-CLI-Versions.ps1 -Auto
```

### Windows (无需 clone, 一行命令安装到当前目录)
```powershell
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex

# 备用写法 (同样是 raw 内容)
irm https://github.com/IIXINGCHEN/Check-AI-CLI/raw/main/install.ps1 | iex
```

### Windows (安装到固定目录并加入 PATH)
```powershell
# 目标目录: C:\Program Files\Tools\Check-AI-CLI
# 需要管理员权限: 请用管理员 PowerShell 运行
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex

# 安装完成后, 直接执行
check-ai-cli
```

### 安全与稳定(推荐设置)

#### 推荐: 使用代理加速, 不改下载源
```powershell
$ProgressPreference = 'SilentlyContinue'
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

#### 推荐: 固定版本(避免 main 变动)
```powershell
# 你可以固定到 tag 或 commit SHA
$env:CHECK_AI_CLI_REF = 'main'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

#### 不推荐: 使用第三方镜像(必须显式允许)
```powershell
$env:CHECK_AI_CLI_RAW_BASE = 'YOUR_MIRROR_RAW_BASE'
$env:CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR = '1'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

### macOS / Linux
```bash
# 方法 1: 添加执行权限后运行
chmod +x check-ai-cli-versions.sh
./check-ai-cli-versions.sh

# 自动模式: 未安装自动安装, 非最新自动更新
CHECK_AI_CLI_AUTO=1 ./check-ai-cli-versions.sh --yes

# 方法 2: 使用 bash 直接运行
bash check-ai-cli-versions.sh

# 方法 3: 从任意位置运行
bash /path/to/check-ai-cli-versions.sh
```

### macOS / Linux (无需 clone, 一行命令安装到当前目录)
```bash
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash

# 备用写法 (同样是 raw 内容)
curl -fsSL https://github.com/IIXINGCHEN/Check-AI-CLI/raw/main/install.sh | bash
```

### 中国大陆网络较慢时, 推荐使用代理环境变量

#### PowerShell
```powershell
$ProgressPreference = 'SilentlyContinue'
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

#### Bash
```bash
export HTTP_PROXY="http://127.0.0.1:7890"
export HTTPS_PROXY="http://127.0.0.1:7890"
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

## 📖 功能特性

### ✅ 自动版本检测
- 从官方源获取最新稳定版本
- 自动检测本地已安装版本
- 智能版本比较算法

### 🔄 多数据源支持
- **Factory CLI**: 官方安装脚本
- **Claude Code**: Google Cloud Storage + npm 备用
- **OpenAI Codex**: GitHub Releases API + npm 备用
- **Gemini CLI**: npm registry

### 🎨 交互式界面
- 彩色输出，清晰易读
- 交互式菜单选择
- 实时进度显示

### 🛠️ 一键安装/更新
- 自动选择最佳安装方式
- macOS 优先使用 Homebrew
- 提供多种备用安装方案

## 📊 使用示例

### 场景 1: 检查所有工具
```
$ ./check-ai-cli-versions.sh

╔════════════════════════════════════════════════╗
║     AI CLI 工具版本检查器                      ║
║   Factory CLI | Claude Code | OpenAI Codex    ║
╚════════════════════════════════════════════════╝

请选择要检查的工具:
  [1] Factory CLI (Droid)
  [2] Claude Code
  [3] OpenAI Codex
  [A] 全部检查 (默认)

请输入选项 (1/2/3/A): A

1. Factory CLI (Droid)
======================
[INFO] 正在获取 Factory CLI (Droid) 最新版本...
[SUCCESS] 官方最新版本: v0.36.0
[SUCCESS] 本地版本: v0.35.0

[WARNING] 发现新版本！
  当前: v0.35.0 → 最新: v0.36.0

是否更新? (Y/N): Y
[INFO] 正在更新 Factory CLI (Droid)...
[SUCCESS] 完成！
```

### 场景 2: 仅检查单个工具
```
请输入选项 (1/2/3/A): 2

Claude Code
===========
[INFO] 正在获取 Claude Code 最新版本...
[SUCCESS] 官方最新版本: v2.0.67
[SUCCESS] 本地版本: v2.0.67
[SUCCESS] ✓ 已是最新版本 v2.0.67
```

## 🔧 系统要求

### Windows
- Windows 10/11 (64-bit)
- PowerShell 5.1 或更高版本
- 网络连接

### macOS
- macOS 10.15 (Catalina) 或更高版本
- Bash 3.2 或更高版本
- 可选: Homebrew（推荐）

### Linux
- 任何现代 Linux 发行版
- Bash 4.0 或更高版本
- curl 或 wget

## 📚 各工具安装方式

### Factory CLI (Droid)

#### Windows
```powershell
irm https://app.factory.ai/cli/windows | iex
```

#### macOS / Linux
```bash
# Recommended
curl -fsSL https://app.factory.ai/cli | sh

# Fallback
curl -fsSL https://app.factory.ai/cli/install.sh | bash
```

### Claude Code

#### Windows
```powershell
irm https://claude.ai/install.ps1 | iex
```

#### macOS
```bash
# 方法 1: Homebrew (推荐)
brew install --cask claude-code

# 方法 2: 官方脚本
curl -fsSL https://claude.ai/install.sh | bash

# 方法 3: npm
npm install -g @anthropic-ai/claude-code
```

#### Linux
```bash
# 方法 1: 官方脚本
curl -fsSL https://claude.ai/install.sh | bash

# 方法 2: npm
npm install -g @anthropic-ai/claude-code
```

### OpenAI Codex

#### Windows
```powershell
npm install -g @openai/codex
```

#### macOS
```bash
# 方法 1: Homebrew (推荐)
brew install --cask codex

# 方法 2: npm
npm install -g @openai/codex
```

#### Linux
```bash
npm install -g @openai/codex
```

### Gemini CLI

#### Windows
```powershell
npm install -g @google/gemini-cli
```

#### macOS
```bash
# 方法 1: Homebrew (推荐)
brew install gemini-cli

# 方法 2: npm
npm install -g @google/gemini-cli
```

#### Linux
```bash
npm install -g @google/gemini-cli
```

## 🛠️ 故障排除

### 问题：PowerShell 执行策略错误

**错误信息**:
```
无法加载文件，因为在此系统上禁止运行脚本
```

**解决方案**:
```powershell
# 临时允许（仅当前会话）
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# 永久允许（当前用户）
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 问题：Bash 权限被拒绝

**错误信息**:
```
Permission denied
```

**解决方案**:
```bash
# 添加执行权限
chmod +x check-ai-cli-versions.sh

# 或使用 bash 显式运行
bash check-ai-cli-versions.sh
```

## Self Check (Offline)

### PowerShell
```powershell
powershell -NoProfile -Command "[ScriptBlock]::Create((Get-Content -Raw .\\Check-AI-CLI-Versions.ps1)) | Out-Null; 'OK'"
```

### Bash
```bash
bash -n ./check-ai-cli-versions.sh
```

### 问题：无法连接到服务器

**解决方案**:
1. 检查网络连接
2. 确认防火墙设置
3. 尝试使用 VPN
4. 检查 DNS 设置

### 问题：npm 命令不存在

**解决方案**:

**Windows**:
1. 访问 https://nodejs.org
2. 下载并安装 Node.js LTS 版本
3. 重启 PowerShell

**macOS**:
```bash
# 使用 Homebrew
brew install node
```

**Linux**:
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install nodejs npm

# CentOS/RHEL
sudo yum install nodejs npm

# Fedora
sudo dnf install nodejs npm

# Arch Linux
sudo pacman -S nodejs npm
```

## 🔐 安全说明

本脚本：
- ✅ 仅从官方源获取数据
- ✅ 使用 HTTPS 加密连接
- ✅ 验证下载文件的校验和（当官方提供时）
- ✅ 不收集或发送任何用户数据
- ✅ 开源透明，可审查代码

## 📋 版本数据源

| 工具 | 主要数据源 | 备用数据源 |
|------|----------|-----------|
| Factory CLI | app.factory.ai/cli/install.sh | app.factory.ai/cli/windows |
| Claude Code | GCS claude-code-releases/stable | registry.npmjs.org |
| OpenAI Codex | api.github.com/repos/openai/codex | registry.npmjs.org |
| Gemini CLI | registry.npmjs.org/@google/gemini-cli | github.com/google-gemini/gemini-cli |

## 🎯 高级用法

### 自动化定期检查 (Linux/macOS)

使用 cron 每天自动检查版本：

```bash
# 编辑 crontab
crontab -e

# 添加以下行（每天早上 9 点运行）
0 9 * * * ~/check-ai-cli-versions.sh >> ~/ai-cli-check.log 2>&1
```

### 自动化定期检查 (Windows)

使用任务计划程序：

```powershell
# 创建每日检查任务
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File G:\wwwroot\CRS\code\USA\droid2api-v3\shell\Check-AI-CLI-Versions.ps1"

$trigger = New-ScheduledTaskTrigger -Daily -At 9am

Register-ScheduledTask -Action $action -Trigger $trigger `
    -TaskName "AI CLI Version Check" -Description "每日检查 AI CLI 工具版本"
```

## 🔗 相关链接

- [Factory CLI 官方文档](https://docs.factory.ai)
- [Claude Code 官方文档](https://code.claude.com/docs)
- [OpenAI Codex 官方文档](https://developers.openai.com/codex)
- [Factory CLI GitHub](https://github.com/Factory-AI/factory)
- [Claude Code GitHub](https://github.com/anthropics/claude-code)
- [OpenAI Codex GitHub](https://github.com/openai/codex)

## 📞 支持

如果遇到问题：

1. 查看上方的故障排除部分
2. 检查官方文档
3. 在 GitHub 上提交 issue
4. 加入各工具的官方 Discord 社区

---

**提示**: 建议定期运行此脚本以保持工具最新，获得最佳性能和新功能！

## 📝 更新日志

### 2025-12-12
- ✅ 初始版本发布
- ✅ 支持 Factory CLI、Claude Code、OpenAI Codex
- ✅ 跨平台支持 (Windows/macOS/Linux)
- ✅ 多数据源备用方案
- ✅ 交互式安装界面
