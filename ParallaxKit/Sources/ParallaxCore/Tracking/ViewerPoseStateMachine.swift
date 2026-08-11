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
            let elapsed = now - startTime
            // 时间倒退或过渡时长非正：直接结束过渡，避免出现负进度。
            if elapsed <= 0 || transitionDuration <= 0 {
                output = elapsed < 0 ? target : start
                if elapsed < 0 {
                    transitionStart = nil
                    transitionStartTime = nil
                }
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
