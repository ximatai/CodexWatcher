# 架构与数据流

## 组件

| 文件 | 职责 |
| --- | --- |
| `MyApp.swift` | SwiftUI 设置场景、原生独立窗口和应用生命周期 |
| `StatusBarController.swift` | 原生状态栏入口、左右键分流、浮层与右键设置菜单 |
| `ContentView.swift` | 用量面板、重置确认、登录与设置入口 |
| `ResetConfirmationView.swift` / `ResetConfirmationContent.swift` | 确认页实时状态校验与分组展示；纯展示组件可用模拟数据预览 |
| `AppTheme.swift` | 亮色 / 暗色语义配色与跟随系统的外观模式 |
| `MenuBarLabelRenderer.swift` | 将图标与用量合成模板图，按 1x / 2x 可见像素对齐 |
| `MenuBarConfiguration.swift` / `MenuBarSettingsView.swift` | 图标和文本组合规则、配置与预览 |
| `UsageMonitor.swift` | 主线程状态、5 分钟轮询、登录事件、重置编排 |
| `AppServerClient.swift` | 子进程、stdio JSON-RPC、握手、超时、断线与通知 |
| `UsageModels.swift` | 可空字段、多个额度桶、窗口计算和卡片状态 |
| `PresentationFormat.swift` | 日期、数字、百分比、时长和已知卡片名称的显示 |
| `ResetAttemptStore.swift` | 本地幂等记录、跨实例锁、原子写入和匹配清理 |

应用没有自建后端，也没有 Swift 包外部依赖。Codex CLI 是用户单独安装的运行依赖。

`UsageMonitor` 支持注入客户端和偏好存储；默认仍使用独立 Runtime 与系统应用偏好。离线编排测试使用临时目录、本地假进程和独立 UserDefaults suite，验证预检与重试流程，不接触真实账号。

状态栏使用单个 `NSStatusItem`：左键打开承载 SwiftUI 面板的 `NSPopover`，右键或 Control 点按打开原生设置菜单。不注册全局鼠标监听。用量与时钟变化通过 Observation 更新标签，偏好修改通过 UserDefaults 通知即时更新；退出时释放监听和状态栏入口。

确认页以不可变的 `ResetConfirmation` 绑定账号键、卡片 ID、原重试键及显示的额度窗口。页面和执行层使用同一确认对象校验，刷新不能将新操作切换为另一笔重试；预检后再次匹配确认对象。新操作通过文件锁内的 `prepareNew` 仅创建新记录，若已有待确认记录则要求重新确认，不自动采用其键。

## 启动与刷新

启动 CLI 子进程 → `initialize` → `initialized` → `account/read` → `account/rateLimits/read`。

浏览器登录调用 `account/login/start`，只打开受支持的官方 HTTPS 主机链接，回调由 CLI 负责。账号通知会触发防抖刷新；进程退出或请求超时会关闭传输，下一次刷新重建。

服务器使用多桶结构时优先解析该结构，避免重复展示历史单桶字段。缺失值保留未知状态，不能当作零用量或没有重置卡。失败时保留旧数据并在面板标记。

## 手动重置

1. 用户选择卡片，展示账号、当前窗口用量、数据更新时间、完整到期时间和不可撤销提示。
2. 用户明确确认；数据失效或卡片不可用时禁用新的重置。
3. 再读取账号和卡片，核对账号身份以及所选卡片，阻止使用过期快照。
4. 在文件锁内创建或读取待确认操作，原子写入卡片 ID 与 UUID。存在其他卡片的未决操作时先阻止并要求核实。
5. 调用 `account/rateLimitResetCredit/consume`。同一次操作的所有重试复用幂等键。
6. 明确结果后仅清除匹配该键的本地操作，再读取用量。迟到的旧结果不能清掉更新的记录。

超时、断线、存储损坏、未知服务端结果均不能自动产生新的重置请求。文件锁仅保护本机记录；服务器幂等语义仍是防止重复消耗的最终保障。

## 格式与安全

额度计算只处理数字和时间戳；本地化仅作用于显示。日期模板使用系统日历顺序、时区和 `j` 小时制，不写死北京时间或 24 小时。

子进程只继承运行、证书和代理相关环境变量，避免 IDE 或终端的 API 密钥覆盖独立登录配置。进程标准错误被丢弃，错误界面不显示原始 JSON-RPC 错误详情。

## 外观

`appearance` 本地偏好在所有面板间共享，支持跟随系统、亮色、暗色。外观由 AppKit 的 `NSApplication.appearance` 统一控制；手动模式设为 Aqua / Dark Aqua，跟随系统时清除应用和窗口覆盖并继承系统动态外观，避免 `preferredColorScheme(nil)` 留下旧状态。颜色由 `AppPalette` 按语义统一提供，不修改 macOS 全局外观。状态栏模板图继续跟随系统菜单栏的明暗，不被面板主题覆盖。
