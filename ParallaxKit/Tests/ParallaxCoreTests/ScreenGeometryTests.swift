import Testing
import simd
@testable import ParallaxCore

@Suite("ScreenGeometry")
struct ScreenGeometryTests {

    /// iPhone 14 Pro Max 的推算值：2796x1290 @460ppi
    static let iPhone14ProMax = ScreenGeometry(
        width: 0.07123,
        height: 0.15437,
        cameraOffset: SIMD3(0.005, 0.06719, 0)
    )

    @Test("四角坐标关于中心对称")
    func cornersAreSymmetric() {
        let g = Self.iPhone14ProMax
        #expect(g.bottomLeft.x == -g.width / 2)
        #expect(g.bottomLeft.y == -g.height / 2)
        #expect(g.topRight.x == g.width / 2)
        #expect(g.topRight.y == g.height / 2)
        // 屏幕平面就是 z = 0
        #expect(g.bottomLeft.z == 0)
        #expect(g.topRight.z == 0)
    }

    @Test("四角构成平行四边形")
    func cornersFormParallelogram() {
        let g = Self.iPhone14ProMax
        let fromBottomLeft = g.topRight - g.bottomLeft
        let viaOtherCorners = (g.bottomRight - g.bottomLeft) + (g.topLeft - g.bottomLeft)
        #expect(simd_length(fromBottomLeft - viaOtherCorners) < 1e-6)
    }

    @Test("不旋转时几何不变")
    func identityRotation() {
        let g = Self.iPhone14ProMax
        #expect(g.rotated(.none) == g)
    }

    @Test("顺时针 90 度：宽高交换，顶部摄像头跑到右侧")
    func clockwise90MovesTopCameraToRight() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotatedClockwise90)
        #expect(abs(r.width - g.height) < 1e-6)
        #expect(abs(r.height - g.width) < 1e-6)
        // 原生顶部中央的摄像头，设备顺时针转后应出现在右侧
        #expect(r.cameraOffset.x > 0)
        #expect(abs(r.cameraOffset.x - g.cameraOffset.y) < 1e-6)
        #expect(abs(r.cameraOffset.y + g.cameraOffset.x) < 1e-6)
    }

    @Test("180 度：尺寸不变，偏移取反")
    func halfTurnNegatesOffset() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotated180)
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(abs(r.height - g.height) < 1e-6)
        #expect(abs(r.cameraOffset.x + g.cameraOffset.x) < 1e-6)
        #expect(abs(r.cameraOffset.y + g.cameraOffset.y) < 1e-6)
    }

    @Test("旋转四次回到原样（群性质）")
    func fourQuarterTurnsIsIdentity() {
        let g = Self.iPhone14ProMax
        var r = g
        for _ in 0..<4 { r = r.rotated(.deviceRotatedClockwise90) }
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(abs(r.height - g.height) < 1e-6)
        #expect(simd_length(r.cameraOffset - g.cameraOffset) < 1e-6)
    }

    @Test("顺时针与逆时针互为逆运算")
    func clockwiseAndCounterClockwiseCancel() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotatedClockwise90)
                 .rotated(.deviceRotatedCounterClockwise90)
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(simd_length(r.cameraOffset - g.cameraOffset) < 1e-6)
    }

    @Test("任何旋转都不改变对角线长度", arguments: ScreenRotation.allCases)
    func rotationPreservesDiagonal(_ rotation: ScreenRotation) {
        let g = Self.iPhone14ProMax
        let r = g.rotated(rotation)
        let original = (g.width * g.width + g.height * g.height).squareRoot()
        let rotated = (r.width * r.width + r.height * r.height).squareRoot()
        #expect(abs(original - rotated) < 1e-6)
    }
}
