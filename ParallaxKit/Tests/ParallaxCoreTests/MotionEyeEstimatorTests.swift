import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("MotionEyeEstimator")
struct MotionEyeEstimatorTests {

    // MARK: - 核心契约：接管瞬间不跳变

    @Test("reference == current 时返回精确零向量")
    func referenceEqualsCurrentReturnsExactZero() {
        let q = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.3, 1, -0.2)))
        let offset = MotionEyeEstimator.offset(from: q, to: q, distance: 0.35)
        #expect(offset == SIMD3<Float>(0, 0, 0))
    }

    @Test("reference == current 对任意 distance/sensitivity 组合都返回精确零向量")
    func referenceEqualsCurrentIsZeroRegardlessOfParameters() {
        let q = simd_quatf(angle: -1.2, axis: SIMD3<Float>(1, 0, 0))
        for distance: Float in [0.1, 0.35, 1.5] {
            for sensitivity: Float in [0, 0.5, 1, 2] {
                let offset = MotionEyeEstimator.offset(from: q, to: q, distance: distance, sensitivity: sensitivity)
                #expect(offset == SIMD3<Float>(0, 0, 0),
                        "distance=\(distance) sensitivity=\(sensitivity) 时应精确为零，实际 \(offset)")
            }
        }
    }

    // MARK: - 方向约定
    //
    // 推导（simd_quatf 组合遵循 (p*q).act(v) == p.act(q.act(v))，即先作用 q 再作用 p；
    // 屏幕坐标系见 ScreenGeometry：X 右、Y 上、Z 指向观察者，右手系）：
    //
    // 用 Rodrigues 公式验证 simd_quatf(angle: θ, axis: [0,1,0])（θ>0）把 +Z 轴（设备前向，
    // 指向观察者）转向 +X（设备自身右侧）——这正是「设备向右转」（绕竖直轴向右转，
    // 类似摇头看向右边）。reference 取单位元、current 取该旋转、sensitivity=1 时：
    // delta = current，scaledDelta = current，作用的是逆旋转，即把参考位置
    // (0,0,distance) 绕 Y 轴转 −θ。代入 Rodrigues 公式算出 x 分量 = distance·sin(−θ) < 0。
    // 与任务给出的方向约定（"设备向右转 → 观察者等效在左侧 → x 为负"）一致。
    //
    // 同样方法验证绕 X 轴：simd_quatf(angle: θ, axis: [1,0,0])（θ>0）把屏幕法线 +Z
    // 转向 −Y（顶部后仰、远离观察者，法线转为朝下）。代入同样的推导，作用 −θ 得到
    // y 分量 = distance·sin(θ) > 0——顶部后仰时观察者等效位置在上方。

    @Test("绕 Y 轴转动：设备向右转（前向转向设备自身 +X），观察者等效在左侧，x 分量为负")
    func rotatingRightAboutYGivesNegativeX() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 1, 0))
        let offset = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.35, sensitivity: 1.0)
        #expect(offset.x < 0, "期望 x < 0，实际 offset=\(offset)")
        #expect(abs(offset.y) < 1e-6)
    }

    @Test("绕 X 轴转动：设备顶部后仰远离观察者（屏幕法线转向 −Y），观察者等效在上方，y 分量为正")
    func tiltingTopAwayAboutXGivesPositiveY() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        let current = simd_quatf(angle: 0.3, axis: SIMD3<Float>(1, 0, 0))
        let offset = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.35, sensitivity: 1.0)
        #expect(offset.y > 0, "期望 y > 0，实际 offset=\(offset)")
        #expect(abs(offset.x) < 1e-6)
    }

    // MARK: - sensitivity

    @Test("sensitivity = 0 时恒为零向量")
    func zeroSensitivityAlwaysZero() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let currents: [simd_quatf] = [
            simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0)),
            simd_quatf(angle: 1.1, axis: SIMD3<Float>(1, 0, 0)),
            simd_quatf(angle: 2.0, axis: simd_normalize(SIMD3<Float>(1, 1, 1))),
        ]
        for current in currents {
            let offset = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.35, sensitivity: 0)
            #expect(simd_length(offset) < 1e-5, "sensitivity=0 时应恒为零向量，实际 \(offset)")
        }
    }

    @Test("sensitivity 越大，位移幅度越大")
    func largerSensitivityGivesLargerMagnitude() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: 0.5, axis: SIMD3<Float>(0, 1, 0))
        let small = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.35, sensitivity: 0.2)
        let large = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.35, sensitivity: 0.8)
        #expect(simd_length(large) > simd_length(small),
                "large=\(simd_length(large)) 应大于 small=\(simd_length(small))")
    }

    // MARK: - distance 线性缩放

    @Test("位移幅度随 distance 线性缩放")
    func magnitudeScalesLinearlyWithDistance() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: 0.35, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.1)))
        let base = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.2, sensitivity: 0.6)
        let scaled = MotionEyeEstimator.offset(from: reference, to: current, distance: 0.8, sensitivity: 0.6)
        // 先确认 base 本身不是退化的零向量——否则下面「scaled ≈ base*4」会被
        // 「零缩放 4 倍还是零」这种退化情况蒙混过去，测不出真正的线性缩放关系。
        #expect(simd_length(base) > 1e-4, "base=\(base) 不应接近零向量，否则测不出线性缩放")
        // distance 从 0.2 到 0.8，是 4 倍。
        #expect(simd_length(scaled - base * 4) < 1e-4,
                "base=\(base) scaled=\(scaled)，scaled 应约等于 base*4")
    }

    // MARK: - 安全性：非法 / 非有限 / 退化输入

    @Test("distance <= 0 安全返回零向量")
    func nonPositiveDistanceReturnsZero() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))
        for distance: Float in [0, -0.1, -5] {
            let offset = MotionEyeEstimator.offset(from: reference, to: current, distance: distance, sensitivity: 0.5)
            #expect(offset == SIMD3<Float>(0, 0, 0), "distance=\(distance) 应返回零向量，实际 \(offset)")
        }
    }

    @Test("非有限四元数分量不产生 NaN")
    func nonFiniteQuaternionStaysFinite() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let nanCurrent = simd_quatf(vector: SIMD4<Float>(Float.nan, 0, 0, 1))
        let infReference = simd_quatf(vector: SIMD4<Float>(0, 0, 0, Float.infinity))

        let offset1 = MotionEyeEstimator.offset(from: reference, to: nanCurrent, distance: 0.35)
        #expect(offset1.x.isFinite && offset1.y.isFinite && offset1.z.isFinite)

        let offset2 = MotionEyeEstimator.offset(from: infReference, to: reference, distance: 0.35)
        #expect(offset2.x.isFinite && offset2.y.isFinite && offset2.z.isFinite)
    }

    @Test("退化（零长度）四元数不产生 NaN")
    func degenerateZeroQuaternionStaysFinite() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let zeroQuat = simd_quatf(vector: SIMD4<Float>(0, 0, 0, 0))
        let offset = MotionEyeEstimator.offset(from: reference, to: zeroQuat, distance: 0.35)
        #expect(offset.x.isFinite && offset.y.isFinite && offset.z.isFinite)
    }

    @Test("非归一化（但有限、非零）四元数安全返回有限值")
    func nonNormalizedFiniteQuaternionStaysFinite() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        // 长度 sqrt(0.36+2.56) ≈ 1.71，模拟传感器融合累积误差之类的场景。
        let denormalizedCurrent = simd_quatf(vector: SIMD4<Float>(0, 0.6, 0, 1.6))
        let offset = MotionEyeEstimator.offset(from: reference, to: denormalizedCurrent, distance: 0.35)
        #expect(offset.x.isFinite && offset.y.isFinite && offset.z.isFinite)
    }

    @Test("非有限 sensitivity 与极小旋转量不产生 NaN")
    func nonFiniteSensitivityAndTinyRotationStayFinite() {
        let reference = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0))

        let offsetNaNSensitivity = MotionEyeEstimator.offset(
            from: reference, to: current, distance: 0.35, sensitivity: .nan
        )
        #expect(offsetNaNSensitivity == SIMD3<Float>(0, 0, 0))

        // 极小但非零的旋转量：reference 与 current 几乎重合时 slerp 容易数值不稳定，
        // 这里确认不产生 NaN（这条不测方向/幅度，只测「不炸」）。
        let tinyCurrent = simd_quatf(angle: 1e-6, axis: SIMD3<Float>(0, 1, 0))
        let offsetTiny = MotionEyeEstimator.offset(from: reference, to: tinyCurrent, distance: 0.35)
        #expect(offsetTiny.x.isFinite && offsetTiny.y.isFinite && offsetTiny.z.isFinite)
    }
}
