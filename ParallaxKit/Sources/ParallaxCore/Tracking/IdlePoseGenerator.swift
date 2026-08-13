import Foundation
import simd

/// 无输入时的自动摆动轨迹。
///
/// 这不是兜底而是首屏：app 打开的瞬间画面就该自己活着。
/// 见 spec §9.2②。
///
/// 用两轴不同周期的李萨如曲线。7.0 / 4.328 其实是有理数（最简分数 875/541），
/// 严格说轨迹会循环，但合成周期长达 ≈3787 秒（约 63 分钟）——
/// 没人会盯着屏幕看一小时，循环在实际使用中不可察觉。
public struct IdlePoseGenerator: Sendable {
    /// 横向与纵向摆幅，米
    public var amplitude: SIMD2<Float>
    /// 虚拟观看距离，米
    public var distance: Float
    /// 横向周期，秒
    public var periodX: TimeInterval
    /// 纵向周期，秒。与 periodX 的比值是有理数，靠合成周期够长（≈3787s）
    /// 避免可察觉的循环，理由见上方类型注释。
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

    /// 相对锚点的摆动偏移，不含锚点本身。t=0 时为零向量（两轴 sin(0)=0）。
    public func offset(at time: TimeInterval) -> SIMD3<Float> {
        let x = amplitude.x * Float(sin(2 * Double.pi * time / periodX))
        let y = amplitude.y * Float(sin(2 * Double.pi * time / periodY))
        return SIMD3(x, y, 0)
    }

    /// 绕指定锚点摆动。这是追踪丢失后该用的形式——
    /// 摆动是对「最后已知眼位」的补充，不是回到屏幕中心重新开始。
    ///
    /// t=0 时精确等于 anchor：接管的瞬间不产生任何位移，
    /// 后续的可见偏移全部来自 offset(at:) 本身，不叠加额外的跳变。
    public func pose(at time: TimeInterval, around anchor: SIMD3<Float>) -> SIMD3<Float> {
        anchor + offset(at: time)
    }

    /// 既有形式：绕默认锚点（屏幕正前方 distance 处）摆动。
    public func pose(at time: TimeInterval) -> SIMD3<Float> {
        pose(at: time, around: SIMD3(0, 0, distance))
    }
}
