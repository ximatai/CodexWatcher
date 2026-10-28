# 界面翻译

`CodexWatcher/Localizable.xcstrings` 是翻译的唯一维护入口。现有文案以简体中文为源语言，提供英文翻译；应用保留英文开发语言作为未支持语言的回退。日期、时间、百分比的地区格式与界面语言分别处理。

SwiftUI 中固定文本直接使用字符串字面量。需要在枚举、业务状态、AppKit 或通知中传递的文案使用 `String.LocalizationValue`，在显示边界通过 `L10n.text` 解析；不要先拼接为普通 `String`，再将其当作翻译键。插值保留原始类型，数量使用整数以支持 String Catalog 的复数变化。用户内容、未知服务端卡片名称及协议标识按原值显示；错误码以 `String(code)` 插值，避免千位分隔符。

`L10n.text` 默认遵循应用语言；显式 locale 用于界面预览与测试，通过 Foundation 的语言匹配选择资源，不自行规定支持语言分支。保留 `PresentationFormat` 对地区和时区的显式注入。

修改目录后执行：

```sh
python3 scripts/compile-localizations.py
python3 scripts/compile-localizations.py --check
swift test
```

`PackageLocalization` 是 Apple `xcstringstool` 编译生成的 SwiftPM 兼容资源，请勿手改。Xcode 直接编译 String Catalog，并排除 `.strings` / `.stringsdict` 输入，避免重复打包。预览脚本也直接编译目录。CI 检查兼容资源与目录一致、编译器提取的每个键均有完整中英文翻译，并以中英文运行隔离界面检查。

保留 Xcode 文案提取，新增本地化字面量可自动进入目录。暂不使用 Xcode 生成的 Swift 符号，以便 Xcode、SwiftPM 和直接 swiftc 的预览共用源码；枚举标题与动态文案仍由 Swift 本地化值类型检查。既有相近中文键还会产生同名符号，后续如引入符号需统一命名后再开启。

## 术语与翻译上下文

- 额度：quota；重置卡：reset credit；参考进度：reference pace；用量偏移：usage deviation。
- “重置”指服务端恢复额度，可能消耗重置卡；不能翻译为刷新或重新读取。
- “待核实”表示消费结果未知，不表示消费失败。不得承诺重试一定不消耗卡片。
- 保留 Codex、ChatGPT、CLI、hello 等产品名与协议文本。
- 修改涉及消费、自动执行、不可撤销或重试的警示时，中英文必须表达同一约束。

预览使用虚构数据，检查英文长文本、按钮宽度、临期标记、未决重置和设置项。新增语言需翻译完整目录，并验证目标语言的布局和复数规则；自动检查不能代替母语审校。
