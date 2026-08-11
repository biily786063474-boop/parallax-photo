import Testing
import simd
@testable import ParallaxCore

@Suite("OffAxisProjection")
struct OffAxisProjectionTests {

    static let screen = ScreenGeometry(
        width: 0.07123, height: 0.15437, cameraOffset: .zero
    )
    static let near: Float = 0.01
    static let far: Float = 10.0

    /// 覆盖正前方、四个侧向偏移、远近距离的代表性眼位
    static let eyePositions: [SIMD3<Float>] = [
        SIMD3(0, 0, 0.30),
        SIMD3(0.05, 0, 0.30),
        SIMD3(-0.05, 0, 0.30),
        SIMD3(0, 0.08, 0.30),
        SIMD3(0, -0.08, 0.30),
        SIMD3(0.04, -0.06, 0.22),
        SIMD3(-0.03, 0.05, 0.55)
    ]

    private static func project(_ point: SIMD3<Float>, _ m: simd_float4x4) -> SIMD3<Float> {
        let clip = m * SIMD4<Float>(point, 1)
        return SIMD3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    @Test("屏幕四角精确映射到 NDC 边界", arguments: eyePositions)
    func screenCornersMapToNDCEdges(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let expectations: [(SIMD3<Float>, SIMD2<Float>)] = [
            (Self.screen.bottomLeft,  SIMD2(-1, -1)),
            (Self.screen.bottomRight, SIMD2( 1, -1)),
            (Self.screen.topLeft,     SIMD2(-1,  1)),
            (Self.screen.topRight,    SIMD2( 1,  1))
        ]
        for (corner, expected) in expectations {
            let ndc = Self.project(corner, m)
            #expect(abs(ndc.x - expected.x) < 1e-4,
                    "眼位 \(eye) 下角点 \(corner) 的 NDC.x = \(ndc.x)，应为 \(expected.x)")
            #expect(abs(ndc.y - expected.y) < 1e-4,
                    "眼位 \(eye) 下角点 \(corner) 的 NDC.y = \(ndc.y)，应为 \(expected.y)")
        }
    }

    @Test("眼位在正前方时退化为对称视锥")
    func centeredEyeGivesSymmetricFrustum() {
        let m = OffAxisProjection.matrix(
            eye: SIMD3(0, 0, 0.3), screen: Self.screen, near: Self.near, far: Self.far
        )
        // 对称视锥的特征：第三列的 x、y 分量为 0（无偏斜）
        #expect(abs(m.columns.2.x) < 1e-6)
        #expect(abs(m.columns.2.y) < 1e-6)
    }

    @Test("离轴投影产生真实视差：屏幕前后的点朝相反方向移动")
    func offAxisProducesOppositeParallax() {
        // 这条测试守护的是离轴投影存在的理由。
        // 简单平移会让所有点同向移动等量；只有真正的离轴视锥
        // 才会让屏幕平面前后的点朝相反方向偏移——那就是视差。
        let centeredEye = SIMD3<Float>(0, 0, 0.3)
        let leftEye = SIMD3<Float>(-0.05, 0, 0.3)
        let behindScreen = SIMD3<Float>(0, 0, -0.1)   // 屏幕后方，远离观察者
        let inFrontOfScreen = SIMD3<Float>(0, 0, 0.1) // 屏幕前方，靠近观察者

        let centered = OffAxisProjection.matrix(
            eye: centeredEye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let shifted = OffAxisProjection.matrix(
            eye: leftEye, screen: Self.screen, near: Self.near, far: Self.far
        )

        // 眼位居中时，屏幕轴线上的点都投在画面正中
        #expect(abs(Self.project(behindScreen, centered).x) < 1e-5)
        #expect(abs(Self.project(inFrontOfScreen, centered).x) < 1e-5)

        // 眼位左移后：后方的点向左偏，前方的点向右偏
        let behindShift = Self.project(behindScreen, shifted).x
        let frontShift = Self.project(inFrontOfScreen, shifted).x
        #expect(behindShift < -0.01, "屏幕后方的点未向左偏：\(behindShift)")
        #expect(frontShift > 0.01, "屏幕前方的点未向右偏：\(frontShift)")
        // 两者必须反向——这是视差的本质，不是幅度差异
        #expect(behindShift * frontShift < 0, "前后景未朝相反方向移动，这不是真视差")
    }

    @Test("屏幕中心恒映射到 NDC 原点，与眼位无关", arguments: eyePositions)
    func screenCenterIsInvariant(_ eye: SIMD3<Float>) {
        // 四角映射到 NDC 的 ±1，中心作为四角中点必然映射到 0。
        // 这不是巧合，是离轴投影的定义决定的。
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let ndc = Self.project(SIMD3<Float>(0, 0, 0), m)
        #expect(abs(ndc.x) < 1e-5, "眼位 \(eye) 下屏幕中心 x 偏移了 \(ndc.x)")
        #expect(abs(ndc.y) < 1e-5, "眼位 \(eye) 下屏幕中心 y 偏移了 \(ndc.y)")
    }

    @Test("近平面映射到 0，远平面映射到 1（Metal 深度约定）")
    func metalDepthRange() {
        let eye = SIMD3<Float>(0, 0, 0.3)
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        // 眼前方 near 处与 far 处的点（屏幕坐标系中 Z 指向用户，故沿 -Z 远离）
        let atNear = SIMD3(eye.x, eye.y, eye.z - Self.near)
        let atFar = SIMD3(eye.x, eye.y, eye.z - Self.far)
        #expect(abs(Self.project(atNear, m).z - 0) < 1e-4)
        #expect(abs(Self.project(atFar, m).z - 1) < 1e-4)
    }

    @Test("屏幕平面上的点深度落在 [0,1] 内", arguments: eyePositions)
    func screenPlaneDepthInRange(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let z = Self.project(SIMD3(0, 0, 0), m).z
        #expect(z > 0 && z < 1, "屏幕平面深度 \(z) 落在 [0,1] 之外")
    }

    @Test("矩阵元素全部有限", arguments: eyePositions)
    func matrixIsFinite(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            for value in [column.x, column.y, column.z, column.w] {
                #expect(value.isFinite, "矩阵含非有限值：\(value)")
            }
        }
    }

    @Test("眼位贴到屏幕平面上不产生 NaN")
    func degenerateEyeDistanceIsSafe() {
        let m = OffAxisProjection.matrix(
            eye: SIMD3(0, 0, 0), screen: Self.screen, near: Self.near, far: Self.far
        )
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            for value in [column.x, column.y, column.z, column.w] {
                #expect(value.isFinite, "退化眼位产生了非有限值：\(value)")
            }
        }
    }
}
