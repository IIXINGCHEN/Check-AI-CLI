# Check-AI-CLI

跨平台检查并更新常用 AI 编程 CLI（**仅 npm 全局托管**）：

| 工具 | 官方 npm 包 | 更新策略 |
|---|---|---|
| Claude Code | `@anthropic-ai/claude-code@latest` | 官方 npm；自动维护 PATH 优先级 |
| OpenAI Codex | `@openai/codex@latest` | 官方 npm；镜像缺 optional 二进制时回退官方源 |
| Gemini CLI | `@google/gemini-cli@latest` | 官方 npm |
| Grok Build | `@xai-official/grok@latest` | 官方 npm；canonical `.grok/bin` 安装可由 npm 原位接管，其他外部来源继续阻断 |
| OpenCode | `opencode-ai@latest` | 官方 npm |

项目负责版本发现、npm registry 区域自适应与双向故障转移、PATH 偏好修复、全局安装/更新与结果复核。
**仅支持官方全局 npm 包**，不支持第三方远程执行脚本、系统包管理器（brew/scoop/choco）或 CLI 自升级。

不收集任何用户数据。

---

## 快速开始

### Windows：一键安装

默认安装至 `%LOCALAPPDATA%\Programs\Tools\Check-AI-CLI` 并自动写入当前用户 PATH：

```powershell
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

固定不可变 Commit SHA 安装：

```powershell
$env:CHECK_AI_CLI_REF = '63ba8d5467b6fa2a2be42450d16adc8ae1769e5e'
irm https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.ps1 | iex
```

全机安装（需管理员权限）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Machine
```

### macOS / Linux：一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/IIXINGCHEN/Check-AI-CLI/main/install.sh | bash
```

### 运行

安装完成后重新打开终端即可全局使用：

```bash
check-ai-cli
```

### 安全卸载

卸载器要求确认输入 `DELETE`，仅删除带有合法 `.check-ai-cli-installed` 标记的目录：

```powershell
.\uninstall.ps1
```

```bash
./uninstall.sh
```

---

## 检查与更新

### 交互菜单

运行命令后提供交互菜单：单个检查、全部检查、全部检查并更新（`U`）、退出。

```powershell
.\Check-AI-CLI-Versions.ps1
```

```bash
bash ./check-ai-cli-versions.sh
```

### 自动模式 (CI / 定时任务)

```powershell
.\Check-AI-CLI-Versions.ps1 -Auto
```

```bash
CHECK_AI_CLI_AUTO=1 ./check-ai-cli-versions.sh --yes
```

- **前置依赖**：Node.js / npm（更新 CLI 所需）。
- **验证机制**：更新完成后自动重新读取本地版本，验证版本一致后方报告成功。
- **源自动切换**：自动探测官方 npm、npmmirror、腾讯和华为 registry；按可达性、区域偏好与响应时间排序。任一源安装失败、缺少目标版本、命令不可运行或版本不匹配时，会自动继续尝试下一源。
- **版本正确性**：官方 npm 的 dist-tag 是首选权威来源；官方 metadata 不可达时，会比较所有可达国内源并选择其中最新的有效 SemVer，再以精确版本安装，避免单个镜像的陈旧 `latest` 阻止更新。
- **生命周期脚本**：全局安装仅通过当前命令的 `--allow-scripts` 放行已审查包，不修改用户 `.npmrc`，也不动态放行未知依赖。
- **Grok 迁移**：检测到官方 installer 使用的 canonical `.grok/bin/grok`（Windows 为 `grok.exe`）时，交由 `@xai-official/grok` 的官方 `postinstall` 原位接管；配置、认证和会话所在的 `.grok` 目录不会被本工具删除。其他目录中的同名命令仍按来源冲突处理。

---

## 安全与防篡改模型

- **零远程第三方脚本**：所有受管 CLI 统一通过 `npm i -g <package>@latest` 更新，不执行任何外部远程脚本。
- **最小脚本许可**：只对每个官方 CLI 已核验的 install-time lifecycle package 使用一次性 allowlist，不持久化 npm 用户配置。
- **不可变安装与分发哈希**：工具自身分发载荷严格匹配 `checksums.sha256`，支持通过 `$env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256` 进行带外哈希锚定。
- **镜像防劫持**：第三方 raw 镜像默认拦截；安装器强制校验路径穿越与目录边界。
- **提权隔离安全**：UAC 提权临时脚本采用随机 GUID 隔离且执行后自清理。

---

## 环境变量配置

| 变量 | 作用 | 示例 |
|---|---|---|
| `CHECK_AI_CLI_AUTO` | 自动模式（跳过确认直接更新） | `1` |
| `CHECK_AI_CLI_REGION` | 调整国内/官方源首选顺序；首选不可达时仍自动切换 | `China` / `Global` |
| `CHECK_AI_CLI_RETRY` | 下载重试次数 (1-10) | `3` |
| `CHECK_AI_CLI_REF` | 安装本工具时锁定 tag / commit | `v1.3.0` |
| `CHECK_AI_CLI_RAW_BASE` | 自定义原始分发源 | `https://mirror.example/repo` |
| `CHECK_AI_CLI_ALLOW_UNTRUSTED_MIRROR` | 允许非官方 raw 源 | `1` |
| `CHECK_AI_CLI_INSTALL_DIR` | 自定义安装目录 | `E:\Tools\Check-AI-CLI` |
| `CHECK_AI_CLI_PATH_SCOPE` | PATH 写入范围 | `CurrentUser` / `Machine` |
| `CHECK_AI_CLI_RUN` | 安装完成后立即启动 checker | `1` |

---

## 开发与验证

```powershell
# 运行全套测试
.\run-all-tests.ps1
```

```bash
# 验证校验和
pwsh ./tools/Update-Checksums.ps1 -Check
```

修改分发载荷文件后更新校验和：

```powershell
git add distribution-files.txt install.ps1 install.sh uninstall.ps1 uninstall.sh bin scripts tools/PSModulePath.ps1
.\tools\Update-Checksums.ps1
git add checksums.sha256
```

---

## 发布

向 `main` 分支推送 `vX.Y.Z` 语义化 tag 自动触发 GitHub Actions Release 工作流。
