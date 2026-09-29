# PinyinKeyboardKit

外观与交互对齐 iOS 系统中文键盘的全拼输入法键盘扩展库。纯 UIKit，离线，不需要「完全访问」，没有第三方运行时依赖。

存在的理由：iOS 不允许第三方往系统键盘的候选栏注入内容，想在键盘上显示自己的候选词只能自己做整个键盘。
这个库把「做一个和系统一样的中文键盘」这部分做完，宿主只需要提供候选建议。

## 功能

- 26 键全拼：常驻候选条、首项托底、⌄ 展开完整候选网格；空格/回车选第一个候选
- 拼音显示在候选条左上角的拼音行，按音节分隔（`ni hao`、`t t kai x`、`nv er`、`xi'an`），**不**写入宿主输入框的标记文本
- 整词、整句组合、前缀逐段选词；`v` 代替 `ü`；`'` 分隔音节（在 123 页）
- ⇧ 单击大写一次、双击锁定，大写字母直接上屏英文
- 123 / #+= 符号页；长按 ⌫ 连删；回车标题跟随 `returnKeyType`
- 键位几何按系统键盘截图实测（第二排缩进半键、第三排 ⇧/⌫ 贴边）

## 接入

```swift
// Package.swift 或 Xcode: Add Local Package → PinyinKeyboardKit
// 只需链接到键盘扩展 target。

import PinyinKeyboardKit

final class KeyboardViewController: PinyinKeyboardViewController {
    // 可选：候选条几何。宿主若按键盘区域裁切截图等，应和这里共用同一处常量。
    override var configuration: Configuration {
        Configuration(candidateBarHeight: 44, candidateBarGap: 8)
    }

    // 没有拼写时候选条显示的建议（对应系统英文键盘的三条预测，等宽平铺）。
    override func suggestions() -> [KeyboardSuggestion] {
        [KeyboardSuggestion(id: "1", text: "好的"), KeyboardSuggestion(id: "2", text: "晚点聊")]
    }

    // 点击建议。默认直接插入文字；可覆写做确认、二次点击等逻辑。
    override func didSelectSuggestion(_ suggestion: KeyboardSuggestion) {
        textDocumentProxy.insertText(suggestion.text)
        showMessage("已插入")
    }
}
```

Info.plist 的 `NSExtensionPrincipalClass` 指向这个子类即可。

- `reloadSuggestions()`：建议来源变化时调用；内容签名没变不会重建按钮，可放心定时调用。
- `showMessage(_:duration:)`：在候选条上显示一句提示，到期自动恢复。
- `isComposing`：是否有未上屏的拼音。
- `PinyinInputEngine(dictionaryURL:)`：可换成自己的词库（TSV：`词<TAB>空格分隔全拼<TAB>词频`）。

## 结构

| Target | 内容 | 平台 |
|---|---|---|
| `PinyinEngine` | 词库加载、音节切分、候选计算。线程安全，`prepare()` 可在后台预热 | iOS / macOS |
| `PinyinKeyboardKit` | `PinyinKeyboardViewController`、按键排版、候选网格；重导出 `PinyinEngine` | iOS |

## 测试

```sh
swift test   # 在 macOS 上跑拼音引擎测试
```

## 已知差距

- 没有按键放大预览、按键震动与声音、长按出更多字符
- 词库不支持简拼（`key` 不出「可以」）、模糊音、用户词频学习
- 底排没有 😀 键（键盘扩展调不出系统表情面板）

## 许可

词库派生自 rime-pinyin-simp（上游 Android Pinyin IME，Apache 2.0），见 `Licenses/`。
