# 发布版本

[返回 README](../README.md) · [开发与接入](DEVELOPMENT.md)

推送版本标签后，GitHub Actions 自动测试、构建 Universal 应用、完成 Developer ID 签名与 Apple 公证、检查最终 DMG/ZIP，并公开发布 Release。没有人工验收步骤，不需要自建下载服务器。

`v0.2.0` 已[正式发布](https://github.com/ximatai/CodexWatcher/releases/tag/v0.2.0)，DMG 已完成本地安装与运行验收。后续版本采用以下自动门禁；自动检查不等于所有系统、硬件和真实服务场景均已验证。

## 一次性准备

### 1. Developer ID Application 证书

Apple 开发者会员不代表本机已有站外分发证书。需要 **Developer ID Application** 及对应私钥；`Apple Development`、`Apple Distribution`、`Developer ID Installer` 和临时签名不能替代它。

先检查有效签名身份：

```sh
security find-identity -v -p codesigning
```

如果没有 Developer ID Application，可在 Xcode → Settings → Accounts → 选择团队 → Manage Certificates 中创建，或按 [Apple 官方说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)操作；需有相应团队权限。如果证书在其他 Mac 上，导入含私钥的 P12 即可，不必重复创建或撤销其他项目的证书。

在钥匙串访问的「我的证书」中确认它可展开显示私钥，再导出该身份为带密码的 `.p12`。只下载 `.cer` 不包含私钥，无法让 CI 签名。

### 2. 公证凭据

此工作流使用具备公证权限的 **App Store Connect 团队 API 密钥**，需要 `.p8` 私钥、Key ID 和 Issuer ID。它用于 Apple 公证，不会将应用提交到 Mac App Store。个人 API 密钥的参数形式不同，当前脚本未使用该方式。

另外准备签名证书所属团队的 Team ID。不要把个人开发身份括号中的 ID 直接当作 Team ID。

### 3. GitHub Secrets

仓库 Settings → Environments 中创建 `release` 环境，并设置以下 Secrets。仓库或组织级同名 Secrets 也可以使用；环境级配置便于独立控制发布权限。

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 含证书及私钥的 P12，Base64 编码 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 导出密码 |
| `APPLE_TEAM_ID` | 签名证书所属团队的 Team ID |
| `NOTARY_KEY_P8_BASE64` | 团队公证 API 私钥 P8，Base64 编码 |
| `NOTARY_KEY_ID` | 对应 Key ID |
| `NOTARY_ISSUER_ID` | 对应 Issuer ID |

例如在本机将编码结果复制到剪贴板，再粘贴到 Secret 输入框：

```sh
base64 -i DeveloperID.p12 | pbcopy
base64 -i AuthKey_EXAMPLE.p8 | pbcopy
```

每次只执行一条并保存对应 Secret，避免后一次覆盖剪贴板。Base64 不是加密；不要把结果、证书、私钥或密码发到 Issue、聊天、日志或 Git 仓库。

建议限制 `release` 环境仅允许 `main` 分支及受控的 `v*` 标签，自动发布模式不设置必需人工审批。发布凭据只在凭据检查及签名步骤中注入，不提供给普通 PR 工作流。工作流将证书导入临时钥匙串，结束时删除钥匙串和临时私钥文件。[GitHub 官方签名指南](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

## 自动发布

先在 `CHANGELOG.md` 中加入对应版本章节，将本次已完成的改动从「未发布」移入其中。例如：

```markdown
## 0.2.2 — 2026-10-21

- 本版实际完成的变更。
```

标题必须使用 `## 版本号 — YYYY-MM-DD`，内容至少包含一条非空 `-` 列表项。预发布版必须单独记录，如 `## 0.3.0-beta.1 — YYYY-MM-DD`，不能借用 `0.3.0` 或「未发布」。记录缺失、重复或为空都会在构建、签名和公证前阻止发布。

再将改动合入并推送至 `main`，创建一个未使用过的版本标签：

```sh
git tag v0.2.2
git push origin v0.2.2
```

- `v0.2.2`：公开正式版，并设为 Latest。
- `v0.3.0-beta.1`：公开预发布版，不取代 Latest。
- Actions → Release → Run workflow：在 `main` 上手动运行仍只生成草稿，便于排查；勾选 `verify_only` 则只验证，不创建 Release。正常发版无需手动运行。

仅接受版本标签；标签提交必须属于 `main` 历史。任何门禁失败都会阻止公开发布；文件先上传到草稿，全部上传成功后才公开。已发布版本不会覆盖，修复应使用新版本号。手动创建的草稿在标签尚未落地时，必须继续对应原提交。

发布环境不能设置必需人工审批，否则标签发布仍会等待审批。应限制为 `main` 和受控 `v*` 标签，并限制有权推送这些标签的维护者。

工作流使用 `xcode-27` macOS runner 和 Xcode 27.1，当前 runner 标签处于 GitHub 公共预览阶段；工具链变动时需要维护。它会：

1. 检查版本与源提交；测试变更记录提取器，从对应版本章节生成说明，再检查六项凭据并运行离线测试。
2. 编译 `arm64 + x86_64`，检查二进制架构及应用版本。
3. 验证唯一的 Developer ID Application 身份与 Team ID，启用 Hardened Runtime 和安全时间戳签名。
4. 公证并附加应用票据，验证签名、票据及 Gatekeeper，再生成 ZIP 与拖拽安装的 DMG。
5. 对 DMG 再签名、公证和附加票据，生成 SHA-256 校验文件。
6. 挂载最终 DMG、解压 ZIP，分别核对校验值、版本、架构、签名团队、签名、公证票据和 Gatekeeper，并检查 DMG 的 Applications 链接。
7. 分别启动两个安装包中的应用，在隔离的本地假服务下验证额度读取、主窗口、状态栏和亮暗色切换，要求应用正常退出。假服务拒绝所有写操作，不启动真实 CLI、不读取真实账号、不注册登录项。
8. 上传 DMG、ZIP、SHA256SUMS.txt；标签触发时自动公开，手动运行时保留草稿。

Release 的「本版变更」直接取自本次提交的 `CHANGELOG.md`，不另写一份摘要；安装说明复用 [RELEASE_INSTALLATION.md](RELEASE_INSTALLATION.md)，完整记录链接固定到源提交，避免随 `main` 漂移。修订历史版本文字时可在 `main` 修正记录后重新生成并编辑 Release 正文，不移动版本标签或替换已有安装包。

本地生成说明（不上传、不创建 Release）：

```sh
python3 scripts/generate-release-notes.py v0.2.1 /tmp/release-notes.md \
  --repository ximatai/CodexWatcher --revision "$(git rev-parse HEAD)"
python3 -m unittest discover -s scripts/tests -v
```

应用版本采用标签中的数字部分，构建号采用 GitHub run number。预发布标签如 `v0.2.0-beta.1` 的应用版本为 `0.2.0`，Release 则保留完整标签并标记预发布。

公证每次最多等待 30 分钟；超时或拒绝即停止，不能跳过公证发布。超时不取消 Apple 服务端处理，作业日志中的失败信息和提交结果可用于后续核实。[Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 验证边界与故障处理

自动启动检查验证应用内部状态及正常退出，不能替代视觉质量检查、真实登录和令牌长期刷新、跨登录启动或 Intel 真机测试。Universal 编译不等于 Intel 真机验收。界面细节和个别系统兼容性问题可能随版本发布，通过补丁版本修复；账号串用、误消费和凭据泄露属于阻断问题。

应用仍需要单独安装 Codex CLI，不捆绑、不自动下载。真实重置尚未验收，测试不消费真实卡片。发布说明保留这些边界。

失败时查看 Actions 日志，修复后重新运行未发布版本；如果已经公开，则发布新补丁版本，不移动旧标签或覆盖旧文件。严重问题可撤下有问题的安装包，并引导用户使用上一稳定版本。不要将 Source code ZIP 当作应用安装包。

## 本地验证

不使用凭据，只验证 Universal 编译：

```sh
bash scripts/build-release.sh v0.2.0 dist
```

输出目录须为新目录或不含同名应用。生成的 `.app` 仍未签名、公证，不用于公开分发。`scripts/notarize-release.sh` 使用与 CI 相同的六项环境变量；仅在已准备正式凭据、确需提交 Apple 公证时运行。它不会登录 ChatGPT 或触发重置卡。

对已签名、公证的产物运行最终验证（需要可用的 macOS 图形会话）：

```sh
APPLE_TEAM_ID=YOURTEAMID bash scripts/verify-release.sh v0.2.1 dist
```

仅验证隔离启动可运行 `python3 scripts/smoke-test-app.py /path/to/CodexWatcher.app`。冒烟模式必须同时提供专用参数与临时假服务目录，缺少夹具即失败，不回退到真实 CLI。
