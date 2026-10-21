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

仓库不包含开发者签名团队设置。正式发行仍需准备自己的签名、公证和交付流程；当前无安装包或自动更新。

已补充独立的 CI 发布草稿工作流，配置及凭据要求见[发布流程](RELEASING.md)。它与普通的无签名构建检查分开，目前尚未完成远程签名、公证验收。

「登录时启动」通过 [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice) 管理，需要正确的代码签名。上述无签名命令仅用于编译验证，不代表登录项注册已验收。相关单元测试使用注入的假服务，不修改开发机器的登录项。

## 测试

```sh
swift test
git diff --check
```

默认测试使用临时文件与本地假服务，不访问真实账号、不发起模型调用、不消费重置卡。CI 同时运行离线测试和无签名 Release 构建。

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

本应用通过本地 Codex App Server 的账号接口读取额度，并提供手动重置入口。账号凭证由 CLI 的系统钥匙串存储管理，应用不使用开发者自建后端。

截至 2026-10-21，[官方认证说明](https://learn.chatgpt.com/docs/app-server#auth-endpoints)允许已有本地或开源应用继续使用此认证，同时明确不允许将 App Server 认证用于商业或托管服务。官方建议迁移至 [Sign in with ChatGPT](https://developers.openai.com/siwc/quickstart)。

本项目尚未迁移，也不承诺迁移后仍有相同的额度和重置接口。发行前需重新核对当时的认证要求及协议；MIT 许可证不授予 OpenAI 服务访问权。

## 本地数据

| 数据 | 位置与用途 |
| --- | --- |
| CLI 独立配置 | `~/Library/Application Support/CodexWatcher/Runtime`，与其他客户端隔离 |
| 待确认重置 | 同级 `State/pending-resets.json`，保存账号标识、卡片 ID 和幂等键，不含密码或访问令牌 |
| 应用偏好 | 本地 UserDefaults，保存外观、CLI 路径和显示选项等 |

应用不记录原始协议、登录 URL 或令牌，并丢弃 CLI 标准错误；CLI 自身的状态及官方服务的处理行为不由应用控制。更多说明见 [安全与隐私](../SECURITY.md)。
