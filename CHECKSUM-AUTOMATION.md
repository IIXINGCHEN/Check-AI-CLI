# checksums.sha256 自动化与可信校验链

## 已实现的生命周期

### Pull Request

`.github/workflows/verify-checksums.yml` 在 PR 中执行：

```powershell
./tools/Update-Checksums.ps1 -Check
```

清单过期时 PR 直接失败，防止不一致内容进入主分支。

### main 分支

`.github/workflows/update-checksums.yml` 监控全部发布载荷文件。发生变化后：

1. 从 Git 索引中的已提交文件计算摘要；
2. 自动生成 `checksums.sha256`；
3. 再次执行 `-Check`；
4. 由 `github-actions[bot]` 提交更新后的清单。

仓库启用分支保护时，需要允许 GitHub Actions 写入 `main`，或将该工作流调整为自动创建 PR。

### Tag / Release

原 Release 工作流继续执行 `Update-Checksums.ps1 -Check`。摘要不一致时拒绝发布，因此不会发布文件与清单错配的版本。

## 安装时的可信获取

安装器现在只从同一不可变来源获取清单和所有文件：

- 默认优先使用最新稳定 Release tag；
- Release API 不可用时使用 main 当前的 40 位 commit SHA；
- 显式设置 `CHECK_AI_CLI_REF=main` 时，也会先解析成 commit SHA；
- 无法获得 tag 或 commit 时失败关闭，不再退回可变的 `main` URL。

这样避免了先读取一个版本的 `checksums.sha256`，再下载另一个提交中的文件。

## 可选的清单锚定

如果通过可信的独立渠道获得了 `checksums.sha256` 自身的 SHA-256，可设置：

```powershell
$env:CHECK_AI_CLI_REF = 'v1.2.3'
$env:CHECK_AI_CLI_EXPECTED_MANIFEST_SHA256 = '<64位十六进制摘要>'
.\install.ps1
```

安装器会先验证清单自身，再解析清单并逐个验证载荷。

## 防御性解析

安装器现在拒绝：

- 非 64 位十六进制 SHA-256；
- 重复或冲突的清单条目；
- 绝对路径、反斜杠路径、盘符路径；
- `.`、`..`、空路径段；
- 重复的 `distribution-files.txt` 条目；
- 空校验清单。

这些检查防止被篡改的清单进行路径穿越或覆盖安装目录之外的文件。

## 本地 ZIP

本地 ZIP 继续使用 ZIP 内置清单。校验失败时不会联网下载“最新清单”覆盖它，因为旧载荷和最新清单可能属于不同版本。正确恢复方式是重新下载并解压可信 Release ZIP。
