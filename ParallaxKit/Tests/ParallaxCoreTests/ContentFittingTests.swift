import Testing
import simd
@testable import ParallaxCore

@Suite("ContentFitting")
struct ContentFittingTests {

    /// 复用 ScreenGeometryTests 同款 iPhone 14 Pro Max 推算值：竖屏，宽 < 高，
    /// 宽高比约 0.4615——真实照片（尤其 4:3/3:2 横向构图人像）的宽高比通常
    /// 明显比这个大，是本项目里最容易触发变形的组合。
    static let screen = ScreenGeometry(
        width: 0.07123,
        height: 0.15437,
        cameraOffset: .zero
    )

    static var screenAspect: Float { screen.width / screen.height }

    @Test("内容宽高比等于屏幕宽高比时，返回值精确等于屏幕尺寸")
    func matchingAspectReturnsScreenSize() {
        let result = ContentFitting.fillSize(contentAspect: Self.screenAspect, screen: Self.screen)
        #expect(abs(result.x - Self.screen.width) < 1e-6)
        #expect(abs(result.y - Self.screen.height) < 1e-6)
    }

    @Test("内容比屏幕更宽（如 4:3 照片对竖屏）时，高度贴合屏幕、宽度溢出")
    func widerContentFillsHeightAndOverflowsWidth() {
        // 0.75 = 4:3，明显大于 screenAspect(0.4615)
        let result = ContentFitting.fillSize(contentAspect: 0.75, screen: Self.screen)
        #expect(result.y == Self.screen.height)
        #expect(result.x > Self.screen.width)
    }

    @Test("内容比屏幕更窄（更瘦长）时，宽度贴合屏幕、高度溢出")
    func narrowerContentFillsWidthAndOverflowsHeight() {
        // 0.30 明显小于 screenAspect(0.4615)
        let result = ContentFitting.fillSize(contentAspect: 0.30, screen: Self.screen)
        #expect(result.x == Self.screen.width)
        #expect(result.y > Self.screen.height)
    }

    @Test(
        "结果的宽高比恒等于 contentAspect——这是 fill 不变形的核心契约",
        arguments: [Float(0.1), 0.3, 0.4615, 0.5, 0.75, 1.0, 1.3333, 2.0, 5.0]
    )
    func resultAspectMatchesContentAspect(_ contentAspect: Float) {
        let result = ContentFitting.fillSize(contentAspect: contentAspect, screen: Self.screen)
        let resultAspect = result.x / result.y
        #expect(
            abs(resultAspect - contentAspect) < 1e-4,
            "结果宽高比 \(resultAspect) 应等于输入的 contentAspect \(contentAspect)，否则画面就是被拉伸的"
        )
    }

    @Test(
        "退化输入（≤0 或非有限）返回屏幕尺寸而非 NaN",
        arguments: [Float(0), -1, -0.0001, Float.nan, Float.infinity, -Float.infinity]
    )
    func degenerateInputFallsBackToScreenSize(_ contentAspect: Float) {
        let result = ContentFitting.fillSize(contentAspect: contentAspect, screen: Self.screen)
        #expect(result.x == Self.screen.width)
        #expect(result.y == Self.screen.height)
        #expect(result.x.isFinite && result.y.isFinite)
    }
}
