# AI CLI 工具版本检查器

一键检查和更新五大 AI 编程助手的完整解决方案！

## 🎯 支持的工具

| 工具 | 描述 | 官网 |
|------|------|------|
| **Factory CLI (Droid)** | Factory.ai 的 AI 开发代理 | https://factory.ai |
| **Claude Code** | Anthropic 的终端 AI 编程工具 | https://code.claude.com |
| **OpenAI Codex** | OpenAI 的轻量级编程代理 | https://developers.openai.com/codex |
| **Gemini CLI** | Google 的 Gemini CLI 工具 | https://github.com/google-gemini/gemini-cli |
| **OpenCode (opencode)** | OpenCode 的 AI 编程助手 CLI 工具 | https://opencode.ai |

## 📦 脚本文件

- `install.ps1` - Windows 一键安装器(支持 PATH)
- `install.sh` - macOS/Linux 一键安装器
- `uninstall.ps1` - Windows 卸载器(需要确认 DELETE)
- `uninstall.sh` - macOS/Linux 卸载器(需要确认 DELETE)
- `checksums.sha256` - 下载文件校验(安装时自动验证)
- `scripts/` - 版本检查脚本(主逻辑)
- `bin/` - 命令入口(用于 PATH)

## 目录结构

- `scripts/Check-AI-CLI-Versions.ps1` - Windows PowerShell 版本(主脚本)
- `scripts/check-ai-cli-versions.sh` - macOS/Linux Bash 版本
- `bin/check-ai-cli.cmd` - Windows PATH 命令入口
- `bin/check-ai-cli.ps1` - PowerShell PATH 命令入口

## 目录职责说明

- `scripts/` - 项目主逻辑, 优先修改这里的实现
- `bin/` - 安装到 PATH 后使用的真实命令入口
- 根目录同名脚本 - 兼容旧路径/旧调用方式的 legacy wrapper, 仅做转发
- `tools/` - 发布和维护辅助脚本
- `tests/` - 回归测试与自检脚本
- `.github/` - CI 与自动校验工作流
- 其他本地 AI/IDE 工具目录 - 不属于项目运行必需内容, 已建议忽略, 避免把本地工具状态混入仓库


## 兼容入口

- `Check-AI-CLI-Versions.ps1` - 兼容旧路径, 会转发到 `scripts/Check-AI-CLI-Versions.ps1`
- `Check-FactoryCLI-Version.ps1` - 兼容旧路径, 会转发到 `scripts/Check-AI-CLI-Versions.ps1 -FactoryOnly`
- `check-ai-cli-versions.sh` - 兼容旧路径, 会转发到 `scripts/check-ai-cli-versions.sh`


## 🚀 快速使用

### Windows
```powershell
# 方法 1: 直接运行
.\Check-AI-CLI-Versions.ps1

# 方法 2: 绕过执行策略
powershell -ExecutionPolicy Bypass -File ".\Check-AI-CLI-Versions.ps1"

# 方法 3: 从任意位置运行
powershell -ExecutionPolicy Bypass -File "G:\shell\Check-AI-CLI-Versions.ps1"

# 自动模式: 未安装自动安装, 非最新自动更新
$env:CHECK_AI_CLI_AUTO = '1'
.\Check-AI-CLI-Versions.ps1 -Auto

# 仅检查 Factory CLI
.\Check-FactoryCLI-Version.ps1

```

### Windows (无需 clone, 一行命令安装到默认目录并加入 PATH)
```powershell
# 推荐: stable bootstrap asset
# 管理员 PowerShell: 默认安装到 C:\Program Files\Tools\Check-AI-CLI, 写入 Machine PATH
# 非管理员 PowerShell: 默认安装到 %LOCALAPPDATA%\Programs\Tools\Check-AI-CLI, 写入 CurrentUser PATH
irm https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.ps1 | iex

# 兼容入口: raw main bootstrap
# 若未显式设置 CHECK_AI_CLI_REF / CHECK_AI_CLI_RAW_BASE, bootstrap 会自动解析 latest stable release tag
irm https://github.com/IIXINGCHEN/Check-AI-CLI/raw/main/install.ps1 | iex
```

### Windows (安装到自定义目录, 不需要管理员权限)
```powershell
$env:CHECK_AI_CLI_INSTALL_DIR = (Get-Location).Path
$env:CHECK_AI_CLI_PATH_SCOPE = 'CurrentUser'
irm https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.ps1 | iex
```

### 安全与稳定(推荐设置)

#### 推荐: 使用代理加速, 不改下载源
```powershell
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
irm https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.ps1 | iex
```

#### 默认: latest stable release
```powershell
# 未设置 CHECK_AI_CLI_REF 时, bootstrap 会自动解析 GitHub latest release tag
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

#### 推荐: 固定版本(避免 release 继续前进)
```powershell
# 你可以固定到 tag 或 commit SHA
$env:CHECK_AI_CLI_REF = 'v1.2.3'
irm https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.ps1 | iex
```

#### 开发/排障: 强制使用 main
```powershell
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

# 安装完成后, 直接执行
./bin/check-ai-cli

# 卸载(需要输入 DELETE 确认)
./uninstall.sh
```

### macOS / Linux (安全稳定推荐设置)
```bash
# 推荐: 用代理加速, 不改下载源
export HTTP_PROXY="http://127.0.0.1:7890"
export HTTPS_PROXY="http://127.0.0.1:7890"

# 推荐: stable bootstrap asset
curl -fsSL https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.sh | bash
```

```bash
# 默认: 若未设置 CHECK_AI_CLI_REF, raw main bootstrap 会自动解析 latest stable release tag
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

```bash
# 固定到 tag 或 commit
export CHECK_AI_CLI_REF="v1.2.3"
curl -fsSL https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.sh | bash
```

```bash
# 开发/排障: 强制使用 main
export CHECK_AI_CLI_REF="main"
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

## 发布流程(自动生成 checksums.sha256)

```powershell
# 1) 修改代码后先 add
git add -A

# 2) 自动生成/更新 checksums.sha256
.\tools\Update-Checksums.ps1

# 3) 提交
git add checksums.sha256
git commit -m "Update checksums"
```

### 中国大陆网络较慢时, 推荐使用代理环境变量

#### PowerShell
```powershell
$env:CHECK_AI_CLI_SHOW_PROGRESS = '1'
$env:HTTP_PROXY  = 'http://127.0.0.1:7890'
$env:HTTPS_PROXY = 'http://127.0.0.1:7890'
irm https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.ps1 | iex
```

#### Bash
```bash
export CHECK_AI_CLI_SHOW_PROGRESS=1
export HTTP_PROXY="http://127.0.0.1:7890"
export HTTPS_PROXY="http://127.0.0.1:7890"
curl -fsSL https://github.com/IIXINGCHEN/Check-AI-CLI/releases/latest/download/install.sh | bash
```

启用 `CHECK_AI_CLI_SHOW_PROGRESS=1` 后, 安装阶段会输出统一的字节进度条:

```text
[##########..........] 50%
```

### 核心依赖检查

#### Windows
- Invoke-WebRequest

#### macOS / Linux
- curl 或 wget
- sha256sum 或 shasum



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
- **OpenCode**: GitHub Releases API (anomalyco/opencode) + opencode.ai/install 备用 (可用 CHECK_AI_CLI_OPENCODE_VERSION 覆盖)

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
# Factory 的 Windows bootstrap 现在会先提供版本/下载元数据,
# 再由本项目脚本在本地下载并校验官方二进制, 不再直接执行远端 bootstrap 内容
.\Check-FactoryCLI-Version.ps1
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

### OpenCode (opencode)

自动从 GitHub (anomalyco/opencode) 获取最新版本。可通过环境变量 CHECK_AI_CLI_OPENCODE_VERSION 覆盖为指定版本。

#### Windows
```bash
# 方法 0: Git Bash + curl (推荐, 与 macOS/Linux 一致)
curl -fsSL https://opencode.ai/install | bash -s -- --version 1.1.21
```

```powershell
# 方法 1: Scoop
scoop install extras/opencode

# 方法 2: Chocolatey
choco install opencode -y

# 方法 3: npm (fallback)
npm install -g opencode-ai@latest
```

提示: 脚本现在会优先自动修复 `OpenCode` 的 PATH 冲突, 会把 `~/.opencode/bin` 或对应用户安装目录提升到 PATH 前面, 并刷新当前会话。若 PowerShell 仍命中旧的 `%APPDATA%\\npm\\opencode.ps1`, 先重开终端再检查:

```powershell
Get-Command opencode
opencode --version
```

如果当前会话仍被旧 shim 缓存, 再使用以下临时兜底:

```powershell
$exe = Join-Path $env:USERPROFILE ".opencode\\bin\\opencode.exe"
Set-Alias opencode $exe
opencode --version
```

#### macOS / Linux
```bash
# 默认: 官方安装脚本 (curl / wget)
curl -fsSL https://opencode.ai/install | bash

# 可选: Homebrew
brew install anomalyco/tap/opencode

# 可选: npm (fallback)
npm install -g opencode-ai@latest
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

### 问题：缺少 sha256sum/shasum (校验工具)

**错误信息**:
```
sha256 tool not found
```

**原因**:
- `install.sh` 会对下载文件做 SHA256 校验, 没有 `sha256sum` 或 `shasum` 会直接失败, 这是为了安全稳定.

**解决方案**:
```bash
# macOS (Homebrew)
brew install coreutils

# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y coreutils

# Fedora/RHEL
sudo dnf install -y coreutils

# CentOS/RHEL (旧版)
sudo yum install -y coreutils

# Alpine
sudo apk add coreutils

# Arch
sudo pacman -S coreutils
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
- ✅ 验证下载文件的校验和（checksums.sha256）
- ✅ 不收集或发送任何用户数据
- ✅ 开源透明，可审查代码

## 📋 版本数据源

| 工具 | 主要数据源 | 备用数据源 |
|------|----------|-----------|
| Factory CLI | app.factory.ai/cli/install.sh | app.factory.ai/cli/windows |
| Claude Code | github.com/anthropics/claude-code/releases/latest | GCS claude-code-releases/stable, registry.npmjs.org |
| OpenAI Codex | github.com/openai/codex/releases/latest | registry.npmjs.org/@openai/codex |
| Gemini CLI | github.com/google-gemini/gemini-cli/releases/latest | registry.npmjs.org/@google/gemini-cli |
| OpenCode | github.com/anomalyco/opencode/releases/latest | registry.npmjs.org/opencode-ai |

- `Claude Code`、`Codex`、`Gemini CLI`、`OpenCode`: 现在优先使用官方仓库 release 作为 `latest` 来源, 只有仓库源不可用时才回退到其他官方发布源。
- `Claude Code`: 仓库 release 不可用时, 再回退到官方 stable 发布源, 最后才回退到 npm。
- `OpenCode`: 仓库源不可用时回退到官方 npm 包; 若官方来源都失败则显示 `unknown`.
- 五个工具在检查前和更新后都会自动尝试修复 PATH/环境变量冲突, 以减少“已安装但命令未识别”问题。

## 🚢 自动发布 GitHub Releases

推送符合 `vX.Y.Z` 格式的 tag 后, GitHub Actions 会自动创建 GitHub Release。

### 发布方式

```bash
git tag v1.3.0
git push origin v1.3.0
```

### 自动校验

- tag 必须匹配 `vX.Y.Z`
- tag 对应提交必须已经包含在 `main` 上
- `checksums.sha256` 必须与仓库当前内容一致
- 同名 Release 已存在时会直接失败, 不自动覆盖

### 自动上传的 Release 附件

- `checksums.sha256`
- `install.ps1`
- `install.sh`
- `uninstall.ps1`
- `uninstall.sh`
- `bin/check-ai-cli`
- `bin/check-ai-cli.cmd`
- `bin/check-ai-cli.ps1`
- `scripts/Check-AI-CLI-Versions.ps1`
- `scripts/check-ai-cli-versions.sh`

Release 页面会包含一段固定说明, 并附加 GitHub 自动生成的 Release Notes。

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
- [OpenCode 官方文档](https://opencode.ai/docs/cli)
- [Factory CLI GitHub](https://github.com/Factory-AI/factory)
- [Claude Code GitHub](https://github.com/anthropics/claude-code)
- [OpenAI Codex GitHub](https://github.com/openai/codex)
- [OpenCode GitHub](https://github.com/anomalyco/opencode)

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
- ✅ 支持 Factory CLI、Claude Code、OpenAI Codex、Gemini CLI、OpenCode
- ✅ 跨平台支持 (Windows/macOS/Linux)
- ✅ 多数据源备用方案
- ✅ 交互式安装界面
