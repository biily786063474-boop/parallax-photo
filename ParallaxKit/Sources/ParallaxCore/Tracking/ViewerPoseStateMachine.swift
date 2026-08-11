import Foundation
import simd

/// 观察者位置的四级降级链，带平滑过渡。
///
/// 见 spec §9。核心要求：**层级之间必须交叉淡入，不能瞬切**。
/// 追踪一丢就硬切到陀螺仪，画面会跳一下，那一跳会让整个效果显得廉价。
public struct ViewerPoseStateMachine: Sendable {

    /// 源切换时的交叉淡入时长，秒。
    public var transitionDuration: TimeInterval

    public private(set) var activeSource: ViewerPoseSourceKind = .idle

    /// 上一次对外输出的位置。**过渡的起点永远是它**，不是上一个源的当前值——
    /// 源切换时上一个源往往已经彻底不可用（脸移出画面），拿它的最后一个值当起点会跳。
    private var lastOutput: SIMD3<Float>?
    private var transitionStart: SIMD3<Float>?
    private var transitionStartTime: TimeInterval?

    public init(transitionDuration: TimeInterval = 0.3) {
        self.transitionDuration = transitionDuration
    }

    public mutating func update(
        _ inputs: ViewerPoseInputs,
        now: TimeInterval
    ) -> SIMD3<Float> {
        let (kind, target) = inputs.best()

        // 首次调用：直接落到目标，不做过渡。
        guard let previousOutput = lastOutput else {
            activeSource = kind
            lastOutput = target
            return target
        }

        if kind != activeSource {
            activeSource = kind
            transitionStart = previousOutput
            transitionStartTime = now
        }

        let output: SIMD3<Float>
        if let start = transitionStart, let startTime = transitionStartTime {
            // 过渡时长非正 = 调用方显式禁用了过渡：直接落到目标，不留中间态。
            // 注意必须清掉过渡状态，否则后续每帧都会重新进入这里，输出被永久冻结。
            if transitionDuration <= 0 {
                output = target
                transitionStart = nil
                transitionStartTime = nil
                lastOutput = output
                return output
            }
            let elapsed = now - startTime
            if elapsed < 0 {
                // 时钟倒退。硬跳到目标、或退回过渡起点，都会重新制造这个状态机
                // 存在的理由——那一跳。所以把锚点挪到当前输出、计时基准挪到当前时刻，
                // 从这里重新走完剩下的路。
                transitionStart = previousOutput
                transitionStartTime = now
                output = previousOutput
            } else if elapsed >= transitionDuration {
                output = target
                transitionStart = nil
                transitionStartTime = nil
            } else {
                let progress = Float(elapsed / transitionDuration)
                output = simd_mix(start, target, SIMD3(repeating: smoothstep(progress)))
            }
        } else {
            output = target
        }

        lastOutput = output
        return output
    }

    /// 三次 Hermite 平滑，两端一阶导为 0。
    /// 用它而不是线性插值：线性插值在过渡开始和结束的瞬间速度突变，肉眼能看出两下轻微的顿。
    private func smoothstep(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
