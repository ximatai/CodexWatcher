# 发布版本

[返回 README](../README.md) · [开发与接入](DEVELOPMENT.md)

GitHub Actions 负责构建 Universal 应用、Developer ID 签名、Apple 公证、生成 DMG/ZIP 及 Release 草稿。不需要自建下载服务器；正式发布由维护者验收后操作。

2026-10-21，`v0.2.0` 已通过[首次完整发布工作流](https://github.com/ximatai/CodexWatcher/actions/runs/39575378778)，生成签名、公证后的 DMG、ZIP 和校验文件，当前保留为 Release 草稿。本机已核对 SHA-256、应用和 DMG 签名、公证票据及应用 Gatekeeper 检查；安装后的功能验收与正式公开发布仍需维护者完成。普通 CI 的无签名构建不能作为正式安装包。

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

建议限制 `release` 环境仅允许 `main` 分支及受控的 `v*` 标签，并按团队需要配置审批。发布凭据只在凭据检查及签名步骤中注入，不提供给普通 PR 工作流。工作流将证书导入临时钥匙串，结束时删除钥匙串和临时私钥文件。[GitHub 官方签名指南](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

## 触发草稿

将改动合入并推送至 `main` 后，可二选一：

- Actions → Release draft → Run workflow，分支选 `main`，输入版本如 `v0.2.0`。
- 在 `main` 的提交上创建并推送版本标签，如 `v0.2.0` 或 `v0.2.0-beta.1`。

仅接受版本标签，不接受任意路径或 shell 内容；已有标签必须指向当前构建提交，提交必须属于 `main` 历史。未公开的草稿可以重跑上传；已正式发布的版本不会被覆盖。手动创建的草稿在标签尚未落地时，也必须继续对应原提交。

工作流使用 `xcode-27` macOS runner 和 Xcode 27.1，当前 runner 标签处于 GitHub 公共预览阶段；工具链变动时需要维护。它会：

1. 检查版本、源提交和六项凭据，运行离线测试。
2. 编译 `arm64 + x86_64`，检查二进制架构及应用版本。
3. 验证唯一的 Developer ID Application 身份与 Team ID，启用 Hardened Runtime 和安全时间戳签名。
4. 公证并附加应用票据，验证签名、票据及 Gatekeeper，再生成 ZIP 与拖拽安装的 DMG。
5. 对 DMG 再签名、公证和附加票据，生成 SHA-256 校验文件。
6. 上传三份文件到 Release **草稿**，不自动公开发布。

应用版本采用标签中的数字部分，构建号采用 GitHub run number。预发布标签如 `v0.2.0-beta.1` 的应用版本为 `0.2.0`，Release 则保留完整标签并标记预发布。

公证每次最多等待 30 分钟；超时或拒绝即停止，不能跳过公证发布。超时不取消 Apple 服务端处理，作业日志中的失败信息和提交结果可用于后续核实。[Apple 公证流程](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 发布前验收

从草稿下载 DMG，检查签名、公证和安装，再验证登录、用量、亮暗色、状态栏设置及登录启动。Universal 编译不等于 Intel 真机验收；发布说明应如实注明硬件验证范围。

应用仍需要用户单独安装 Codex CLI，不捆绑、不自动下载 CLI。不要宣传为完全无依赖；安装说明和 Release 说明需保留此前提。真实重置尚未验收，测试过程中不消费真实卡片。

确认后在 GitHub Releases 中人工发布草稿。不要将 GitHub 自动生成的 Source code ZIP 当作应用安装包。

## 本地验证

不使用凭据，只验证 Universal 编译：

```sh
bash scripts/build-release.sh v0.2.0 dist
```

输出目录须为新目录或不含同名应用。生成的 `.app` 仍未签名、公证，不用于公开分发。`scripts/notarize-release.sh` 使用与 CI 相同的六项环境变量；仅在已准备正式凭据、确需提交 Apple 公证时运行。它不会登录 ChatGPT 或触发重置卡。
