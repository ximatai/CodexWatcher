# 开发与接入

[返回 README](../README.md) · [贡献指南](../CONTRIBUTING.md) · [架构](ARCHITECTURE.md)

## 环境与构建

- macOS 14 及以上；已在本机 Apple Silicon 验证，尚未完成所有系统版本和 Intel 硬件验收。
- 可打开项目格式的 Xcode，已验证 27.1；核心测试需要 Swift 6 及以上。
- 独立安装的 Codex CLI，已验证 `codex-cli 0.163.0`，应用不下载或捆绑 CLI。
- 能提供对应额度字段的 ChatGPT 账号；并非所有套餐都提供相同字段或重置卡。

从仓库根目录执行：

```sh
xcodebuild -project CodexWatcher.xcodeproj -scheme CodexWatcher \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/CodexWatcher.app
```

仓库不包含开发者签名团队设置。自行发行需配置自己的签名与公证凭据。

独立的 CI 发布工作流已完成签名、公证和 DMG/ZIP 打包验证，版本标签触发自动发布，手动运行保留草稿；应用不提供自动更新。配置及凭据要求见[发布流程](RELEASING.md)。

「登录时启动」通过 [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) 管理，需要正确的代码签名。上述无签名命令仅用于编译验证，不代表登录项注册已验收。相关单元测试使用注入的假服务，不修改开发机器的登录项。

## 测试

```sh
swift test
git diff --check
```

默认测试使用临时文件与本地假服务，不访问真实账号、不发起模型调用、不消费重置卡。趋势测试覆盖时间片内读数变化、高频采样、恢复分段和持久化；隔离安装包检查通过真实鼠标及空格键事件验证进度/趋势切换、返回、重开恢复默认和焦点状态，不依赖辅助功能树。CI 同时运行离线测试、无签名 Release 构建和英文/简体中文的隔离界面检查。可在本地使用 `python3 scripts/smoke-test-app.py /path/to/CodexWatcher.app --language en` 或 `--language zh-Hans` 复验；语言设置仅作用于该测试进程。

可选的真实 CLI 握手检查：

```sh
WATCHER_LIVE_SMOKE=1 swift test --filter testAppServerHandshake
```

该检查使用临时未登录配置，只握手并读取账号状态，随后清理；不使用现有登录状态。任何测试都不应发起真实重置。

历史复查与验收边界见 [复查记录](REVIEW.md)。历史测试数量不代表当前测试总数。

## 图标与文档预览

```sh
xcrun swift scripts/generate-app-icons.swift
bash scripts/generate-screenshots.sh
```

图标从 1024 方形原稿生成。界面预览复用当前视图及隔离的虚构数据；不需要登录账号或安装 CLI。详见 [图标素材](design/README.md) 与 [预览素材](images/README.md)。

## 接入范围

本应用通过本地 Codex App Server 的账号接口读取额度，并提供手动重置、明确授权后的临期自动使用，以及默认关闭的满额自动 hello 入口。账号凭证由 CLI 的系统钥匙串存储管理，应用不使用开发者自建后端。

截至 2026-10-21，[官方认证说明](https://learn.chatgpt.com/docs/app-server#auth-endpoints)允许已有本地或开源应用继续使用此认证，同时明确不允许将 App Server 认证用于商业或托管服务。官方建议迁移至 [Sign in with ChatGPT](https://developers.openai.com/siwc/quickstart)。

本项目尚未迁移，也不承诺迁移后仍有相同的额度和重置接口。发行前需重新核对当时的认证要求及协议；MIT 许可证不授予 OpenAI 服务访问权。

## 本地数据

| 数据 | 位置与用途 |
| --- | --- |
| CLI 独立配置 | `~/Library/Application Support/CodexWatcher/Runtime`，与其他客户端隔离 |
| 满额问候去重 | 同级 `State/automatic-hello.json`，保存账号/窗口的认领状态、尝试结果及用量基线；未知结果不补发，不含令牌或回复 |
| 问候工作目录 | 同级 `HelloWorkspace/`，仅供独立临时 hello 会话使用 |
| 额度趋势历史 | 同级 `State/usage-trend-<账号哈希>.json`，仅含窗口、采样时间、剩余百分比、重置时间与分段标识；每账号最多保留 8 天、每窗口 4096 点，不含邮箱或令牌 |
| 待确认重置 | 同级 `State/pending-resets.json`，保存账号标识、卡片 ID、幂等键，及自动请求的原到期时间、次数和重试租约，不含密码或访问令牌 |
| 临期处理记录 | 同级 `State/expiry-actions.json`，保存账号与卡片组合的哈希标识及处理模式，跨重启和实例去重；不要作为缓存删除 |
| 应用偏好 | 本地 UserDefaults，保存外观、CLI 路径、显示选项及绑定账号的临期处理配置等 |

应用不记录原始协议、登录 URL 或令牌，并丢弃 CLI 标准错误；CLI 自身的状态及官方服务的处理行为不由应用控制。更多说明见 [安全与隐私](../SECURITY.md)。
