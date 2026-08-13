import Foundation

/// `CVPixelBuffer` 深度/视差数据的原始像素存储格式。
///
/// 对应 `CVPixelBuffer.h` 里的四个深度像素格式常量：
/// `kCVPixelFormatType_Disparity/DepthFloat16`（`hdis`/`hdep`，2 字节/像素）、
/// `kCVPixelFormatType_Disparity/DepthFloat32`（`fdis`/`fdep`，4 字节/像素）。
public enum DepthPixelFormat: Sendable {
    case float16
    case float32

    var bytesPerPixel: Int {
        switch self {
        case .float16: return 2
        case .float32: return 4
        }
    }
}

/// 把 `CVPixelBuffer` 拷出的原始字节，按 `bytesPerRow` 解包成逐像素排列、
/// 不含行间 padding 的 `[Float]`。
///
/// **这一层存在的唯一理由是 `bytesPerRow`。**
/// `CVPixelBuffer` 的每行字节数通常大于 `width × 每像素字节数`——为了内存对齐
/// 会有 padding。按 `width` 硬算偏移会逐行累积错位，画面表现为「深度图倾斜/
/// 撕裂」。把它隔离成纯数据变换，就能在 Mac 上用构造的 padding 数据测死。
public enum DepthPixelUnpacking {

    public static func unpack(
        bytes: [UInt8], format: DepthPixelFormat, width: Int, height: Int, bytesPerRow: Int
    ) -> [Float]? {
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = format.bytesPerPixel
        let rowBytesNeeded = width * bytesPerPixel
        guard bytesPerRow >= rowBytesNeeded else { return nil }
        guard bytes.count >= height * bytesPerRow else { return nil }

        var result = [Float]()
        result.reserveCapacity(width * height)

        bytes.withUnsafeBytes { raw in
            for row in 0..<height {
                let rowStart = row * bytesPerRow
                for col in 0..<width {
                    // bytesPerRow 的 padding 可能导致像素偏移不是自然对齐的，
                    // 用 loadUnaligned 而不是 load(fromByteOffset:as:)。
                    let offset = rowStart + col * bytesPerPixel
                    switch format {
                    case .float32:
                        result.append(raw.loadUnaligned(fromByteOffset: offset, as: Float.self))
                    case .float16:
                        let half = raw.loadUnaligned(fromByteOffset: offset, as: Float16.self)
                        result.append(Float(half))
                    }
                }
            }
        }

        return result
    }
}
