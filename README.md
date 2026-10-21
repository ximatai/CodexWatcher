# Codex Watcher

A native macOS menu bar app for monitoring Codex plan usage, quota pace, and earned reset cards.

原生 macOS 菜单栏额度监控工具。状态栏显示「图标 + 已用百分比」，展开后查看实际用量、自然时间基准、偏移、重置倒计时和重置卡。

> 独立第三方项目，与 OpenAI 无隶属关系。当前为本地开源预览版，未提供签名、公证的安装包，也未验证真实重置操作。

## 功能

- 浏览器官方登录，独立管理本机登录状态。
- 每 5 分钟读取用量，打开面板、系统唤醒及账号变更时也会刷新。
- 自动选择 Codex 中最长的额度窗口，也可切换其他服务器提供的窗口。
- 对比「实际消耗」与「自然时间进度」，提前发现额度使用偏快。
- 展示重置卡数量和到期时间；卡片详情可能由服务器限制。
- 手动重置前二次确认账号、用量、更新时间和卡片有效期。确认后再次核实服务端状态。
- 重置请求先原子落盘，再发送；跨实例文件锁和幂等键用于避免重复消耗。
- 日期、时区、12/24 小时制、数字和百分比遵从系统格式。当前界面以简体中文为主，尚非完整多语言界面。
- 不创建模型会话，不发起推理调用，不通过 AI 定时任务轮询。

## 从源码运行

### 环境

- macOS 14 及以上；目前实际运行验收在本机完成，未做所有系统版本和 Intel 设备兼容性验收。
- 能打开该项目格式的 Xcode；已验证 Xcode 27.1。核心测试需要 Swift 6 及以上。
- 独立安装的 Codex CLI；已验证 `codex-cli 0.163.0`。其他版本需核对 App Server 协议。
- 支持对应额度与重置卡的 ChatGPT 账号；某些字段可能因套餐或服务端状态不可用。

安装 CLI 请参照 [OpenAI Codex 官方文档](https://learn.chatgpt.com/docs/app-server)。应用不会下载或捆绑 CLI。

```sh
git clone https://github.com/aruis/CodexWatcher.git
cd CodexWatcher
open CodexWatcher.xcodeproj
```

在 Xcode 选择 `CodexWatcher` 和 `My Mac` 运行。如果需要签名，选择自己的 Development Team。仓库不包含开发者的签名团队设置。

也可仅验证构建：

```sh
xcodebuild -project CodexWatcher.xcodeproj -scheme CodexWatcher \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/CodexWatcher.app
```

启动后显示独立窗口，同时提供菜单栏入口，不显示 Dock 图标。点击「使用 ChatGPT 连接」，在官方浏览器页面完成登录。默认寻找 `/opt/homebrew/bin/codex` 或 `/usr/local/bin/codex`；其他路径可在齿轮菜单选择。

## 用量口径

```text
周期起点（推算） = 下次重置时间 − 服务器返回的窗口长度
标准用量 = 已过去的周期时间 / 窗口长度 × 100%
偏移 = 实际用量 − 标准用量
```

例如标准用量 13.1%、实际用量 25%，偏移为 **+11.9 个百分点**，表示消耗超前。自然时间包含睡眠和休息时间。

窗口起点由服务器返回值推算，不是服务端明确提供的历史起点。手动重置若保留原窗口终点，基准仍按原窗口计算。缺失窗口长度或已到达重置时间时，不推算偏移。

状态栏保持简洁，显示最近一次成功读取的用量。详细面板显示最后更新时间及数据失效状态；每 5 分钟轮询不等于秒级实时同步。

## 重置卡

数量以服务端 `availableCount` 为准，详情列表可能少于总数。没有到期时间表示「未提供」，不代表永久有效。已知英文卡片名称会本地化，未知名称保持原样。

「使用」只打开二次确认；只有确认「消耗 1 张并重置」才会发起操作。实际可重置范围由服务器决定，可能涵盖当前查看窗口以外的额度。

超时不代表失败。若出现「重试上次重置」，应用会复用原请求标识核实结果。不要删除本地待确认记录或把重试改成全新请求。本项目开发测试**不会消费真实重置卡**。

## 隐私与接入边界

- 独立 `CODEX_HOME`：`~/Library/Application Support/CodexWatcher/Runtime`。
- CLI 使用系统钥匙串保存凭证；不自动降级为明文认证文件。
- 待确认操作存于同级 `State` 目录，包含账号标识、卡片 ID 和幂等键；不含密码或访问令牌。
- CLI 路径、窗口选择保存在本地应用偏好；用量不上传到开发者服务器。
- 连接通过子进程 stdio 完成。官方登录流程的本机回调由 CLI 托管。
- 本应用不记录原始协议、登录 URL 或令牌，并丢弃 CLI 标准错误。CLI 自身产生的本地状态和官方服务的处理行为不由本应用控制。

该接入使用 Codex App Server 账号接口。官方说明对此认证方式的商业或托管使用有约束；MIT 许可证不授予 OpenAI 服务访问权或商业接入许可。商业发行前应重新核对 [官方认证说明](https://learn.chatgpt.com/docs/app-server#auth-endpoints) 和 [Sign in with ChatGPT](https://developers.openai.com/siwc/quickstart)。

## 验证与贡献

```sh
swift test
```

默认测试使用临时文件与本地假服务，不访问真实账号、不运行模型、不触发重置。另有可选的真实 CLI 未登录握手测试：

```sh
WATCHER_LIVE_SMOKE=1 swift test --filter testAppServerHandshake
```

它只启动临时未登录配置，读取账号状态，随后清理，不会登录或重置。请不要在测试里引入真实重置请求。

- [架构与数据流](docs/ARCHITECTURE.md)
- [代码复查与验收范围](docs/REVIEW.md)
- [贡献指南](CONTRIBUTING.md)
- [安全与隐私](SECURITY.md)
- [更新记录](CHANGELOG.md)

代码采用 [MIT License](LICENSE)。OpenAI、ChatGPT 与 Codex 名称及相关商标属于各自权利人。
