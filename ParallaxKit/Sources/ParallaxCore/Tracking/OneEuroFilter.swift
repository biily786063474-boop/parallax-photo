import Foundation
import simd

/// 一阶低通滤波器。alpha 由调用方按当前采样间隔算好后传入。
struct LowPassFilter {
    private var state: Float?

    /// 上一次的输出。尚未有输出时为 0。
    private(set) var lastOutput: Float = 0

    var hasOutput: Bool { state != nil }

    mutating func filter(_ x: Float, alpha: Float) -> Float {
        let y: Float
        if let previous = state {
            y = alpha * x + (1 - alpha) * previous
        } else {
            y = x
        }
        state = y
        lastOutput = y
        return y
    }
}

/// One Euro Filter（Casiez et al., CHI 2012）。
///
/// 为什么是它：眼位追踪要同时满足两个互相矛盾的要求——静止时要稳（否则画面发抖），
/// 移动时要跟手（否则拖影）。固定截止频率的低通做不到，One Euro 用速度自适应地
/// 调整截止频率解决了这个权衡。
///
/// - 慢速时 cutoff 低 → 强平滑，消抖动
/// - 快速时 cutoff 高 → 弱平滑，低延迟
public struct OneEuroFilter: Sendable {
    /// 最低截止频率（Hz）。越小越稳，也越迟钝。
    public var minCutoff: Float
    /// 速度对截止频率的影响系数。**米制下的量纲与原论文的像素制不同**，见 Task 2 说明。
    public var beta: Float
    /// 速度估计本身的截止频率（Hz）。
    public var derivativeCutoff: Float

    private var valueFilter = LowPassFilter()
    private var derivativeFilter = LowPassFilter()
    private var lastTimestamp: TimeInterval?
    private var lastRawValue: Float?

    public init(minCutoff: Float = 1.0, beta: Float = 1.0, derivativeCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Float, deltaTime: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / deltaTime)
    }

    public mutating func filter(_ x: Float, timestamp: TimeInterval) -> Float {
        // 非有限输入直接丢弃，绝不让它进入内部状态——一个 NaN 能污染之后的每一帧。
        guard x.isFinite else {
            return valueFilter.hasOutput ? valueFilter.lastOutput : 0
        }

        guard let previousTimestamp = lastTimestamp else {
            lastTimestamp = timestamp
            lastRawValue = x
            return valueFilter.filter(x, alpha: 1)
        }

        let deltaTime = Float(timestamp - previousTimestamp)
        // 时间戳倒退或重复：拒绝更新状态，返回上次结果。
        guard deltaTime > 0, deltaTime.isFinite else {
            return valueFilter.lastOutput
        }
        lastTimestamp = timestamp

        let derivative = (x - (lastRawValue ?? x)) / deltaTime
        lastRawValue = x

        let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, deltaTime: deltaTime)
        let smoothedDerivative = derivativeFilter.filter(derivative, alpha: derivativeAlpha)

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let valueAlpha = Self.alpha(cutoff: cutoff, deltaTime: deltaTime)
        return valueFilter.filter(x, alpha: valueAlpha)
    }
}

/// 三分量 One Euro 滤波器。各轴独立滤波。
public struct OneEuroFilter3: Sendable {
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var z: OneEuroFilter

    public init(minCutoff: Float = 1.0, beta: Float = 1.0, derivativeCutoff: Float = 1.0) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        z = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    public mutating func filter(_ v: SIMD3<Float>, timestamp: TimeInterval) -> SIMD3<Float> {
        SIMD3(
            x.filter(v.x, timestamp: timestamp),
            y.filter(v.y, timestamp: timestamp),
            z.filter(v.z, timestamp: timestamp)
        )
    }
}
