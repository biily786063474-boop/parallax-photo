import Testing
import Foundation

/// 这条测试守护 spec §5.2 的依赖规则。它一旦变红，说明有人把平台框架带进了纯逻辑层，
/// 而那会立刻让整个 Core 无法在 Mac 上测试。
@Test("ParallaxCore 不得依赖任何平台框架")
func coreHasNoPlatformImports() throws {
    let forbidden = [
        "ARKit", "Metal", "MetalKit", "UIKit", "AppKit",
        "SwiftUI", "AVFoundation", "Photos", "CoreMotion"
    ]

    // 本文件位于 ParallaxKit/Tests/ParallaxCoreTests/ArchitectureTests.swift
    // 上溯三层得到 ParallaxKit/
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDir = packageRoot.appending(path: "Sources/ParallaxCore")

    let swiftFiles = try FileManager.default
        .subpathsOfDirectory(atPath: sourcesDir.path)
        .filter { $0.hasSuffix(".swift") }

    #expect(!swiftFiles.isEmpty, "没找到任何源文件，说明路径推导错了：\(sourcesDir.path)")

    for relativePath in swiftFiles {
        let content = try String(
            contentsOf: sourcesDir.appending(path: relativePath),
            encoding: .utf8
        )
        for framework in forbidden {
            #expect(
                !content.contains("import \(framework)"),
                "\(relativePath) 违规 import 了 \(framework)"
            )
        }
    }
}
