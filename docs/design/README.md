# 应用图标

[返回 README](../../README.md)

<img src="app-icon-macos.png" alt="macOS 应用图标" width="128" height="128">

## 素材

| 素材 | 用途 |
| --- | --- |
| [1024 × 1024 方形原稿](app-icon-1024.png) | 完整直角、不透明，适合重新裁切或派生 |
| [macOS 预览 PNG](app-icon-macos.png) | 256 × 256，带圆角和透明留白，用于项目文档 |
| [AppIcon 资源](../../CodexWatcher/Assets.xcassets/AppIcon.appiconset) | macOS 应用各尺寸图标 |
| [AppBrand 资源](../../CodexWatcher/Assets.xcassets/AppBrand.imageset) | 面板标题图标 |

原稿由 GPT Image 辅助生成，再导出为 1024 × 1024 PNG。衍生资源与代码一同保存在仓库，按项目 MIT 许可证提供。

C 形仪表呼应 Codex 的首字母，右侧开口。青绿与琥珀色的目标比例约为 65:35，指针约朝向 10 点钟，分别表达用量与时间两个维度。生成图的比例是近似的品牌设计，不代表账号实时数据。

## 资源生成

在 macOS 上运行，无需第三方依赖：

```sh
xcrun swift scripts/generate-app-icons.swift
```

- `CodexWatcher/Assets.xcassets/AppIcon.appiconset`：macOS 所需的 16、32、128、256、512pt，分别包含 1× 和 2×，共 10 项。导出时添加透明留白与圆角；原稿不变。
- `CodexWatcher/Assets.xcassets/AppBrand.imageset`：面板标题使用的 64pt、1×/2× 方形资源，圆角由 SwiftUI 控制。

Xcode 的 Debug 和 Release 都通过 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 指定应用图标。应用为菜单栏工具，不常驻 Dock；应用图标主要用于 Finder、系统应用列表等位置。状态栏继续使用适合小尺寸及系统深浅背景的单色模板图标，并保留用户图标选项。

更换设计时替换方形原稿、重新运行脚本，并检查 Release 构建及大小图显示。生成后的资源随源码提交，普通构建无需额外运行脚本。

脚本也会更新本页及 README 使用的 `app-icon-macos.png`。
