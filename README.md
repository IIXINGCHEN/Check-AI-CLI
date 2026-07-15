# Check-AI-CLI

跨平台检查并更新常用 AI 编程 CLI：Factory CLI、Claude Code、OpenAI Codex、Gemini CLI 和 OpenCode。

项目负责版本发现、PATH 修复、安装/更新回退和结果复核，不收集用户数据。

## 快速开始

### Windows：远程安装

默认安装到 `%LOCALAPPDATA%\Programs\Tools\Check-AI-CLI`，并写入当前用户 PATH。默认不会因为当前 PowerShell 已提权而安装到 Program Files。

```powershell
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

固定到不可变 commit：

```powershell
$env:CHECK_AI_CLI_REF = '63ba8d5467b6fa2a2be42450d16adc8ae1769e5e'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

安装完成后重新打开 PowerShell，然后运行：

```powershell
check-ai-cli
```

### Windows：本地 ZIP 或源码

从 Release ZIP 解压后运行 `install.ps1`。安装器会优先验证 ZIP 内的清单和载荷；Git checkout 不会被误认为 Release ZIP，而会使用 immutable 远程来源。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

全机安装必须显式指定 `-Machine`，需要管理员权限：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Machine
```

### macOS / Linux：远程安装

默认安装到当前目录，并将 `bin/` 加入当前 Shell 的 profile。

```bash
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

固定版本：

```bash
CHECK_AI_CLI_REF='63ba8d5467b6fa2a2be42450d16adc8ae1769e5e' \
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

Windows Program Files 安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -ProgramFiles
```

## 检查与更新

直接运行主脚本：

```powershell
.\Check-AI-CLI-Versions.ps1
```

```bash
bash ./check-ai-cli-versions.sh
```

菜单支持单个工具、全部检查、全部检查并更新，以及退出。自动模式不会询问确认：

```powershell
.\Check-AI-CLI-Versions.ps1 -Auto
```

```bash
CHECK_AI_CLI_AUTO=1 ./check-ai-cli-versions.sh --yes
```

只检查 Factory CLI：

```powershell
.\Check-FactoryCLI-Version.ps1
```

更新完成后脚本会重新读取本地版本；无法验证新版本时返回失败状态。

## 支持工具与版本来源

| 工具 | 版本发现 | Windows 更新 | macOS / Linux 更新 |
|---|---|---|---|
| Factory CLI | 官方 bootstrap 元数据 | 官方二进制 + SHA256；失败后 npm/官方安装器 | 官方安装脚本；失败后 npm |
| Claude Code | GCS stable + npm；不可用时 GitHub Release | `claude update`、官方脚本、npm | `claude update`、官方脚本、npm |
| OpenAI Codex | npm；失败时 GitHub Release | npm，并检查 Windows optional package | npm 或 Homebrew |
| Gemini CLI | npm；失败时 GitHub Release | npm | npm 或 Homebrew |
| OpenCode | GitHub Release；失败时 npm，可用环境变量覆盖 | self-upgrade、Scoop、Chocolatey、npm、官方脚本 | 官方脚本、self-upgrade、Homebrew、npm |

Factory Windows bootstrap 只提供版本和下载元数据，项目不会直接执行该 bootstrap。派生下载地址必须是受信任的 Factory HTTPS 域名，二进制和 ripgrep 均需通过 SHA256 校验。

## 安全模型

- 远程安装默认解析稳定 Release tag；失败时解析 `main` 的 40 位 commit SHA，不使用可变 `main` 作为最终下载 ref。
- `checksums.sha256` 来自同一 immutable ref，并逐个校验分发载荷。
- 可设置 `CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256`，对清单本身增加独立摘要锚定。
- 安装器拒绝路径穿越、绝对路径、重复清单项、非法 SHA256 和空清单。
- 自动模式默认跳过远程脚本执行；只有显式设置 `CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT=1` 才允许该回退路径。
- 第三方镜像默认拒绝。显式设置 `CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR=1` 后才会使用，并显示安全警告。
- HTTPS 保护传输，但不能替代 checksum、immutable ref 和独立摘要锚定。

固定版本并固定清单摘要：

```powershell
$env:CHECK_AI_CLI_REF = 'v1.3.0'
$env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 = '<64 位 SHA256>'
.\install.ps1
```

## 配置

| 变量 | 作用 | 示例 |
|---|---|---|
| `CHECK_AI_CLI_AUTO` | 自动安装/更新，不询问确认 | `1` |
| `CHECK_AI_CLI_SHOW_PROGRESS` | 显示 checker 的字节进度 | `1` |
| `CHECK_AI_CLI_QUIET_PROGRESS` | 抑制 checker 进度 | `1` |
| `CHECK_AI_CLI_REGION` | 覆盖网络区域判断 | `China` / `Global` |
| `CHECK_AI_CLI_ALLOW_REMOTE_SCRIPT` | 自动模式允许远程脚本回退 | `1` |
| `CHECK_AI_CLI_RETRY` | 下载重试次数，范围 1-10 | `3` |
| `CHECK_AI_CLI_CLAUDE_UPDATE_TIMEOUT_SECONDS` | Claude 原生更新超时 | `300` |
| `CHECK_AI_CLI_OPENCODE_VERSION` | 覆盖 OpenCode 目标版本 | `1.4.3` |
| `CHECK_AI_CLI_OPENCODE_UPGRADE_TIMEOUT_SECONDS` | OpenCode 更新超时 | `300` |
| `CHECK_AI_CLI_REF` | tag、40 位 commit SHA 或 `main` | `v1.3.0` |
| `CHECK_AI_CLI_RAW_BASE` | 自定义原始文件源 | `https://mirror.example/repo` |
| `CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR` | 允许非官方原始文件源 | `1` |
| `CHECK_AI_CLI_INSTALL_DIR` | 安装目录 | `E:\Tools\Check-AI-CLI` |
| `CHECK_AI_CLI_PATH_SCOPE` | PATH 范围 | `CurrentUser` / `Machine` |
| `CHECK_AI_CLI_INSTALL_SCOPE` | PATH scope 兼容别名 | `Machine` |
| `CHECK_AI_CLI_RUN` | 安装完成后启动 checker | `1` |
| `CHECK_AI_CLI_UNINSTALL_PROGRAM_FILES` | 卸载 Program Files 安装 | `1` |

`CHECK_AI_CLI_ELEVATION_DONE`、`CHECK_AI_CLI_SKIP_MAIN` 等变量由内部重入和测试流程使用，不建议手动设置。

## 依赖

### Windows

- Windows 10/11。
- PowerShell 5.1 或更高版本。
- `Invoke-WebRequest`、`Get-FileHash` 或 checker 使用的 `certutil.exe`。
- 更新对应工具时可能需要 Node.js/npm、Git Bash、Scoop 或 Chocolatey。

### macOS / Linux

- Bash 3.2 或更高版本。
- `curl` 或 `wget`。
- `sha256sum` 或 `shasum`。
- 更新对应工具时可能需要 Node.js/npm、Homebrew 或 Git Bash。

## 项目结构

| 路径 | 作用 |
|---|---|
| `scripts/` | Windows 与 POSIX 主逻辑 |
| `bin/` | PATH 入口 |
| `install.ps1` / `install.sh` | 安装器 |
| `uninstall.ps1` / `uninstall.sh` | 安全卸载器 |
| `distribution-files.txt` | 分发载荷的唯一清单来源 |
| `checksums.sha256` | 清单载荷的 SHA256 摘要 |
| `tools/` | checksum、发布和维护工具 |
| `tests/` | PowerShell 与 Shell 回归测试 |
| `.github/workflows/` | 测试、checksum、发布和 CDN 工作流 |

兼容入口：

- `Check-AI-CLI-Versions.ps1` 转发到 Windows 主脚本。
- `Check-FactoryCLI-Version.ps1` 转发到 Windows 主脚本的 `-FactoryOnly` 模式。
- `check-ai-cli-versions.sh` 转发到 POSIX 主脚本。

## 开发与验证

运行全部可用回归测试：

```powershell
.\run-all-tests.ps1
```

```bash
bash ./run-all-tests.sh
```

基础静态检查：

```bash
bash -n install.sh uninstall.sh scripts/check-ai-cli-versions.sh
```

验证 checksum：

```powershell
.\tools\Update-Checksums.ps1 -Check
```

修改分发载荷后，必须重新生成并提交 `checksums.sha256`：

```powershell
git add distribution-files.txt install.ps1 install.sh uninstall.ps1 uninstall.sh bin scripts tools/PSModulePath.ps1
.\tools\Update-Checksums.ps1
git add checksums.sha256
```

## 发布

推送包含在 `main` 中的 `vX.Y.Z` tag 会触发 Release 工作流：

```bash
git tag v1.3.0
git push origin v1.3.0
```

发布前会检查 tag 格式、tag commit 是否在 `main`、checksum 是否一致，以及同名 Release 是否存在。

Release 资产由 `distribution-files.txt` 派生，包含 checksum、安装/卸载器、PATH 入口和主脚本。

## 常见问题

### PowerShell 禁止执行脚本

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

或直接使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Check-AI-CLI-Versions.ps1
```

### Bash 权限不足

```bash
chmod +x ./check-ai-cli-versions.sh ./bin/check-ai-cli
bash ./check-ai-cli-versions.sh
```

### checksum 工具缺失

macOS 可安装 `coreutils`，Linux 使用发行版包管理器安装 `coreutils`。安装器缺少 SHA256 工具时会失败关闭，不会跳过校验。

### Windows 下仍命中旧版本

查看实际命令来源并重新打开终端：

```powershell
where.exe claude
where.exe codex
where.exe opencode
claude --version
codex --version
opencode --version
```

如果同时存在 Program Files 和 CurrentUser 安装，直接运行目标安装目录下的 `bin/check-ai-cli.cmd`，或按提示清理旧安装。

### Codex 缺少 Windows optional package

优先使用官方 npm registry：

```powershell
npm install -g @openai/codex@latest --registry https://registry.npmjs.org
codex --version
```

## 相关链接

- [Factory CLI 文档](https://docs.factory.ai)
- [Claude Code 文档](https://code.claude.com/docs)
- [OpenAI Codex 文档](https://developers.openai.com/codex)
- [Gemini CLI 仓库](https://github.com/google-gemini/gemini-cli)
- [OpenCode 文档](https://opencode.ai/docs/cli)
- [GitHub Actions](https://github.com/IIXINGCHEN/Check-AI-CLI/actions)
