import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("ParallaxBudget")
struct ParallaxBudgetTests {

    static let budget = ParallaxBudget(
        linearRadius: 0.06, maxRadius: 0.12, distanceRange: 0.15...0.80
    )

    @Test("线性区内原样通过", arguments: [Float(0), 0.01, 0.03, 0.059])
    func insideLinearRegionIsIdentity(_ r: Float) {
        #expect(abs(ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12) - r) < 1e-6)
    }

    @Test("超出线性区后被压缩，且在浮点可分辨范围内严格递增")
    func beyondLinearRegionIsCompressedAndMonotonic() {
        // tanh 渐近饱和：过了某点，相邻步长带来的增量会落到 Float 精度以下，
        // 输出停在上限不再变化——那是设计意图，不是缺陷。
        // 实测在 max=0.12 时 r≈0.52 起增量就归零了（ULP(0.12)=7.45e-9）。
        // 所以严格递增只在 r ≤ 0.40 内断言，那里增量仍有 ULP 的 55 倍余量。
        var previous = ParallaxBudget.softClamp(0.06, linear: 0.06, max: 0.12)
        for step in 1...34 {
            let r = 0.06 + Float(step) * 0.01   // 0.07 ... 0.40
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out > previous, "在 r=\(r) 处不再严格递增")
            #expect(out < r, "在 r=\(r) 处没有被压缩")
            previous = out
        }
    }

    @Test("饱和区单调不减且永不越限")
    func saturationRegionIsNonDecreasingAndBounded() {
        // 饱和之后允许输出持平，但绝不允许回退或越界。
        // 这条和上一条合起来才是完整的单调性契约：
        // 可分辨区严格递增，饱和区不回退不越限。
        var previous = ParallaxBudget.softClamp(0.40, linear: 0.06, max: 0.12)
        for step in 1...100 {
            let r = 0.40 + Float(step) * 0.05   // 0.45 ... 5.40
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out >= previous, "在 r=\(r) 处回退：\(out) < \(previous)")
            #expect(out <= 0.12 + 1e-6, "在 r=\(r) 处越限：\(out)")
            previous = out
        }
    }

    @Test("永远不超过渐近上限")
    func neverExceedsMaximum() {
        for r in stride(from: Float(0), through: 100, by: 0.5) {
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out <= 0.12 + 1e-6, "r=\(r) 时输出 \(out) 超过上限")
            #expect(out.isFinite)
        }
    }

    @Test("在线性区边界处一阶连续")
    func derivativeIsContinuousAtBoundary() {
        let boundary: Float = 0.06
        let h: Float = 1e-4
        func derivative(at x: Float) -> Float {
            let a = ParallaxBudget.softClamp(x - h, linear: boundary, max: 0.12)
            let b = ParallaxBudget.softClamp(x + h, linear: boundary, max: 0.12)
            return (b - a) / (2 * h)
        }
        let inside = derivative(at: boundary - 5 * h)
        let outside = derivative(at: boundary + 5 * h)
        // 两侧导数都应接近 1，且彼此接近
        #expect(abs(inside - 1) < 0.05, "线性区内导数应为 1，实为 \(inside)")
        #expect(abs(inside - outside) < 0.05, "边界两侧导数跳变：\(inside) vs \(outside)")
    }

    @Test("径向夹紧保持方向不变")
    func clampPreservesDirection() {
        let eye = SIMD3<Float>(0.3, 0.4, 0.3)   // 横向模长 0.5，远超上限
        let clamped = Self.budget.clamp(eye)
        let originalDirection = simd_normalize(SIMD2(eye.x, eye.y))
        let clampedDirection = simd_normalize(SIMD2(clamped.x, clamped.y))
        #expect(simd_length(originalDirection - clampedDirection) < 1e-5)
    }

    @Test("对角方向与轴向受到同等限制（径向而非方形边界）")
    func clampIsRadialNotRectangular() {
        let alongAxis = Self.budget.clamp(SIMD3(1.0, 0, 0.3))
        let diagonal = Self.budget.clamp(SIMD3(0.7071, 0.7071, 0.3))
        let axisLength = simd_length(SIMD2(alongAxis.x, alongAxis.y))
        let diagonalLength = simd_length(SIMD2(diagonal.x, diagonal.y))
        #expect(abs(axisLength - diagonalLength) < 1e-4,
                "轴向 \(axisLength) 与对角 \(diagonalLength) 受限不一致，说明是方形边界")
    }

    @Test("观看距离被夹进合法区间")
    func distanceIsClampedToRange() {
        #expect(Self.budget.clamp(SIMD3(0, 0, 0.05)).z == 0.15)
        #expect(Self.budget.clamp(SIMD3(0, 0, 5.0)).z == 0.80)
        #expect(Self.budget.clamp(SIMD3(0, 0, 0.35)).z == 0.35)
    }

    @Test("零向量与非有限输入不产生 NaN")
    func degenerateInputIsSafe() {
        let zero = Self.budget.clamp(SIMD3(0, 0, 0.3))
        #expect(zero.x == 0 && zero.y == 0)
        let nan = Self.budget.clamp(SIMD3(.nan, .nan, .nan))
        #expect(nan.x.isFinite && nan.y.isFinite && nan.z.isFinite)
    }
}
