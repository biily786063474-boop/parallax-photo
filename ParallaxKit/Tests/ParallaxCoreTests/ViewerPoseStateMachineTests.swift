import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("ViewerPoseStateMachine")
struct ViewerPoseStateMachineTests {

    static let idlePose = SIMD3<Float>(0, 0, 0.35)

    private static func inputs(
        face: SIMD3<Float>? = nil,
        motion: SIMD3<Float>? = nil,
        manual: SIMD3<Float>? = nil
    ) -> ViewerPoseInputs {
        ViewerPoseInputs(faceTracking: face, motion: motion, manual: manual, idle: idlePose)
    }

    @Test("优先级顺序：manual > faceTracking > motion > idle")
    func priorityOrder() {
        #expect(ViewerPoseSourceKind.manual.priority > ViewerPoseSourceKind.faceTracking.priority)
        #expect(ViewerPoseSourceKind.faceTracking.priority > ViewerPoseSourceKind.motion.priority)
        #expect(ViewerPoseSourceKind.motion.priority > ViewerPoseSourceKind.idle.priority)
    }

    @Test("只有 idle 可用时输出 idle")
    func fallsBackToIdle() {
        var machine = ViewerPoseStateMachine()
        let out = machine.update(Self.inputs(), now: 0)
        #expect(machine.activeSource == .idle)
        #expect(simd_length(out - Self.idlePose) < 1e-6)
    }

    @Test("人脸追踪可用时切换过去")
    func switchesToFaceTracking() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(), now: 0)
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 0.1)
        #expect(machine.activeSource == .faceTracking)
    }

    @Test("过渡期间输出连续，无跳变")
    func transitionIsContinuous() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        var previous = machine.update(Self.inputs(), now: 0)
        let target = SIMD3<Float>(0.09, 0.07, 0.25)   // 与 idle 相距较远

        // 从 0.01 秒开始每 1/120 秒喂一次，全程检查相邻输出差
        var time: TimeInterval = 0.01
        while time < 1.0 {
            let current = machine.update(Self.inputs(face: target), now: time)
            let delta = simd_length(current - previous)
            #expect(delta < 0.02, "在 t=\(time) 处跳变 \(delta) 米")
            previous = current
            time += 1.0 / 120.0
        }
        // 过渡结束后应该到达目标
        #expect(simd_length(previous - target) < 1e-3, "过渡结束仍未到达目标")
    }

    @Test("追踪丢失后平滑降级到 motion")
    func degradesToMotionSmoothly() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let facePose = SIMD3<Float>(0.08, 0, 0.3)
        let motionPose = SIMD3<Float>(-0.06, 0.04, 0.4)

        var time: TimeInterval = 0
        // 先让人脸追踪完全接管
        while time < 0.5 {
            _ = machine.update(Self.inputs(face: facePose, motion: motionPose), now: time)
            time += 1.0 / 120.0
        }
        #expect(machine.activeSource == .faceTracking)

        // 追踪丢失
        var previous = machine.update(Self.inputs(motion: motionPose), now: time)
        #expect(machine.activeSource == .motion)

        while time < 1.5 {
            let current = machine.update(Self.inputs(motion: motionPose), now: time)
            #expect(simd_length(current - previous) < 0.02,
                    "降级过程在 t=\(time) 跳变")
            previous = current
            time += 1.0 / 120.0
        }
        #expect(simd_length(previous - motionPose) < 1e-3)
    }

    @Test("手动拖动优先于人脸追踪")
    func manualOverridesFaceTracking() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 0)
        _ = machine.update(
            Self.inputs(face: SIMD3(0.05, 0, 0.3), manual: SIMD3(-0.02, 0.01, 0.3)),
            now: 0.1
        )
        #expect(machine.activeSource == .manual)
    }

    @Test("过渡中途改变目标不产生跳变")
    func retargetMidTransitionIsSmooth() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        _ = machine.update(Self.inputs(), now: 0)

        var previous = machine.update(Self.inputs(face: SIMD3(0.09, 0, 0.25)), now: 0.05)
        // 过渡进行到一半时切到另一个源
        var time: TimeInterval = 0.05
        while time < 0.20 {
            previous = machine.update(Self.inputs(face: SIMD3(0.09, 0, 0.25)), now: time)
            time += 1.0 / 120.0
        }
        while time < 0.8 {
            let current = machine.update(Self.inputs(motion: SIMD3(-0.08, 0.05, 0.45)), now: time)
            #expect(simd_length(current - previous) < 0.02,
                    "中途改变目标时在 t=\(time) 跳变")
            previous = current
            time += 1.0 / 120.0
        }
    }

    @Test("反复快速丢失与恢复不产生振荡")
    func rapidFlappingStaysBounded() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let facePose = SIMD3<Float>(0.08, 0.06, 0.28)
        let motionPose = SIMD3<Float>(-0.07, -0.05, 0.42)
        var previous = machine.update(Self.inputs(motion: motionPose), now: 0)

        var time: TimeInterval = 0
        for step in 0..<600 {
            let faceAvailable = (step / 10) % 2 == 0
            let current = machine.update(
                Self.inputs(face: faceAvailable ? facePose : nil, motion: motionPose),
                now: time
            )
            #expect(simd_length(current - previous) < 0.02, "第 \(step) 步振荡")
            #expect(current.x.isFinite && current.y.isFinite && current.z.isFinite)
            previous = current
            time += 1.0 / 120.0
        }
    }

    @Test("时间倒退不产生 NaN")
    func handlesBackwardTime() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 10)
        let out = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 5)
        #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite)
    }

    @Test("过渡时长为零时立即落到目标，不会永久冻结")
    func zeroTransitionDurationSnapsToTarget() {
        // transitionDuration 是 public var，调用方可能为了"无动画/减弱动效"把它设成 0。
        // 那时正确行为是直接落到目标，而不是卡在过渡起点再也出不来。
        var machine = ViewerPoseStateMachine(transitionDuration: 0)
        let motionPose = SIMD3<Float>(-0.07, -0.05, 0.42)
        let facePose = SIMD3<Float>(0.08, 0.06, 0.28)

        _ = machine.update(Self.inputs(motion: motionPose), now: 0)
        let afterSwitch = machine.update(
            Self.inputs(face: facePose, motion: motionPose), now: 0.1
        )
        #expect(machine.activeSource == .faceTracking)
        #expect(simd_length(afterSwitch - facePose) < 1e-5,
                "未落到目标，停在 \(afterSwitch)")

        // 再喂若干帧，确认不是暂时现象
        var latest = afterSwitch
        for step in 1...10 {
            latest = machine.update(
                Self.inputs(face: facePose, motion: motionPose),
                now: 0.1 + TimeInterval(step) * 0.1
            )
        }
        #expect(simd_length(latest - facePose) < 1e-5, "输出被永久冻结在 \(latest)")
    }

    @Test("过渡中途时钟倒退不产生跳变，且仍能到达目标")
    func backwardClockMidTransitionDoesNotJump() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let target = SIMD3<Float>(0.09, 0.07, 0.25)

        _ = machine.update(Self.inputs(), now: 0)
        // 让过渡走到中途
        var previous = machine.update(Self.inputs(face: target), now: 0.1)
        for step in 1...6 {
            previous = machine.update(
                Self.inputs(face: target), now: 0.1 + TimeInterval(step) * 0.01
            )
        }

        // 时钟退到过渡开始之前
        let afterRewind = machine.update(Self.inputs(face: target), now: 0.05)
        let jump = simd_length(afterRewind - previous)
        #expect(jump < 0.02, "时钟倒退造成跳变 \(jump) 米")
        #expect(afterRewind.x.isFinite && afterRewind.y.isFinite && afterRewind.z.isFinite)

        // 时钟恢复正常后仍能走到目标
        var latest = afterRewind
        for step in 1...60 {
            latest = machine.update(
                Self.inputs(face: target), now: 0.05 + TimeInterval(step) * 0.02
            )
        }
        #expect(simd_length(latest - target) < 1e-3, "倒退后无法到达目标，停在 \(latest)")
    }
}
