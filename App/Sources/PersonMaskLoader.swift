import Foundation
import Vision
import ImageIO
import CoreVideo
import CoreGraphics
import ParallaxCore

/// 分割遮罩：与 `ParallaxCore` 的 `DepthMap` 同构（width/height/values），
/// 但语义不同——值域 [0,1]，**1 = 前景（人像/主体），0 = 背景**，不是深度。
///
/// 故意不放进 `ParallaxCore`：它只是 Vision 输出的薄包装（一次 `CVPixelBuffer`
/// 读取 + `bytesPerRow` 去 padding），不涉及任何这一层值得单独 TDD 的数值
/// 变换——真正需要测试、也已经测过的数值变换（重采样、外扩填补）都在 Core 里，
/// 见 `MaskResampling` / `BackgroundInpainting`。这里的原始 values 未必严格
/// 落在 [0,1]（Vision 没有书面契约保证），下游一律经 `MaskResampling.resample`
/// 再用（它的"出口保证"会做 NaN/越界 sanitize），不要直接拿 `values` 上传纹理。
struct MaskMap {
    let width: Int
    let height: Int
    let values: [Float]
}

/// 用 Vision 的实例分割拿到人像/主体的精确边界，供两层渲染的前景层剔除
/// 遮罩外片元、背景层做外扩填补用（见 `ParallaxRenderer`）。
///
/// **TDD 例外**（简报原话）：Vision 请求的正确性无法用断言表达，把关点是
/// `make app-build` 通过 + 真机看到边缘改善——这个文件没有配套的单元测试。
///
/// 降级链（简报 Task 3 要点 5）：
/// 1. `VNGeneratePersonInstanceMaskRequest`——针对人的实例分割，本 app 的
///    主场景（人像照片）。
/// 2. 无人（`results` 为空或没有实例）→ `VNGenerateForegroundInstanceMaskRequest`
///    ——iOS 17 起可用，调用形状与①完全一致（同样产出 `VNInstanceMaskObservation`），
///    覆盖"有明显主体但不是人"的照片。
/// 3. 两条都拿不到实例 → 返回 `nil`，调用方（`ParallaxRenderer`）据此退回
///    单层渲染，不能因为分割失败就黑屏或崩溃。
///
/// 全部 API 名已用 `swiftc -typecheck`（iphonesimulator SDK，见
/// `docs/api-facts-arkit-depth.md` §4 的验证法）逐个确认过，包括容易被当成
/// ObjC 直译坑的 `generateScaledMaskForImage(forInstances:from:)`。
enum PersonMaskLoader {

    /// - Parameter cgImage: **必须是已经按 EXIF 方向摆正过的彩色图**——即
    ///   `DepthPhotoLoader.load` 里 `orientedCGImage(...)` 之后的那张 `color`，
    ///   不是相册原始字节里刚解出来、还没摆正的那张。因此这里恒传
    ///   `orientation: .up`：图像像素本身已经是"正的"，不需要 Vision 再做
    ///   一次方向修正。
    ///
    ///   这不是偷懒，是刻意的设计取舍：如果改成"喂未摆正的原图 + 传原始
    ///   EXIF 方向给 Vision"，遮罩的摆正就变成了跟彩色图（`orientedCGImage`
    ///   用 `UIGraphicsImageRenderer` 重绘）、深度图（`AVDepthData.
    ///   applyingExifOrientation`）各自独立的第三条旋转路径——三条路径的
    ///   旋转语义只要有一丝出入，就是简报警告的"遮罩比人物偏了一点"那种
    ///   看得见却说不清的错误。让遮罩从跟彩色图/深度图完全同一张、同一次
    ///   摆正后的图像派生，从根上消除这种出入的可能性，这正是"三者共用
    ///   同一套 UV 约定"的落地方式。
    /// - Returns: 遮罩尺寸精确等于 `cgImage` 分辨率（Vision 文档实测确认，
    ///   见简报"已核实的 Vision 事实"表）；两条请求都没有可用实例时返回
    ///   `nil`。
    static func loadMask(cgImage: CGImage) -> MaskMap? {
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        if let mask = personMask(handler: handler) {
            return mask
        }
        return foregroundMask(handler: handler)
    }

    private static func personMask(handler: VNImageRequestHandler) -> MaskMap? {
        let request = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            print("PersonMaskLoader: VNGeneratePersonInstanceMaskRequest 失败: \(error.localizedDescription)")
            fflush(stdout)
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            print("PersonMaskLoader: 未检测到人像实例，尝试前景兜底")
            fflush(stdout)
            return nil
        }
        return extractMask(observation: observation, handler: handler, label: "person")
    }

    private static func foregroundMask(handler: VNImageRequestHandler) -> MaskMap? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            print("PersonMaskLoader: VNGenerateForegroundInstanceMaskRequest 失败: \(error.localizedDescription)")
            fflush(stdout)
            return nil
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            print("PersonMaskLoader: 前景兜底也未检测到可分割的主体，退回单层渲染")
            fflush(stdout)
            return nil
        }
        return extractMask(observation: observation, handler: handler, label: "foreground")
    }

    /// - Parameter handler: **必须是执行了该 observation 所属请求的同一个
    ///   `VNImageRequestHandler`**——`generateScaledMaskForImage` 要重读源图
    ///   （简报坑①），传别的 handler 或已释放的 handler 会失败。`personMask`/
    ///   `foregroundMask` 各自持有自己那个 handler 局部变量直到这个函数返回，
    ///   满足这个前提。
    private static func extractMask(
        observation: VNInstanceMaskObservation, handler: VNImageRequestHandler, label: String
    ) -> MaskMap? {
        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler
            )
        } catch {
            print("PersonMaskLoader: generateScaledMaskForImage(\(label)) 失败: \(error.localizedDescription)")
            fflush(stdout)
            return nil
        }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent32Float else {
            print("PersonMaskLoader: 遮罩像素格式不是预期的 OneComponent32Float（\(label)）")
            fflush(stdout)
            return nil
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        // 与 DepthPhotoLoader 读 depthDataMap 的手法完全一致：先整段拷字节，
        // 再交给 DepthPixelUnpacking 去 bytesPerRow 的行 padding——遮罩这里是
        // 单通道 32-bit float，正好复用 .float32 分支，不需要为它另写一套
        // 解包逻辑（同一类坑，Plan 3 Task 1 已经踩过一次）。
        let byteCount = bytesPerRow * height
        let bytes = [UInt8](UnsafeRawBufferPointer(start: baseAddress, count: byteCount))

        guard let values = DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: width, height: height, bytesPerRow: bytesPerRow
        ) else {
            print("PersonMaskLoader: 遮罩像素解包失败（尺寸或 bytesPerRow 不合法，\(label)）")
            fflush(stdout)
            return nil
        }

        print("PersonMaskLoader: \(label) 遮罩加载成功，\(width)x\(height)")
        fflush(stdout)
        return MaskMap(width: width, height: height, values: values)
    }

    // MARK: - 冷启动预热（简报要点 6）

    /// Vision 的分割模型首次调用有 0.7–2.3s 冷启动（模型加载，见简报"已核实的
    /// Vision 事实"表），足够让用户选第一张照片后感觉明显卡顿。这里在 app
    /// 启动后立刻用一张程序化生成的小图在后台空跑一次请求，把模型加载这部分
    /// 开销提前花掉——结果直接丢弃，只要模型进了内存。
    ///
    /// 顺带效果：`loadMask` 内部走完整降级链，一张纯灰色图必然检测不到人，
    /// 所以这一次预热会**依次**把人像与前景两个模型都预热到，而不只是第一个。
    ///
    /// `.utility` QoS：这是"最好在用户真正需要之前完成，但不差这一两秒"的
    /// 后台任务，不该跟 `tick()`（显示心跳）抢线程优先级。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let image = warmUpImage else {
                print("PersonMaskLoader: 预热用图像构造失败，跳过预热")
                fflush(stdout)
                return
            }
            let start = Date()
            _ = loadMask(cgImage: image)
            print("PersonMaskLoader: 预热完成，耗时 \(Date().timeIntervalSince(start))s")
            fflush(stdout)
        }
    }

    /// 64×64 纯灰图——预热只关心"把模型 load 进内存"这件事本身，
    /// 内容和尺寸都无关紧要，选小尺寸只是为了让这次空跑尽快完成。
    private static var warmUpImage: CGImage? {
        let side = 64
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
