import Foundation
import ARKit
import simd
import UIKit
import ParallaxCore

/// 人脸追踪探针。只测量与打印，不渲染。
///
/// 各项测量对应 docs/api-facts-arkit-depth.md §6 的编号。
final class FaceProbe: NSObject, ARSessionDelegate {

    private let report: ProbeReport
    private let session = ARSession()

    // P3 用：统计相邻帧时间戳差
    private var lastFrameTimestamp: TimeInterval?
    private var frameIntervals: [TimeInterval] = []

    // P9 用：累积瞳距样本
    private var pupillaryDistances: [Float] = []

    init(report: ProbeReport) {
        self.report = report
        super.init()
        session.delegate = self
    }

    func start() {
        measureStaticFacts()

        guard ARFaceTrackingConfiguration.isSupported else {
            report.set("P1", value: "不支持", note: "本机型不支持人脸追踪")
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    /// 不需要跑起 session 就能测的部分
    private func measureStaticFacts() {
        // P1：各档视频格式的帧率
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        let formatDescriptions = formats.map { format in
            "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond)fps"
        }
        report.set(
            "P1",
            value: formatDescriptions.joined(separator: ", "),
            note: formats.isEmpty ? "列表为空" : "首项为默认格式"
        )

        // P4：可同时追踪的脸数
        report.set(
            "P4",
            value: "\(ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)",
            note: "默认 maximumNumberOfTrackedFaces = 1"
        )

        // P8：主摄像头是否可配置（nil 意味着被 ARKit 独占用于追踪）
        let configurableDevice = ARConfiguration.configurableCaptureDeviceForPrimaryCamera
        report.set(
            "P8",
            value: configurableDevice == nil ? "nil" : "非 nil",
            note: configurableDevice == nil
                ? "印证前摄被 ARKit 独占，不能并存 AVCaptureSession"
                : "可配置，与预期不符，需重新评估架构"
        )

        // P11：设备标识符与屏幕参数
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let profile = DeviceProfileRegistry.profile(for: identifier)
        // UIScreen.main 在 iOS 16+ 是 soft-deprecated，会产生一条警告。
        // 探针是一次性工具且只在 portrait 下跑，为它引入 window scene 查找不值得。
        // 正式 app 里不要这么写。
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        report.set(
            "P11",
            value: identifier,
            note: """
            表内: \(profile.displayName), 已校准: \(profile.isCalibrated); \
            点: \(Int(bounds.width))x\(Int(bounds.height)) @\(scale)x; \
            像素: \(Int(bounds.width * scale))x\(Int(bounds.height * scale)); \
            推算物理: \(String(format: "%.1f", profile.screen.width * 1000))x\
            \(String(format: "%.1f", profile.screen.height * 1000))mm
            """
        )
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        measureFrameRate(frame)
        measureCameraBasis(frame)
        measureCapturedDepth(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        measureEyes(faceAnchor)
        measureLookAtPoint(faceAnchor)
        measureFaceGeometry(faceAnchor)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        report.set("P1", value: "session 失败", note: error.localizedDescription)
    }

    // MARK: - 各项测量

    /// P3：didUpdateFrame 的实测频率
    private func measureFrameRate(_ frame: ARFrame) {
        if let last = lastFrameTimestamp {
            let interval = frame.timestamp - last
            if interval > 0 {
                frameIntervals.append(interval)
                if frameIntervals.count > 120 { frameIntervals.removeFirst() }
            }
        }
        lastFrameTimestamp = frame.timestamp

        guard frameIntervals.count >= 60 else { return }
        let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
        guard mean > 0 else { return }
        let minInterval = frameIntervals.min() ?? 0
        let maxInterval = frameIntervals.max() ?? 0
        report.set(
            "P3",
            value: String(format: "%.1f fps", 1.0 / mean),
            note: String(
                format: "帧间隔 %.1f–%.1f ms（%d 样本）",
                minInterval * 1000, maxInterval * 1000, frameIntervals.count
            )
        )
    }

    /// P2：相机变换的实际基准。设备静止时观察它是否为单位阵附近。
    private func measureCameraBasis(_ frame: ARFrame) {
        let position = frame.camera.transform.columns.3
        report.set(
            "P2",
            value: String(format: "cam pos (%.3f, %.3f, %.3f) m", position.x, position.y, position.z),
            note: "启动时若接近原点，说明世界原点确实落在设备初始位姿"
        )
    }

    /// P10：ARFrame 携带的深度数据类型与分辨率
    private func measureCapturedDepth(_ frame: ARFrame) {
        guard let depthData = frame.capturedDepthData else {
            report.set("P10", value: "nil", note: "该帧未携带深度（深度帧节奏与视频帧不同）")
            return
        }
        let buffer = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let type = depthData.depthDataType
        // OSType 是四字符码，转成可读形式
        let fourCC = String(bytes: [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)
        ], encoding: .ascii) ?? "????"
        report.set(
            "P10",
            value: "\(fourCC) \(width)x\(height)",
            note: "hdis/fdis=disparity, hdep/fdep=depth；已滤波: \(depthData.isDepthDataFiltered)"
        )
    }

    /// P5 与 P9：左右眼镜像关系与眼位单位
    private func measureEyes(_ faceAnchor: ARFaceAnchor) {
        guard faceAnchor.isTracked else { return }

        // 眼位 transform 是 anchor 局部空间，必须左乘 anchor.transform 才是世界坐标。
        // 见 docs/api-facts-arkit-depth.md §1.2
        let leftWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
        let rightWorld = faceAnchor.transform * faceAnchor.rightEyeTransform
        let leftPosition = SIMD3<Float>(
            leftWorld.columns.3.x, leftWorld.columns.3.y, leftWorld.columns.3.z
        )
        let rightPosition = SIMD3<Float>(
            rightWorld.columns.3.x, rightWorld.columns.3.y, rightWorld.columns.3.z
        )

        // P5：在相机空间里比较两眼的 X 分量，判断 left/right 的实际方位
        let viewMatrix = session.currentFrame?.camera.viewMatrix(for: .portrait)
        let leftCameraX: Float
        let rightCameraX: Float
        if let viewMatrix {
            leftCameraX = (viewMatrix * SIMD4(leftPosition, 1)).x
            rightCameraX = (viewMatrix * SIMD4(rightPosition, 1)).x
        } else {
            leftCameraX = leftPosition.x
            rightCameraX = rightPosition.x
        }
        // P5：报告事实与判断规则，不替操作者下结论。
        // ARKit 头文件对 leftEye/rightEyeTransform 的左右语义只字未提
        // （只对 blendShapes 说明了镜像），所以这条探针是唯一能settle它的东西。
        let blinkLeft = faceAnchor.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
        let blinkRight = faceAnchor.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        report.set(
            "P5",
            value: String(
                format: "leftEye.x=%+.4f  rightEye.x=%+.4f  |  眨眼 L=%.2f R=%.2f",
                leftCameraX, rightCameraX, blinkLeft, blinkRight
            ),
            note: """
            判断规则：前置摄像头面对你，摄像头的右手边对应你的左手边，\
            所以你解剖学上的左眼应出现在相机空间的 +X 侧。
            leftEye.x 为正 → leftEyeTransform 指你自己的左眼（无镜像）；
            leftEye.x 为负 → 它按捕获图像的左右命名（镜像），投影时须换向。
            交叉验证：闭上你的左眼，看 L / R 哪个数值涨上去。
            """
        )

        // P9：瞳距。成人正常范围约 50–75 mm；若量出的是 0.050–0.075 说明单位是米。
        let distance = simd_length(leftPosition - rightPosition)
        guard distance.isFinite, distance > 0 else { return }
        pupillaryDistances.append(distance)
        if pupillaryDistances.count > 120 { pupillaryDistances.removeFirst() }
        let mean = pupillaryDistances.reduce(0, +) / Float(pupillaryDistances.count)
        let plausible = (0.050...0.075).contains(mean)
        report.set(
            "P9",
            value: String(format: "%.4f (均值，%d 样本)", mean, pupillaryDistances.count),
            note: plausible
                ? "落在成人瞳距 50–75mm 区间，单位确认为米"
                : "不在预期区间，单位存疑，投影前必须查清"
        )
    }

    /// P6：lookAtPoint 的尺度
    private func measureLookAtPoint(_ faceAnchor: ARFaceAnchor) {
        guard faceAnchor.isTracked else { return }
        let point = faceAnchor.lookAtPoint
        report.set(
            "P6",
            value: String(format: "(%.3f, %.3f, %.3f), 模长 %.3f",
                          point.x, point.y, point.z, simd_length(point)),
            note: "头文件只说「相对 anchor 原点」，未定义距离含义"
        )
    }

    /// P7：faceGeometry 顶点坐标系
    private func measureFaceGeometry(_ faceAnchor: ARFaceAnchor) {
        let vertices = faceAnchor.geometry.vertices
        guard !vertices.isEmpty else { return }
        var minimum = vertices[0]
        var maximum = vertices[0]
        for vertex in vertices {
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        report.set(
            "P7",
            value: String(format: "%d 顶点, x[%.3f,%.3f] y[%.3f,%.3f] z[%.3f,%.3f]",
                          vertices.count,
                          minimum.x, maximum.x, minimum.y, maximum.y, minimum.z, maximum.z),
            note: "极值接近 ±0.1 说明是以头部为中心的局部空间"
        )
    }
}
