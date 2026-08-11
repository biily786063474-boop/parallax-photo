import Foundation
import simd

/// 无输入时的自动摆动轨迹。
///
/// 这不是兜底而是首屏：app 打开的瞬间画面就该自己活着。
/// 见 spec §9.2②。
///
/// 用两轴不同周期的李萨如曲线，周期比取无理数，避免肉眼可察觉的循环。
public struct IdlePoseGenerator: Sendable {
    /// 横向与纵向摆幅，米
    public var amplitude: SIMD2<Float>
    /// 虚拟观看距离，米
    public var distance: Float
    /// 横向周期，秒
    public var periodX: TimeInterval
    /// 纵向周期，秒。与 periodX 的比值取无理数。
    public var periodY: TimeInterval

    public init(
        amplitude: SIMD2<Float> = SIMD2(0.035, 0.022),
        distance: Float = 0.35,
        periodX: TimeInterval = 7.0,
        periodY: TimeInterval = 4.328
    ) {
        self.amplitude = amplitude
        self.distance = distance
        self.periodX = periodX
        self.periodY = periodY
    }

    public func pose(at time: TimeInterval) -> SIMD3<Float> {
        let x = amplitude.x * Float(sin(2 * Double.pi * time / periodX))
        let y = amplitude.y * Float(sin(2 * Double.pi * time / periodY))
        return SIMD3(x, y, distance)
    }
}
