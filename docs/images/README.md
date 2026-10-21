# 界面预览素材

[返回 README](../../README.md)

这些 PNG 由当前应用的 SwiftUI / AppKit 视图直接渲染，不是 AI 效果图。账号 `demo@example.com`、套餐、额度及重置卡均为虚构演示数据；日期随生成时间更新。它们用于展示界面，不代表特定账号权益。

| 文件 | 内容 |
| --- | --- |
| [dashboard-light.png](dashboard-light.png) | 亮色面板 |
| [dashboard-dark.png](dashboard-dark.png) | 暗色面板 |
| [menu-bar-settings.png](menu-bar-settings.png) | 状态栏设置与数值预览 |
| [reset-confirmation.png](reset-confirmation.png) | 重置确认页 |

## 重新生成

在 macOS 上，从仓库根目录执行：

```sh
bash scripts/generate-screenshots.sh
```

需要 Xcode 工具链，不需要 Codex CLI 或账号。脚本编译独立文档预览程序，使用临时 Runtime 和独立偏好；假服务仅响应初始化及读取，拒绝其他方法。确认页按钮为空操作。退出后清理临时程序、数据和偏好，不影响正式应用。

预览按 2× 分辨率导出，使用简体中文和 Asia/Shanghai 时区；正式应用仍遵从用户地区设置。图片不含系统菜单栏、桌面或真实账号截图。界面改变后应重新生成并逐张检查排版。
