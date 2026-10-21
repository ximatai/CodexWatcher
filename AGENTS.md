# 项目协作约定

本文件适用于整个仓库。发版细节见 [docs/RELEASING.md](docs/RELEASING.md)。

## 发版顺序

用户要求发布指定版本时，必须按以下顺序完成，不得先打 tag 再补记录：

1. 核对待发布提交及实际改动，先更新 `CHANGELOG.md`。将本次已完成内容从「未发布」移到对应版本章节，保留尚未发布的内容，不写计划或占位文字。
2. 章节标题必须为 `## 版本号 — YYYY-MM-DD`，版本号不带 `v`，日期采用实际发布日期；至少包含一条非空 `-` 列表项。章节必须唯一，预发布版使用完整版本号（例如 `0.3.0-beta.1`），不能借用正式版或「未发布」记录。
3. 运行 `python3 -m unittest discover -s scripts/tests -v`、`swift test` 和 `git diff --check`，修复失败项；不跳过发布门禁。测试不得消费真实重置卡，也不得使用真实账号进行重置测试。
4. 将包含 CHANGELOG 的改动提交并推送到 `main`。使用 `scripts/generate-release-notes.py` 对目标版本生成并核对说明；缺失、重复或空记录必须修复后才能继续。示例：

   ```sh
   python3 scripts/generate-release-notes.py vX.Y.Z /tmp/codex-watcher-release-notes.md \
     --repository ximatai/CodexWatcher --revision "$(git rev-parse HEAD)"
   ```

5. 确认目标提交已在远程 `main`、工作区干净、目标标签及 Release 未被占用，再在该提交创建并推送 `v版本号` 标签。不得移动或覆盖已有发布标签。
6. 跟进标签触发的 Release 工作流直至结束。CI 自动执行测试、构建、签名、公证、最终安装包与隔离启动检查，全部通过后公开发布，无需增加人工验收环节。正式版设为 Latest；带预发布后缀的版本不替代 Latest。
7. 核对公开 Release 的版本、源提交、正式版/预发布状态，以及 DMG、ZIP、`SHA256SUMS.txt` 三份附件，向用户提供 Release 和 CI 链接。仅推送标签不算发版完成；失败时继续排查并如实报告。

## Release 说明与历史修订

- `CHANGELOG.md` 是版本变更的唯一来源，CI 提取精确匹配的版本章节，再附加 `docs/RELEASE_INSTALLATION.md`。不要在工作流另写一份版本摘要。
- 安装要求、CLI 依赖、Intel 验证边界及真实重置未验收的说明必须与实际情况一致，不把自动检查表述为全部场景已验收。
- 修订历史说明时，先修正 CHANGELOG，提交后用同一生成器重建对应 Release 正文。只更新文字，不移动旧标签、不替换已发布附件；程序修复使用新版本号。
- 手动运行工作流默认生成草稿，`verify_only` 仅验证；它们用于排查，不替代正常的标签自动发布流程。只修改文档或发版规则时，不自行创建新版本标签。
