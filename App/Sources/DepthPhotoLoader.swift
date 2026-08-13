import Foundation
import ImageIO
import AVFoundation
import CoreVideo
import CoreGraphics
import UIKit
import ParallaxCore

/// 从相册照片的原始文件数据里解出彩色图与深度图。
///
/// 完整链路（每个 API 名都对照 `docs/api-facts-arkit-depth.md` §2 核实过，
/// 有两处文档记忆与编译器实测不符，已按编译器改写——见下方标注）：
///
/// `CGImageSourceCreateWithData` → `CGImageSourceGetPrimaryImageIndex` 取主图
/// （HEIC 是多图容器，不能硬写 0）→ 取 disparity/depth 辅助数据字典 →
/// `AVDepthData(fromDictionaryRepresentation:)` → 按 EXIF 方向摆正、彩色图做
/// 同样的摆正 → `CVPixelBuffer` 拷字节 → `DepthPixelUnpacking.unpack`（去
/// `bytesPerRow` padding）→ `DepthNormalization.normalize`（统一到 [0,1]，
/// 0=最远 1=最近）。
///
/// 任何一步失败都返回 `nil`，调用方（`ParallaxApp.swift`）负责把 `nil`
/// 翻译成「这张照片没有深度信息，建议选人像模式拍的」这类可行动提示——
/// 不在这里崩溃、也不在这里决定 UI 文案。
enum DepthPhotoLoader {

    static func load(from data: Data) -> (color: CGImage, depth: DepthMap)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            print("DepthPhotoLoader: 无法解析图片数据（data.count=\(data.count)）")
            fflush(stdout)
            return nil
        }

        // 诊断：实际拿到的容器是什么类型、里面有几张图、主图是第几张——用来
        // 判断 PhotoPicker 那一侧喂进来的到底是 HEIC 原始容器（多图、
        // containerType = public.heic）还是被转码过的东西（转码后通常是单图
        // JPEG，containerType = public.jpeg，imageCount = 1）。真机排查
        // "选了人像照片却没有深度"从这一行日志开始看。
        let containerType = (CGImageSourceGetType(source) as String?) ?? "nil"
        let imageCount = CGImageSourceGetCount(source)
        let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)
        print("DepthPhotoLoader: containerType=\(containerType) imageCount=\(imageCount) "
            + "primaryIndex=\(primaryIndex) data.count=\(data.count)")
        fflush(stdout)

        guard let rawColorImage = CGImageSourceCreateImageAtIndex(source, primaryIndex, nil) else {
            print("DepthPhotoLoader: 无法解出彩色图")
            fflush(stdout)
            return nil
        }

        guard let depthMap = loadDepthMap(source: source, primaryIndex: primaryIndex) else {
            print("DepthPhotoLoader: 这张照片没有可用的深度数据")
            fflush(stdout)
            return nil
        }

        // 彩色图必须做与深度图相同的方向摆正，否则两者像素对不上——见类型注释。
        // `CGImageSourceCreateImageAtIndex` 不会自动按 EXIF 旋转像素数据，
        // 只有 `AVDepthData.applyingExifOrientation(_:)` 帮我们转了深度那一侧。
        let orientation = exifOrientation(source: source, primaryIndex: primaryIndex) ?? .up
        guard let colorImage = orientedCGImage(rawColorImage, exifOrientation: orientation) else {
            print("DepthPhotoLoader: 彩色图方向摆正失败")
            fflush(stdout)
            return nil
        }

        return (colorImage, depthMap)
    }

    // MARK: - 深度

    private static func loadDepthMap(source: CGImageSource, primaryIndex: Int) -> DepthMap? {
        guard let auxDict = auxiliaryDataDictionary(source: source, primaryIndex: primaryIndex) else {
            // 常规原因：这张照片不是人像模式拍的，没有内嵌 disparity/depth。
            // 也可能是"确实是人像照，但取数据的方式把 aux 数据弄丢了"——
            // 上一行的 portraitMatteAux 诊断能帮着分辨这两种情况：matte 若为
            // true 说明系统认定这是人像照，深度理应存在。
            return nil
        }

        // ⚠️ 与简报文档不同：编译器把 `AVDepthData.depthDataFromDictionaryRepresentation`
        // 标记为 unavailable，替代品是这个 throwing 初始化器——已用
        // iphonesimulator SDK 实测确认（编译器是唯一裁判）。
        guard let rawDepthData = try? AVDepthData(fromDictionaryRepresentation: auxDict) else {
            print("DepthPhotoLoader: AVDepthData 构造失败")
            fflush(stdout)
            return nil
        }

        let orientation = exifOrientation(source: source, primaryIndex: primaryIndex) ?? .up
        let depthData = rawDepthData.applyingExifOrientation(orientation)

        guard let (kind, format) = classify(depthDataType: depthData.depthDataType) else {
            print("DepthPhotoLoader: 未识别的深度像素格式 \(depthData.depthDataType)")
            fflush(stdout)
            return nil
        }

        let pixelBuffer = depthData.depthDataMap
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        let byteCount = bytesPerRow * height
        let bytes = [UInt8](UnsafeRawBufferPointer(start: baseAddress, count: byteCount))

        // bytesPerRow 的行 padding 在这里被剥掉——见 ParallaxCore 的
        // DepthPixelUnpackingTests.skipsRowPadding，这是它存在的唯一理由。
        guard let raw = DepthPixelUnpacking.unpack(
            bytes: bytes, format: format, width: width, height: height, bytesPerRow: bytesPerRow
        ) else {
            print("DepthPhotoLoader: 深度像素解包失败（尺寸或 bytesPerRow 不合法）")
            fflush(stdout)
            return nil
        }

        // NaN（未滤波深度图里的缺失像素）在这里被填成「最远」——
        // DepthNormalization 是全项目唯一做深度方向转换的地方，见其类型注释。
        return DepthNormalization.normalize(raw: raw, width: width, height: height, kind: kind)
    }

    private static func auxiliaryDataDictionary(
        source: CGImageSource, primaryIndex: Int
    ) -> [AnyHashable: Any]? {
        // disparity 与 depth 分开查、分开打日志，不合并成一次 `??` 短路——
        // 否则真机上出问题时没法区分"两种 aux 都没有"还是"取到了但后面的类型
        // 判断/构造环节出了别的问题"。顺带查一下 portraitEffectsMatte：
        // 有 matte 说明这确实是人像照，深度也该在，能帮着定位是不是数据在
        // PhotoPicker 那一侧就已经丢了。
        let disparityInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, primaryIndex, kCGImageAuxiliaryDataTypeDisparity
        )
        let depthInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, primaryIndex, kCGImageAuxiliaryDataTypeDepth
        )
        let matteInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, primaryIndex, kCGImageAuxiliaryDataTypePortraitEffectsMatte
        )
        print("DepthPhotoLoader: disparityAux=\(disparityInfo != nil) "
            + "depthAux=\(depthInfo != nil) portraitMatteAux=\(matteInfo != nil)")
        fflush(stdout)

        let raw = disparityInfo ?? depthInfo
        return raw as? [AnyHashable: Any]
    }

    /// 四字符码 → (来源含义, 像素存储格式)。
    /// 依据 docs/api-facts-arkit-depth.md §2.3：`hdis`/`fdis` = disparity，
    /// `hdep`/`fdep` = depth；h 前缀是 Float16，f 前缀是 Float32。
    private static func classify(depthDataType: OSType) -> (DepthSourceKind, DepthPixelFormat)? {
        switch depthDataType {
        case kCVPixelFormatType_DisparityFloat16: return (.disparity, .float16)
        case kCVPixelFormatType_DisparityFloat32: return (.disparity, .float32)
        case kCVPixelFormatType_DepthFloat16: return (.depth, .float16)
        case kCVPixelFormatType_DepthFloat32: return (.depth, .float32)
        default: return nil
        }
    }

    // MARK: - 方向

    private static func exifOrientation(
        source: CGImageSource, primaryIndex: Int
    ) -> CGImagePropertyOrientation? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, primaryIndex, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32
        else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }

    /// 把 EXIF 方向"烤"进像素数据：`CGImageSourceCreateImageAtIndex` 拿到的
    /// `CGImage` 是传感器原始朝向，不会自动旋转；这里用 `UIImage` 的方向语义
    /// 重绘一遍，让输出的 `CGImage` 像素本身就是摆正后的样子，
    /// 和已经调用过 `applyingExifOrientation` 的深度图保持一致。
    ///
    /// 副作用：重绘顺带把 `CGImage` 的 `bytesPerRow` 变成紧凑排列，
    /// 但 Task 3 的渲染器仍会自己再做一遍紧凑化处理——这里不替它做保证。
    private static func orientedCGImage(_ image: CGImage, exifOrientation: CGImagePropertyOrientation) -> CGImage? {
        let uiImage = UIImage(cgImage: image, scale: 1, orientation: uiOrientation(from: exifOrientation))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: uiImage.size, format: format)
        let rendered = renderer.image { _ in
            uiImage.draw(at: CGPoint.zero)
        }
        return rendered.cgImage
    }

    private static func uiOrientation(from cg: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch cg {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        }
    }
}
