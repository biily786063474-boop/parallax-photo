import SwiftUI
import UIKit
import MetalKit
import ARKit
import CoreMotion
import simd
import Observation
import QuartzCore
import PhotosUI
import Photos
import UniformTypeIdentifiers
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
    @State private var showingPicker = false

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
        // 选照片入口：右上角悬浮按钮，不引入 NavigationStack——现在这个全屏
        // Metal 视图 + 状态文字叠层的首屏结构不该因为加一个按钮而改变。
        .overlay(alignment: .topTrailing) {
            Button {
                showingPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 18, weight: .medium))
                    .padding(10)
                    .background(.black.opacity(0.6), in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.top, 44)
            .padding(.trailing, 12)
            .accessibilityLabel("选照片")
        }
        // 底部叠层：加载失败提示（若有）+ 视差参数滑块，合并进同一个 VStack
        // 而不是各开一个 `.overlay(alignment: .bottom)`——两个 bottom overlay
        // 会在同一个位置各自居中叠放，提示条一出现就会跟滑块条重叠。放进
        // 同一个 VStack 让提示条自然显示在滑块条上方，互不遮挡。
        //
        // 加载失败提示与顶部 statusText 分开放：statusText 每帧刷新，
        // 错误提示放在这里才不会被下一次 tick() 瞬间盖掉（简报要求：不是
        // 「加载失败」，而是解释原因 + 给出下一步）。
        .overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                if let message = poseController.photoLoadMessage {
                    Text(message)
                        .font(.system(.footnote))
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .onTapGesture { poseController.dismissPhotoLoadMessage() }
                        .transition(.opacity)
                }
                ParallaxControlsBar(poseController: poseController)
            }
            .padding(.bottom, 28)
        }
        .sheet(isPresented: $showingPicker) {
            PhotoPicker(
                onFinish: { showingPicker = false },
                onPick: { candidates in poseController.loadPhoto(candidates: candidates) }
            )
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

/// 真机验收用的参数滑块条：视差强度 + 零视差面。两个都是「肉眼参数」——
/// 合适的值取决于具体照片和个人对空间感的取舍，不该在代码里硬编一个猜的
/// 数字，而是让滑块和数值同时露出来，边看画面边拖，当场就能定下来。
///
/// **陀螺仪灵敏度故意不在这里**：它不是口味参数，是能用几何算准的量——
/// 唯一正确值是 1.0（不缩放），推导见 `MotionEyeEstimator` 类型文档。
/// 这里曾经短暂加过第三个滑块想让用户试出"合适的值"，被否决：算不准是
/// 我们数学没对齐的问题，不该做成旋钮推给用户去猜。真机上如果还觉得
/// `motion` 跟 `faceTracking` 速率不匹配，去看 `PoseController.motionSensitivity`
/// 和 `MotionEyeEstimator` 顶部注释里记的已知近似（旋转中心建模），修模型，
/// 不要回头在这里加参数。
///
/// 用 `@Bindable` 而不是手搓 `Binding(get:set:)`：`PoseController` 已经是
/// `@Observable`，`@Bindable` 直接从它的属性生成双向绑定，滑块拖动与数值
/// 文字会一起刷新——手搓的 get/set 闭包也能让 Slider 本身动起来，但旁边
/// 那行文字不保证跟着重绘（它不经过 Observation 的访问追踪）。
private struct ParallaxControlsBar: View {
    @Bindable var poseController: PoseController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                title: "视差强度",
                valueText: String(format: "%.3f", poseController.parallaxScale),
                value: $poseController.parallaxScale,
                range: 0.005...0.20
            )
            row(
                title: "零视差面",
                valueText: String(format: "%.2f", poseController.zeroParallax),
                value: $poseController.zeroParallax,
                range: 0...1
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
    }

    private func row(
        title: String, valueText: String, value: Binding<Float>, range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) \(valueText)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
            Slider(value: value, in: range)
                .tint(.white)
        }
    }
}

/// CoreMotion 的四元数分量是 `Double`，`ParallaxCore`（含 `MotionEyeEstimator`）
/// 全程用 `Float`——这是这条边界唯一的类型转换点。
private extension CMQuaternion {
    var simdQuatf: simd_quatf {
        simd_quatf(vector: SIMD4<Float>(Float(x), Float(y), Float(z), Float(w)))
    }
}

/// 观察者位置控制器：ARKit 眼位追踪 → 屏幕空间眼位，追踪不可用时依次降级到
/// 陀螺仪、再到 idle 兜底。
///
/// 接入了 `ParallaxCore` 的 `ViewerPoseStateMachine`（四级降级链 + 300ms
/// 交叉淡入）。本阶段喂 `faceTracking`／`motion`／`idle` 三路，`manual`
/// （手指拖动）仍传 `nil`——不在这次任务范围内，留给后续任务。
///
/// idle 与 motion 共用同一个锚点 `idleAnchor`：最后一次拿到有效人脸眼位时的
/// 位置。追踪一丢，`tick()` 里 idle 绕它摆、motion 在它上面叠加陀螺仪增量，
/// 而不是分别退回屏幕中心或忽略已知位置。状态机再把当前激活的降级源和丢失前
/// 的输出做 300ms 交叉淡入——两件事缺一都会跳：只做交叉淡入不挪锚点，淡入的
/// 终点仍然在屏幕中心附近，跟用户实际所在位置脱节；只挪锚点不做交叉淡入，
/// 退回硬切换，那一下瞬跳还在。
///
/// motion 具体怎么算见 `MotionEyeEstimator`：陀螺仪只给相对姿态，不知道观察者
/// 在哪，所以追踪刚丢失的那一刻把当时的设备姿态记成参考姿态
/// （`motionReferenceAttitude`），之后每帧算"参考姿态 → 当前姿态"的增量、
/// 叠加到 `idleAnchor` 上——增量在接管瞬间精确为零（`MotionEyeEstimator` 的
/// 核心契约），画面不会跳。
@Observable
final class PoseController: NSObject, ARSessionDelegate {

    let deviceProfile: DeviceProfile
    /// `MetalViewRepresentable.makeUIView` 需要读它来构造渲染器，不能是 private。
    var screen: ScreenGeometry { deviceProfile.screen }

    private(set) var statusText: String

    /// Task 2：相册里选出的真实照片，`DepthPhotoLoader` 解码成功后存在这里。
    /// 本任务不改渲染器，所以只负责把它填好；真正把它推给渲染器换素材、
    /// 并清空这个槽位，是 Task 3 在 `tick()` 里加的那几行。
    private(set) var pendingPhoto: (color: CGImage, depth: DepthMap)?

    /// 加载失败时的可行动提示（简报要求：不能只说「加载失败」）。
    /// 独立于 `statusText`——那个每帧刷新，装不下需要用户读完的句子。
    private(set) var photoLoadMessage: String?

    /// 渲染器由 `MetalViewRepresentable.Coordinator` 强持有，这里只弱引用，
    /// 避免两边互相持有造成的生命周期纠缠——本对象不需要让 renderer 活着。
    weak var renderer: ParallaxRenderer? {
        didSet {
            // renderer 是真机验收时才第一次出现的（`makeUIView` 建好 MTKView
            // 才会赋值），赋值这一刻把当前滑块状态同步过去一次——否则如果
            // 这两处默认值以后不小心分叉（比如只改了这里没改渲染器初值，
            // 或反过来），画面初始效果会和滑块显示的数字对不上。
            renderer?.parallaxScale = parallaxScale
            renderer?.zeroParallax = zeroParallax
        }
    }

    /// 视差强度滑块的当前值，真机验收用（简报 Step 1：幅度太小看不出空间感，
    /// 与其猜一个新的固定值，不如让用户当场拖到合适为止）。范围
    /// `0.005...0.20`：下限保留"几乎关掉视差"的对照组，上限是 `ParallaxBudget`
    /// 允许的位移量级、再往上画面会碎裂成噪声，滑再远也没有意义。
    /// 默认值须与 `ParallaxRenderer.parallaxScale` 的初值一致，见 `renderer` 的
    /// `didSet`——那里负责把"默认值一致"这条假设真正落到实处，而不是两边
    /// 各自硬编码却指望它们碰巧相等。
    var parallaxScale: Float = 0.06 {
        didSet { renderer?.parallaxScale = parallaxScale }
    }

    /// 零视差面滑块（简报「顺便」要求）：哪一层深度贴在屏幕平面上，直接决定
    /// 「伸出屏幕」还是「陷进屏幕」的观感占比，跟 parallaxScale 一样是需要
    /// 现场调的艺术参数，不是能提前猜准的常数。范围 `0...1` 对应
    /// `DepthMap` 的完整值域。
    var zeroParallax: Float = 0.5 {
        didSet { renderer?.zeroParallax = zeroParallax }
    }

    private let session = ARSession()
    private var eyeFilter = OneEuroFilter3()
    private let budget = ParallaxBudget()
    private let idleGenerator = IdlePoseGenerator()
    private let startTime = Date()

    /// 降级链状态机：源切换时做 300ms 交叉淡入，见类型上方注释。
    private var poseStateMachine = ViewerPoseStateMachine()

    /// 降级锚点：最后一次拿到有效人脸眼位时的位置，idle 与 motion 共用。每次
    /// ARKit 给出有效眼位就更新（见 `session(_:didUpdate:)`），追踪丢失后
    /// `tick()` 里 idle 绕它摆、motion 在它上面叠加陀螺仪增量，而不是分别
    /// 退回屏幕中心或忽略已知位置——这是 idle 断层 bug 修复时定下的原则，
    /// motion 延续同一条。
    ///
    /// 初值取 `idleGenerator` 的默认锚点（屏幕正前方 distance 处），
    /// 因为 app 启动瞬间、第一次拿到人脸之前，没有「最后已知眼位」可用。
    private var idleAnchor: SIMD3<Float>

    /// 陀螺仪读数来源。用拉取式（轮询 `deviceMotion` 属性）而不是回调式
    /// （`startDeviceMotionUpdates(to:withHandler:)`），好让姿态更新并入
    /// `tick()` 这一条心跳，不再多开一条状态写入路径——idle 断层 bug 的
    /// 教训就是"两条写入路径各写各的"。
    private let motionManager = CMMotionManager()

    /// 追踪丢失那一刻的设备姿态。`nil` 表示"当前在追踪中，或还没来得及采到
    /// 参考姿态"；`tick()` 每帧判断：一旦重新追踪到人脸就清空，下次丢失再
    /// 重新采一次——不能沿用旧参考，设备这段时间可能已经转动，旧参考会让
    /// 重新丢失瞬间的增量不再是零。非 nil 时，`MotionEyeEstimator.offset(
    /// from: 它, to: 当前姿态, ...)` 在采集的那一帧必然是零向量（reference
    /// 和 current 是同一次读数），这是接管瞬间不跳变的保证。
    private var motionReferenceAttitude: simd_quatf?

    /// 陀螺仪增量的缩放系数，见 `MotionEyeEstimator.offset(sensitivity:)`。
    ///
    /// **恒为 1.0，故意不开放成滑块。** 这不是口味参数：设备转动带来的观察者
    /// 等效位移是能用几何算准的量，1.0（不缩放）就是与 faceTracking（ARKit
    /// 实测眼位，严格 1:1）同一把尺子下的唯一正确值——不是猜出来的初始值，
    /// 是算出来的（推导见 `MotionEyeEstimator` 类型文档）。
    ///
    /// 历史教训：曾经默认给 0.5（"手机转动幅度远大于头部移动，1:1 会让视差
    /// 夸张"），那是没有真机依据的主观猜测；真机反馈"陀螺仪速率和面部追踪
    /// 没保持一致"证明它是错的——错的是数学没对齐，不是需要留给用户微调的
    /// 余量。曾经短暂加过一个真机滑块想让用户试出"合适的值"，也被否决：算不准
    /// 是我们的责任，做成旋钮只会把没做对的活推给用户，猜出来的数字换个机型
    /// 或持机角度照样不准。
    ///
    /// 如果真机上仍然觉得 `motion` 和 `faceTracking` 速率不匹配，**先怀疑模型
    /// 本身，不要在这个值上做文章**：CoreMotion 的 `attitude` 只有朝向、没有
    /// 位置，`MotionEyeEstimator` 的模型隐含假设设备绕屏幕坐标原点转动，但
    /// 实际人是绕手腕/手肘转的，中心差几厘米——这是已知近似，细节和正确的
    /// 修法见 `MotionEyeEstimator` 类型文档最后一段。
    private let motionSensitivity: Float = 1.0

    /// ARKit 最近一次给出的、已滤波夹紧过的眼位。是否仍然「新鲜」由
    /// `lastTrackedAt` + `trackingTimeout` 判定，不在这里判断——
    /// 单一判据，避免两处逻辑各算一遍而慢慢对不上。
    private var latestFaceEye: SIMD3<Float>?

    /// 上一次收到「已追踪」人脸锚点的时刻。超过 `trackingTimeout` 未更新就判定
    /// 追踪不可用（权限拒绝、脸移出画面、session 中断或失败都会走到这里）。
    ///
    /// **真机反馈"切换卡顿"后从 0.5 降到 0.15（约 9 帧 @60Hz）。** 旧值的注释曾写
    /// "不要因为一次眨眼就误判丢失"——这个顾虑站不住：ARKit 眨眼时
    /// `ARFaceAnchor.isTracked` 照常为 true，真正让它变 false 的是脸移出画面、
    /// 被遮挡、光线不足，眨眼根本走不到这条判定。旧值 0.5s 的实际后果是：追踪
    /// 真的丢失后，这 0.5s 内 `isTracking` 仍为 true，喂给状态机的 `faceTracking`
    /// 输入是冻结的旧眼位，画面完全静止；0.5s 后才开始 `ViewerPoseStateMachine`
    /// 的 300ms 过渡——两段相加，用户看到约 0.8s 的异常期，前半段还是彻底不动，
    /// 这就是"明显卡顿"的成因。
    ///
    /// 这层超时不该重复状态机已经做的平滑（`ViewerPoseStateMachine` 有 300ms
    /// 交叉淡入，`rapidFlappingStaysBounded` 测试专门覆盖"快速反复丢失/恢复不
    /// 振荡"），它只需要吸收「单帧漏检」这一类传感器噪声——0.15s 已经是 9 帧的
    /// 余量。两层各司其职：这里挡瞬时噪声，观感上的平滑交给状态机负责。
    private var lastTrackedAt: Date?
    private let trackingTimeout: TimeInterval = 0.15

    /// 状态文字限速到 10Hz，避免每次 `tick()`（屏幕刷新节奏，可达 60Hz+）都去
    /// 驱动 SwiftUI 重绘一行 Text——eye 本身仍然每次 `tick()` 都写进 renderer，
    /// 不受这个限速影响。
    private var lastStatusTextUpdate: TimeInterval = 0
    private let statusTextInterval: TimeInterval = 0.1

    private var displayLink: CADisplayLink?

    init(deviceProfile: DeviceProfile) {
        self.deviceProfile = deviceProfile
        self.idleAnchor = SIMD3(0, 0, idleGenerator.distance)
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

        // 陀螺仪独立于 ARKit 启动，不等人脸追踪成不成功——机型不支持人脸追踪、
        // 或追踪随时丢失，都要靠它兜底（spec §9.3「机型不支持 → motion（启动
        // 即定）」）。不可用时什么都不做：`motionManager.deviceMotion` 永远
        // 是 nil，`tick()` 里读出的姿态自然也是 nil，`motion` 输入传不出去，
        // 链路自动掉到 idle——不需要在别处再加一层"设备不支持"的特判。
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates()
        }

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
        motionManager.stopDeviceMotionUpdates()
    }

    /// Task 2：把选中的相册照片解码成彩色图 + 深度图。
    ///
    /// **候选重试链（bug 修复）**：`candidates` 是 `PhotoPicker` 按优先级
    /// （HEIC → HEIF → 其他非 JPEG 具体类型 → 通用 `public.image`）依次取到的
    /// 原始字节。真机反馈"选了人像照片仍提示没有深度"，根因大概率是旧代码
    /// 只请求了通用类型 `public.image`——`NSItemProvider` 对通用类型可能返回
    /// 转码后的"标准表示"（常见是 JPEG），转码会丢弃 disparity/depth 这类
    /// 辅助数据。这里逐个候选尝试 `DepthPhotoLoader.load`，谁先解出深度就用谁，
    /// 而不是只信第一个、失败就直接报错——用户不该为格式选择失误买单。
    ///
    /// HEIC 解压与深度反 padding 都不是免费的，挪到后台队列；`PoseController`
    /// 是 `@Observable`，它的状态在这个 app 里全靠"只在主线程写"这条约定
    /// 维持一致性（`tick()` 挂在 `CADisplayLink`、ARSessionDelegate 回调都在
    /// 主线程），这里不能破例，所以解码完必须跳回主线程再写 `pendingPhoto`
    /// / `photoLoadMessage`。
    func loadPhoto(candidates: [PhotoDataCandidate]) {
        photoLoadMessage = nil

        guard !candidates.isEmpty else {
            // PhotoPicker 连一种候选格式的原始字节都没取到——比"没有深度"更
            // 基础的失败，消息要分开说，不然会误导用户去找"人像模式"。
            photoLoadMessage = "无法读取这张照片的数据，请重新选择"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for candidate in candidates {
                print("PoseController: 尝试解码候选 \(candidate.typeIdentifier)（data.count=\(candidate.data.count)）")
                fflush(stdout)
                if let result = DepthPhotoLoader.load(from: candidate.data) {
                    print("PoseController: \(candidate.typeIdentifier) 解出深度成功，采用该候选")
                    fflush(stdout)
                    DispatchQueue.main.async { self?.pendingPhoto = result }
                    return
                }
            }
            print("PoseController: 全部 \(candidates.count) 个候选都未能解出深度数据")
            fflush(stdout)
            DispatchQueue.main.async {
                // 可行动提示：说明原因 + 给出下一步，不是「加载失败」四个字了事
                // （简报「几个容易出错的地方」④）。现在明确点出"试过几种格式"，
                // 而不是笼统的"没有深度信息"——那句话在旧实现里其实经常是
                // "格式选错了，压根没读到真正的深度数据"，不是照片真没有。
                self?.photoLoadMessage = "这张照片没有可用的深度数据（已尝试 \(candidates.count) 种格式），"
                    + "换一张用「人像」模式拍摄的照片试试"
            }
        }
    }

    func dismissPhotoLoadMessage() {
        photoLoadMessage = nil
    }

    /// 屏幕刷新节奏的心跳：状态机每帧都跑，不只在追踪丢失时跑。
    ///
    /// 这是接入 `ViewerPoseStateMachine` 的关键：交叉淡入需要知道「丢失前
    /// 输出到了哪」，只有让状态机在追踪期间也持续被喂 `faceTracking` 输入，
    /// 它内部的 `lastOutput` 才会跟着人脸位置走；如果像之前那样追踪时完全
    /// 不调用它，它就没有连续的起点可淡出，第一次调用只会是"首次落地"
    /// （见 `ViewerPoseStateMachine.update` 对 `lastOutput == nil` 的处理），
    /// 等于又变回硬切换。
    ///
    /// `elapsed` 是自 app 启动起单调递增的同一个时钟，同时喂给 idle 生成器
    /// 和状态机——不在切换瞬间重置，摆动的相位才不会跟着源切换抖一下。
    @objc private func tick() {
        let elapsed = Date().timeIntervalSince(startTime)
        let isTracking = lastTrackedAt.map { Date().timeIntervalSince($0) < trackingTimeout } ?? false

        // 重新追踪到人脸：清掉参考姿态，下次丢失时从当时的姿态重新采一次
        // （原因见 `motionReferenceAttitude` 的类型注释）。
        if isTracking {
            motionReferenceAttitude = nil
        }

        let currentAttitude = motionManager.deviceMotion.map { $0.attitude.quaternion.simdQuatf }

        // 追踪丢失、且还没为这一次丢失采过参考姿态：现在采——"现在"就是接管
        // 的起点，`MotionEyeEstimator` 保证这一帧算出的增量精确为零。
        if !isTracking, motionReferenceAttitude == nil {
            motionReferenceAttitude = currentAttitude
        }

        let motionEye: SIMD3<Float>?
        if let reference = motionReferenceAttitude, let current = currentAttitude {
            motionEye = idleAnchor + MotionEyeEstimator.offset(
                from: reference,
                to: current,
                distance: idleAnchor.z,
                sensitivity: motionSensitivity
            )
        } else {
            // 还没有参考姿态（刚丢失、CoreMotion 还没来得及给出第一次读数），
            // 或本机不支持陀螺仪：motion 传 nil，链路自动掉到 idle。
            motionEye = nil
        }

        let idleEye = idleGenerator.pose(at: elapsed, around: idleAnchor)
        let inputs = ViewerPoseInputs(
            faceTracking: isTracking ? latestFaceEye : nil,
            motion: motionEye,
            manual: nil,
            idle: idleEye
        )
        let eye = poseStateMachine.update(inputs, now: elapsed)

        renderer?.eye = eye

        // Task 3：渲染器已经能换素材了，这里把 loadPhoto(from:) 存好的结果
        // 推过去。放在 tick() 而不是加载完成的那一刻直接推，是因为 Task 2
        // 提交时渲染器还没有 updateScene(color:depth:) 这个方法——两次提交
        // 各自都要能独立编译通过，所以中转槽位（pendingPhoto）先于消费它的
        // 代码落地。推送后立刻清空，不然每帧都重新上传一遍纹理。
        if let photo = pendingPhoto {
            pendingPhoto = nil
            // updateScene 失败（纹理创建失败）此前只 print，用户只看到"选了照片但
            // 画面没变"、没有任何解释（Plan 3 progress.md 记录的已知风险 ③）。
            // renderer 为 nil 时（渲染器还没接好）不算这次失败，视为成功放过——
            // 那是另一层生命周期时序问题，不在这次要修的范围内。
            let succeeded = renderer?.updateScene(color: photo.color, depth: photo.depth) ?? true
            if !succeeded {
                photoLoadMessage = "这张照片解码成功，但显示失败，请重试"
            }
        }

        updateStatusText(String(
            format: "%@ · eye=(%.3f, %.3f, %.3f)m",
            statusLabel(for: poseStateMachine.activeSource), eye.x, eye.y, eye.z
        ))
    }

    private func statusLabel(for source: ViewerPoseSourceKind) -> String {
        switch source {
        case .faceTracking: return "追踪中"
        case .idle: return "idle 摆动中"
        case .motion: return "陀螺仪"
        case .manual: return "手动拖动"
        }
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
        latestFaceEye = clamped
        // 每次拿到有效眼位就搬一次 idle 锚点：追踪一旦丢失，idle 从这里接着摆，
        // 不会跑回屏幕中心。这是本次要修的 bug 本体，见类型注释。
        idleAnchor = clamped

        // 不在这里写 renderer.eye / statusText——统一交给 tick() 里的状态机
        // 计算并写入。两条写入路径各写各的，正是之前硬切换 bug 的成因。
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
/// 让 `tick()` 里状态机算出的结果能直接写 `renderer.eye`。
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
        // MTKView 自己的多重采样样本数必须和 renderer 建 pipeline 时用的
        // rasterSampleCount 一致（都来自 renderer.sampleCount 这同一个来源），
        // 否则 draw(in:) 第一次创建 render command encoder 就会崩——
        // 这一行漏掉，4x MSAA 不是"没效果"而是直接不能跑。
        view.sampleCount = renderer.sampleCount
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

/// `PhotoPicker` 取到的一份候选原始字节，配上它对应的类型标识符。类型标识符
/// 只用于日志/调试——真正决定"用哪个候选"的是
/// `PoseController.loadPhoto(candidates:)` 里挨个尝试 `DepthPhotoLoader.load`，
/// 谁先解出深度就用谁。
struct PhotoDataCandidate {
    let typeIdentifier: String
    let data: Data
}

/// 相册选照片入口。`filter = .depthEffectPhotos`（iOS 16+，本 app 部署目标
/// 17.0，恒可用）把列表从源头限制成"有景深效果"的照片，减少选完才发现
/// 没有深度数据的挫败——即便如此，`DepthPhotoLoader` 仍会做完整校验，
/// 因为 `photoDepthEffect` 只是"有景深效果"的旗标，不保证一定能解出可用
/// 深度图（`docs/api-facts-arkit-depth.md` §2.5 的原话）。
struct PhotoPicker: UIViewControllerRepresentable {
    /// 用户选中或取消后，无论是否拿到数据都要调用——负责让 SwiftUI 侧的
    /// `showingPicker` 变回 false。不能让 `PHPickerViewController` 自己
    /// `dismiss(animated:)`：它是被 SwiftUI 的 `.sheet` 呈现出来的，
    /// 自行 dismiss 不会同步 `showingPicker` 这个 `@State`，下次就弹不开了。
    var onFinish: () -> Void
    /// 按优先级排好序的候选数据，可能为空（一个候选都取不到时）。
    var onPick: ([PhotoDataCandidate]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onPick: onPick)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .depthEffectPhotos
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    /// 从 `NSItemProvider.registeredTypeIdentifiers` 里按优先级挑出候选类型。
    ///
    /// **这是这次 bug 修复的核心。** 旧代码只请求通用类型 `public.image`：
    /// `NSItemProvider.loadDataRepresentation(forTypeIdentifier:)` 面对一个
    /// 不是被直接注册、只是"conforms to"的通用类型时，系统可能返回转码后的
    /// "标准表示"（常见是 JPEG），转码会丢弃 disparity/depth 这类辅助数据——
    /// 照片本身没问题，是取数据的方式把深度弄丢了。优先请求具体格式（HEIC/
    /// HEIF）能避免这次转码。
    ///
    /// 顺序：`public.heic` → `public.heif` → 其他非 `public.jpeg` 的具体图像
    /// 类型（按 provider 声明的原始顺序）→ 兜底 `public.image`。故意不把
    /// `public.jpeg` 单独列一档：JPEG 容器本身不带 Apple 的 disparity/depth
    /// 辅助数据，前面的具体类型都试完仍失败时，最后一档 `public.image` 兜底
    /// 自然会解析到它——不需要为它重复一次。
    ///
    /// HEIC/HEIF 用原始 UTI 字符串而不是 `UTType.heic`/`UTType.heif`：本项目已经
    /// 三次栽在"Swift 符号名跟 ObjC 直觉拼写不一致"上（见
    /// `docs/api-facts-arkit-depth.md` §4），这两个值只是拿来跟
    /// `registeredTypeIdentifiers` 里的原始字符串做字符串比较，没有必要
    /// 依赖一个本文档尚未逐个编译验证过的 Swift 静态成员名。
    static func candidateTypeIdentifiers(from registered: [String]) -> [String] {
        let heic = "public.heic"
        let heif = "public.heif"
        let jpeg = "public.jpeg"
        let genericImage = UTType.image.identifier

        var candidates: [String] = []
        let registeredSet = Set(registered)

        func addIfPresent(_ identifier: String) {
            guard registeredSet.contains(identifier), !candidates.contains(identifier) else { return }
            candidates.append(identifier)
        }

        addIfPresent(heic)
        addIfPresent(heif)

        for identifier in registered {
            guard identifier != jpeg,
                  identifier != genericImage,
                  !candidates.contains(identifier),
                  let type = UTType(identifier),
                  type.conforms(to: .image)
            else { continue }
            candidates.append(identifier)
        }

        addIfPresent(genericImage)

        return candidates
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onFinish: () -> Void
        private let onPick: ([PhotoDataCandidate]) -> Void

        init(onFinish: @escaping () -> Void, onPick: @escaping ([PhotoDataCandidate]) -> Void) {
            self.onFinish = onFinish
            self.onPick = onPick
        }

        /// 用户选中一张、或点了取消，都会走到这里（取消时 `results` 为空）。
        ///
        /// 诊断日志（真机排查"选了人像照片却没有深度"用，print + fflush(stdout)，
        /// 配 `devicectl device process launch --console` 读）：
        /// - `registeredTypeIdentifiers`：最关键的一行，决定了下面能试到哪些候选
        /// - 每个候选各自的 data.count / error / 前 12 字节十六进制都单独打印，
        ///   用来对照 magic number 判断到底拿到的是 HEIC（offset 4 起 `66 74 79
        ///   70` = "ftyp"）还是 JPEG（`ff d8 ff` 开头）
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onFinish()
            guard let provider = results.first?.itemProvider else { return }

            let registered = provider.registeredTypeIdentifiers
            print("PhotoPicker: registeredTypeIdentifiers=\(registered)")
            fflush(stdout)

            let candidateIdentifiers = PhotoPicker.candidateTypeIdentifiers(from: registered)
            guard !candidateIdentifiers.isEmpty else {
                print("PhotoPicker: registeredTypeIdentifiers 里没有可用的图像类型，放弃加载")
                fflush(stdout)
                onPick([])
                return
            }

            // 按优先级顺序依次请求；每一步都是异步回调，用嵌套函数递归而不是
            // 并发发起——候选通常只有 1 个（真正的人像 HEIC 照片一般就注册这一种
            // 具体类型），递归的额外开销可以忽略不计，换来顺序有保证、日志好读。
            func attempt(index: Int, collected: [PhotoDataCandidate]) {
                guard index < candidateIdentifiers.count else {
                    // completion handler 不保证在主线程——`onPick` 最终会写
                    // `PoseController` 的 `@Observable` 状态，必须先跳回主线程。
                    // `[onPick]` 显式捕获：这是转义闭包，编译器要求显式 self/捕获，
                    // 与原代码 `loadDataRepresentation` 那个尾随闭包的写法一致。
                    DispatchQueue.main.async { [onPick] in onPick(collected) }
                    return
                }
                let identifier = candidateIdentifiers[index]
                print("PhotoPicker: 请求类型 [\(index + 1)/\(candidateIdentifiers.count)] \(identifier)")
                fflush(stdout)
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    var next = collected
                    if let data {
                        let magic = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
                        print("PhotoPicker: \(identifier) data.count=\(data.count) error=\(String(describing: error)) magic=[\(magic)]")
                        fflush(stdout)
                        next.append(PhotoDataCandidate(typeIdentifier: identifier, data: data))
                    } else {
                        print("PhotoPicker: \(identifier) 未取到数据 error=\(String(describing: error))")
                        fflush(stdout)
                    }
                    attempt(index: index + 1, collected: next)
                }
            }
            attempt(index: 0, collected: [])
        }
    }
}
