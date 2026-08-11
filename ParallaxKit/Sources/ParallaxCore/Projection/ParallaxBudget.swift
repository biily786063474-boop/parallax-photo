import Foundation
import simd

/// 视差预算：把眼位软性夹进一个不会暴露遮挡空洞的舒适锥内。
///
/// 侧头角度越大，被遮挡区域露出的空洞越大。与其等空洞穿帮，
/// 不如在数学层面就把眼位限制住——用户感受应该是「到边了」，而不是「卡住了」。
/// 所以衰减必须一阶连续，这一点由测试强制。
public struct ParallaxBudget: Sendable {
    /// 线性区半径，米。此范围内眼位原样通过。
    public var linearRadius: Float
    /// 渐近上限，米。横向偏移永不超过此值。
    public var maxRadius: Float
    /// 合法观看距离区间，米。
    public var distanceRange: ClosedRange<Float>

    public init(
        linearRadius: Float = 0.06,
        maxRadius: Float = 0.12,
        distanceRange: ClosedRange<Float> = 0.15...0.80
    ) {
        self.linearRadius = linearRadius
        self.maxRadius = maxRadius
        self.distanceRange = distanceRange
    }

    /// 软性饱和函数。
    ///
    /// - `x ≤ linear` 时恒等通过
    /// - `x > linear` 时用 tanh 平滑饱和到 `max`
    ///
    /// 在 `x = linear` 处函数值与一阶导数都连续（tanh'(0) = 1）。
    public static func softClamp(_ x: Float, linear: Float, max maximum: Float) -> Float {
        guard x.isFinite else { return 0 }
        guard x > linear else { return x }
        let span = maximum - linear
        guard span > 0 else { return linear }
        return linear + span * tanh((x - linear) / span)
    }

    public func clamp(_ eye: SIMD3<Float>) -> SIMD3<Float> {
        let lateral = SIMD2(
            eye.x.isFinite ? eye.x : 0,
            eye.y.isFinite ? eye.y : 0
        )
        let radius = simd_length(lateral)

        // 径向夹紧而非分轴夹紧：分轴会产生方形边界，对角方向能跑得比轴向更远，
        // 用户会感觉「斜着动能看得更多」，很怪。
        let clampedRadius = Self.softClamp(radius, linear: linearRadius, max: maxRadius)
        let scaled = radius > 1e-9 ? lateral * (clampedRadius / radius) : lateral

        let rawDistance = eye.z.isFinite ? eye.z : distanceRange.lowerBound
        let distance = min(max(rawDistance, distanceRange.lowerBound), distanceRange.upperBound)

        return SIMD3(scaled.x, scaled.y, distance)
    }
}
