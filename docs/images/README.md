# 界面预览素材

[返回 README](../../README.md)

这些 PNG 由当前应用的 SwiftUI / AppKit 视图直接渲染，不是 AI 效果图。账号 `demo@example.com`、套餐、额度及重置卡均为虚构演示数据；日期随生成时间更新。它们用于展示界面，不代表特定账号权益。

| 文件 | 内容 |
| --- | --- |
| [dashboard-light.png](dashboard-light.png) | 亮色面板 |
| [dashboard-dark.png](dashboard-dark.png) | 暗色面板 |
| [dashboard-trend-full-light.png](dashboard-trend-full-light.png) | 点击进度区域切换后的趋势视图与重置卡（亮色，拉高窗口展示） |
| [dashboard-trend-full-dark.png](dashboard-trend-full-dark.png) | 切换后的趋势视图（暗色，拉高窗口展示） |
| [usage-trend-light.png](usage-trend-light.png) | 剩余额度历史、走势范围与预测耗尽时间（亮色） |
| [usage-trend-dark.png](usage-trend-dark.png) | 剩余额度历史与预测（暗色） |
| [dashboard-pro-short-only.png](dashboard-pro-short-only.png) | Pro 仅返回短周期额度，不显示 7 天窗口 |
| [menu-bar-settings.png](menu-bar-settings.png) | 状态栏设置与数值预览 |
| [reset-confirmation.png](reset-confirmation.png) | 重置确认页 |
| [credit-expiry-reminder.png](credit-expiry-reminder.png) | 临期处理的提醒模式 |
| [credit-expiry-automatic.png](credit-expiry-automatic.png) | 临期处理的自动模式 |
| [automatic-hello-off.png](automatic-hello-off.png) | 满额自动 hello 默认关闭 |
| [automatic-hello-on.png](automatic-hello-on.png) | 满额自动 hello 开启后绑定账号和窗口；不实际发起问候 |
| [dashboard-offline.png](dashboard-offline.png) | 读取失败，保留上次用量及只读恢复入口 |
| [dashboard-compact.png](dashboard-compact.png) | 紧凑高度，内容滚动且保留头部与底栏 |
| [dashboard-expanded.png](dashboard-expanded.png) | 调整独立窗口后的宽布局 |
| [welcome.png](welcome.png) | 未登录界面 |

## 重新生成

在 macOS 上，从仓库根目录执行：

```sh
bash scripts/generate-screenshots.sh
```

可传入输出目录以生成临时预览：`bash scripts/generate-screenshots.sh /tmp/WatcherPreview`。

需要 Xcode 工具链，不需要 Codex CLI 或账号。脚本编译独立文档预览程序，使用临时 Runtime 和独立偏好；假服务仅响应初始化及读取，拒绝其他方法。确认页按钮为空操作；临期配置仅操作演示偏好，通知权限由假回调提供，不发送系统通知、不启动定时检查。退出后清理临时程序、数据和偏好，不影响正式应用。

预览按 2× 分辨率导出，使用简体中文和 Asia/Shanghai 时区；正式应用仍遵从用户地区设置。图片不含系统菜单栏、桌面或真实账号截图。界面改变后应重新生成并逐张检查排版。
