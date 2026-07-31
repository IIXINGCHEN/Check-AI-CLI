# Ultracode 对抗式源码审查报告

> **历史文档**：本报告记录的是 `1dae80b`（2026-07-23，`refactor: npm-only AI CLI updates for five packages`）之前的代码状态。
> 其中的 Factory 官方通道下载、curl 降级、双通道版本漂移处理，以及 `tests/FactoryUpdateReview.Tests.ps1` 等内容已随该重构移除，不再反映当前实现。
> 归档于 2026-07-26，仅作审计追溯用。

## 结论

本次故障不是单点问题，而是三个独立缺陷叠加：

1. **发布完整性清单已过期**：原 ZIP 内 `checksums.sha256` 与 5 个 Windows 分发文件不一致，导致本地 `install.ps1` 必然在安装前失败。失败与管理员权限无关。
2. **Factory 下载重试缺少传输层异构降级**：三次重试都使用 PowerShell `Invoke-WebRequest`/HttpClient；代理与该传输栈不兼容时，只会重复得到相同 EOF。
3. **Factory 的 npm 降级语义错误**：官方二进制通道为 v0.170.0，而 npm 通道仍可能只有 v0.162.1。安装 `droid@latest` 成功不等于达到选定目标版本，原代码却输出“installed via npm”，形成假成功。

## 已修复

### P0：恢复安装包内部一致性

- 按 `distribution-files.txt` 重新生成全部 SHA-256。
- 校验结果：11/11 分发文件全部通过。
- 将 Windows 分发文件统一为仓库约定的 CRLF，避免跨平台换行造成摘要漂移。

### P0：处理代理下的 unexpected EOF

- 保留 PowerShell 下载与重试作为主路径。
- 主路径耗尽后，使用 Windows 自带 `curl.exe` 作为独立传输栈。
- curl 强制 HTTP/1.1，并启用重定向、超时、失败重试及非零退出码检查。
- 下载仍写入 `.download` 临时文件；仅非空且成功时原子移动到目标位置，失败时清理临时文件。
- 既有 SHA-256 验证保持不变，curl 降级不会绕过完整性校验。

### P0：消除旧 npm 通道的假成功

- 同时解析 Factory 官方通道与 npm 通道版本，并显式报告版本漂移。
- 选择两个通道中的较新版本作为检查目标。
- 官方下载失败且 npm 版本落后时，不再执行一个不可能达到目标的 npm 安装，也不再输出误导性的成功信息。
- npm 与目标一致、或官方版本未知时，仍保留 npm 降级路径。

### P1：纠正安装器错误指引

- 本地校验失败时不再提示“以管理员身份运行”。
- 改为明确提示：本地发布载荷完整性失败，应重新解压可信 ZIP，不能绕过校验。

### P1：发布卫生

- 修复包不再携带 `.codegraph` 的本地数据库、日志和 PID 文件。

## 新增回归场景

PowerShell 回归测试已增加：

- PowerShell 下载发生 EOF 后切换 curl 并成功发布文件。
- 官方 Factory 版本高于 npm 时拒绝旧 npm 假降级。
- Factory 双通道版本漂移可见且选择较新版本。

## 已执行验证

- ZIP 原始压缩结构测试：通过。
- Bash 语法检查：通过。
- Shell 回归：7/7 测试文件通过。
- 分发 SHA-256：11/11 通过。
- Windows 文件换行策略：通过。

当前沙箱没有 `pwsh`/`powershell.exe`，因此无法在此 Linux 环境执行 PowerShell 测试集；相关回归已写入 `tests/FactoryUpdateReview.Tests.ps1`，应在 Windows CI 上运行：

```powershell
pwsh -NoProfile -File .\run-all-tests.ps1
```

## 建议复测步骤

```powershell
Expand-Archive .\Check-AI-CLI-ultracode-fixed.zip -DestinationPath .\Check-AI-CLI-ultracode-fixed
cd .\Check-AI-CLI-ultracode-fixed
.\install.ps1
.\check-ai-cli.cmd
```

选择 `U` 后，Factory 官方下载若再次触发 PowerShell EOF，应出现切换 `curl.exe with HTTP/1.1` 的日志；下载完成后仍会执行官方 SHA-256 校验。
