import Testing
import Foundation
@testable import ParallaxCore

@Suite("DepthPixelUnpacking")
struct DepthPixelUnpackingTests {

    /// 把 Float32 数组按指定 bytesPerRow 打包成带 padding 的字节流
    private func packFloat32(_ rows: [[Float]], bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8]()
        for row in rows {
            var rowBytes = [UInt8]()
            for v in row { withUnsafeBytes(of: v) { rowBytes.append(contentsOf: $0) } }
            rowBytes.append(contentsOf: [UInt8](repeating: 0xAB, count: bytesPerRow - rowBytes.count))
            out.append(contentsOf: rowBytes)
        }
        return out
    }

    @Test("无 padding 时逐值还原")
    func unpacksTightlyPacked() throws {
        let rows: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let bytes = packFloat32(rows, bytesPerRow: 12)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 3, height: 2, bytesPerRow: 12
        ))
        #expect(out == [1, 2, 3, 4, 5, 6])
    }

    @Test("有 padding 时必须跳过填充字节")
    func skipsRowPadding() throws {
        // 每行 3 个 Float32 = 12 字节，但 bytesPerRow 是 32（padding 20 字节）
        let rows: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let bytes = packFloat32(rows, bytesPerRow: 32)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 3, height: 2, bytesPerRow: 32
        ))
        #expect(out == [1, 2, 3, 4, 5, 6],
                "padding 未被跳过，读到了填充字节：\(out)")
    }

    @Test("Float16 正确转成 Float")
    func unpacksFloat16() throws {
        let values: [Float16] = [0.5, 1.0, 2.0, 4.0]
        var bytes = [UInt8]()
        for v in values { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float16, width: 4, height: 1, bytesPerRow: 8
        ))
        #expect(out == [0.5, 1.0, 2.0, 4.0])
    }

    @Test("NaN 原样保留——过滤是 DepthNormalization 的职责，不是这里的")
    func preservesNaN() throws {
        let rows: [[Float]] = [[Float.nan, 1.0]]
        let bytes = packFloat32(rows, bytesPerRow: 8)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 2, height: 1, bytesPerRow: 8
        ))
        #expect(out[0].isNaN, "NaN 被提前吞掉了，DepthNormalization 就看不到缺失像素")
        #expect(out[1] == 1.0)
    }

    @Test("字节数不足时返回 nil 而不是崩溃")
    func rejectsTruncatedInput() {
        #expect(DepthPixelUnpacking.unpack(
            bytes: [0, 0, 0, 0], format: .float32, width: 3, height: 2, bytesPerRow: 12
        ) == nil)
    }

    @Test("非法尺寸返回 nil")
    func rejectsInvalidGeometry() {
        #expect(DepthPixelUnpacking.unpack(
            bytes: [UInt8](repeating: 0, count: 64), format: .float32,
            width: 0, height: 2, bytesPerRow: 12) == nil)
        // bytesPerRow 小于一行实际所需
        #expect(DepthPixelUnpacking.unpack(
            bytes: [UInt8](repeating: 0, count: 64), format: .float32,
            width: 4, height: 2, bytesPerRow: 8) == nil)
    }
}
