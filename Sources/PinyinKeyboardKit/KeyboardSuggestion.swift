/// 由宿主注入、在「没有拼写」时显示在候选条上的建议。
///
/// 对应系统英文键盘预测条上的三条预测：等宽平铺，点击后交给
/// `PinyinKeyboardViewController.didSelectSuggestion(_:)` 处理。
public struct KeyboardSuggestion: Equatable, Sendable {
    /// 稳定标识。内容签名用它判断候选条是否需要重建。
    public let id: String
    public let text: String
    /// 读屏标签；为空时用 `text`。
    public let accessibilityLabel: String?

    public init(id: String, text: String, accessibilityLabel: String? = nil) {
        self.id = id
        self.text = text
        self.accessibilityLabel = accessibilityLabel
    }
}
