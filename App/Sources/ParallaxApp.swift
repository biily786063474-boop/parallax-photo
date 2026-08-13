import SwiftUI
import UIKit
import MetalKit
import ARKit
import simd
import Observation
import QuartzCore
import ParallaxCore

@main
struct ParallaxApp: App {
    var body: some Scene {
        WindowGroup {
            ParallaxView()
        }
    }
}

/// 顶层界面：全屏 Metal 视图 + 一行状态文字叠加。
///
/// 状态文字方便真机判读（简报 Step 4 要求）：当前是追踪中还是 idle、
/// 眼位的具体数值——这些数字是真机验收时判断"链路是否走通"的第一手证据。
struct ParallaxView: View {
    @State private var poseController = PoseController(deviceProfile: Self.currentDeviceProfile())

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            MetalViewRepresentable(poseController: poseController)
                .ignoresSafeArea()
            Text(poseController.statusText)
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
                .padding(.top, 48)
                .padding(.leading, 12)
        }
        .task { poseController.start() }
        .onDisappear { poseController.stop() }
    }

    /// 机型标识用 `uname` 取，查 `DeviceProfileRegistry` 拿屏幕参数。
    /// 与 `Probe/Sources/FaceProbe.swift` 里 P11 测量的取法完全一致，不重新发明一遍。
    private static func currentDeviceProfile() -> DeviceProfile {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return DeviceProfileRegistry.profile(for: identifier)
    }
}

/// 观察者位置控制器：ARKit 眼位追踪 → 屏幕空间眼位，追踪不可用时用 idle 兜底。
///
/// **本任务的降级范围**：只做「追踪可用就用它，否则用 idle」的硬切换，
/// **不**接入 `ParallaxCore` 里已经写好的 `ViewerPoseStateMachine`（四级降级链
/// + 300ms 交叉淡入）——那是 spec §9 的完整效果。这个类型没有出现在
/// 本任务要用到的接口列表里，是有意排除：Task 3 的目标是验证「ARKit 眼位 →
/// 离轴投影 → Metal 上屏」这条链路本身能不能走通，不是做最终的降级体验；
/// 硬切换在真机上会有一次可见的跳变，接入交叉淡入留给后续任务。
@Observable
final class PoseController: NSObject, ARSessionDelegate {

    let deviceProfile: DeviceProfile
    /// `MetalViewRepresentable.makeUIView` 需要读它来构造渲染器，不能是 private。
    var screen: ScreenGeometry { deviceProfile.screen }

    private(set) var statusText: String

    /// 渲染器由 `MetalViewRepresentable.Coordinator` 强持有，这里只弱引用，
    /// 避免两边互相持有造成的生命周期纠缠——本对象不需要让 renderer 活着。
    weak var renderer: ParallaxRenderer?

    private let session = ARSession()
    private var eyeFilter = OneEuroFilter3()
    private let budget = ParallaxBudget()
    private let idleGenerator = IdlePoseGenerator()
    private let startTime = Date()

    /// 上一次收到「已追踪」人脸锚点的时刻。超过 `trackingTimeout` 未更新就判定
    /// 追踪不可用（权限拒绝、脸移出画面、session 中断或失败都会走到这里）。
    /// 这不是 spec 里定义的数值，是一个「宁可稍晚一点回落也不要因为一次眨眼
    /// 就误判丢失」的工程判断，量级上跟 ViewerPoseStateMachine 默认的
    /// 300ms 过渡时长相近。
    private var lastTrackedAt: Date?
    private let trackingTimeout: TimeInterval = 0.5

    /// 状态文字限速到 10Hz，避免 ARKit 60Hz 回调与屏幕刷新的 tick 都去驱动
    /// SwiftUI 重绘一行 Text——眼位本身仍然每次回调都写进 renderer，不受影响。
    private var lastStatusTextUpdate: TimeInterval = 0
    private let statusTextInterval: TimeInterval = 0.1

    private var displayLink: CADisplayLink?

    init(deviceProfile: DeviceProfile) {
        self.deviceProfile = deviceProfile
        self.statusText = "机型 \(deviceProfile.displayName)"
            + "（\(deviceProfile.isCalibrated ? "已校准" : "未校准")）· 启动中…"
        super.init()
        session.delegate = self
    }

    /// idle 从这里开始跑，不等相机授权——这是 spec §9.2② 的硬要求：
    /// app 打开的瞬间画面就该自己动，不能等用户做任何事。
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link

        guard ARFaceTrackingConfiguration.isSupported else {
            statusText = "本机型不支持人脸追踪，使用 idle 演示"
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        session.pause()
    }

    /// 屏幕刷新节奏的心跳：追踪可用时什么都不做（眼位由下面的
    /// `ARSessionDelegate` 回调直接写 renderer），追踪不可用时驱动 idle 摆动。
    @objc private func tick() {
        let isTracking = lastTrackedAt.map { Date().timeIntervalSince($0) < trackingTimeout } ?? false
        guard !isTracking else { return }

        let elapsed = Date().timeIntervalSince(startTime)
        let idleEye = idleGenerator.pose(at: elapsed)
        renderer?.eye = idleEye
        updateStatusText(String(
            format: "idle 摆动中 · eye=(%.3f, %.3f, %.3f)m", idleEye.x, idleEye.y, idleEye.z
        ))
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              faceAnchor.isTracked,
              let frame = session.currentFrame
        else { return }

        // 眼位 transform 是 face anchor 局部空间，必须左乘 anchor.transform 才是
        // 世界坐标（docs/api-facts-arkit-depth.md §1.2）。本任务只取双眼中点，
        // 中点不受 P5 实测到的左右眼命名镜像影响，两条都要取才能算中点。
        let leftWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
        let rightWorld = faceAnchor.transform * faceAnchor.rightEyeTransform
        let leftPosition = SIMD3<Float>(leftWorld.columns.3.x, leftWorld.columns.3.y, leftWorld.columns.3.z)
        let rightPosition = SIMD3<Float>(rightWorld.columns.3.x, rightWorld.columns.3.y, rightWorld.columns.3.z)
        let midpointWorld = (leftPosition + rightPosition) / 2

        // 世界坐标 → 相机空间：永不假设世界原点位置，只走有契约的 viewMatrix(for:)
        // （docs/api-facts-arkit-depth.md §1.3）。App 锁定 portrait（见 project.yml
        // 的 UISupportedInterfaceOrientations），所以这里硬编码 .portrait。
        let viewMatrix = frame.camera.viewMatrix(for: .portrait)
        let cameraSpaceEye4 = viewMatrix * SIMD4(midpointWorld, 1)
        let cameraSpaceEye = SIMD3<Float>(cameraSpaceEye4.x, cameraSpaceEye4.y, cameraSpaceEye4.z)

        let screenSpaceEye = EyePoseMapper.screenSpaceEye(cameraSpaceEye: cameraSpaceEye, screen: screen)
        let smoothed = eyeFilter.filter(screenSpaceEye, timestamp: frame.timestamp)
        let clamped = budget.clamp(smoothed)

        lastTrackedAt = Date()
        renderer?.eye = clamped
        updateStatusText(String(
            format: "追踪中 · eye=(%.3f, %.3f, %.3f)m", clamped.x, clamped.y, clamped.z
        ))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // 不直接写 statusText：下一次 tick() 会在 trackingTimeout 内把它
        // 覆盖成「idle 摆动中」，这条 print 只为真机 Console 调试留个痕迹。
        print("ParallaxApp: ARSession 失败: \(error.localizedDescription)")
    }

    private func updateStatusText(_ text: @autoclosure () -> String) {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastStatusTextUpdate > statusTextInterval else { return }
        lastStatusTextUpdate = now
        statusText = text()
    }
}

/// 把 `MTKView` 接进 SwiftUI，并把渲染器交给 `PoseController` 的弱引用，
/// 让 ARKit / idle 回调能直接写 `renderer.eye`。
struct MetalViewRepresentable: UIViewRepresentable {
    let poseController: PoseController

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = ParallaxRenderer.colorPixelFormat
        view.depthStencilPixelFormat = ParallaxRenderer.depthPixelFormat
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black

        guard let device = MTLCreateSystemDefaultDevice() else { return view }
        view.device = device

        guard let renderer = ParallaxRenderer(device: device, screen: poseController.screen) else {
            return view
        }
        // Coordinator 强持有渲染器——MTKView.delegate 是 weak，
        // PoseController 对渲染器的引用也是 weak，总要有一边真正拥有它。
        context.coordinator.renderer = renderer
        poseController.renderer = renderer
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: ParallaxRenderer?
    }
}
