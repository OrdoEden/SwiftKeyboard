// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PinyinKeyboardKit",
    defaultLocalization: "zh-Hans",
    // macOS 只用于在本机跑拼音引擎的单元测试；键盘界面仅 iOS。
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PinyinKeyboardKit", targets: ["PinyinKeyboardKit"]),
        .library(name: "PinyinEngine", targets: ["PinyinEngine"])
    ],
    targets: [
        .target(
            name: "PinyinEngine",
            resources: [.copy("Resources/pinyin.tsv")]
        ),
        .target(name: "PinyinKeyboardKit", dependencies: ["PinyinEngine"]),
        .testTarget(name: "PinyinEngineTests", dependencies: ["PinyinEngine"])
    ],
    swiftLanguageModes: [.v5]
)
