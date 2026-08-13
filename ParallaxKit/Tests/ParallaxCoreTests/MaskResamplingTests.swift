import Testing
@testable import ParallaxCore

@Suite("MaskResampling")
struct MaskResamplingTests {

    @Test("等尺寸时原样返回")
    func sameSizeIsIdentity() throws {
        let mask: [Float] = [0, 0.25, 0.5, 0.75, 1, 0.1, 0.2, 0.3, 0.9]
        let out = try #require(MaskResampling.resample(
            mask: mask, from: (width: 3, height: 3), to: (width: 3, height: 3)))
        #expect(out == mask)
    }

    @Test("放大后四角值不变")
    func upscalePreservesCorners() throws {
        // 2×2 输入，四角各不相同，方便逐一核对。
        let mask: [Float] = [0.0, 0.3,
                              0.6, 1.0]
        let out = try #require(MaskResampling.resample(
            mask: mask, from: (width: 2, height: 2), to: (width: 5, height: 5)))
        #expect(out.count == 25)
        #expect(abs(out[0] - 0.0) < 1e-5, "左上角应为 0.0，实为 \(out[0])")    // (0,0)
        #expect(abs(out[4] - 0.3) < 1e-5, "右上角应为 0.3，实为 \(out[4])")    // (4,0)
        #expect(abs(out[20] - 0.6) < 1e-5, "左下角应为 0.6，实为 \(out[20])")  // (0,4)
        #expect(abs(out[24] - 1.0) < 1e-5, "右下角应为 1.0，实为 \(out[24])")  // (4,4)
    }

    @Test("放大时中间像素是双线性混合值，不是最近邻拷贝")
    func upscaleInteriorIsBilinearBlend() throws {
        // 1×2 渐变放大到 1×4：双线性会在中间产生 0.25 / 0.75 的过渡值，
        // 最近邻只会拷贝原始的 0 或 1，两者在这两个像素上必然不同。
        let mask: [Float] = [0, 1]
        let out = try #require(MaskResampling.resample(
            mask: mask, from: (width: 2, height: 1), to: (width: 4, height: 1)))
        #expect(out.count == 4)
        #expect(abs(out[0] - 0.0) < 1e-5, "首像素应为 0.0，实为 \(out[0])")
        #expect(abs(out[1] - 0.25) < 1e-5, "双线性应给出 0.25 的过渡值，最近邻只会是 0 或 1，实为 \(out[1])")
        #expect(abs(out[2] - 0.75) < 1e-5, "双线性应给出 0.75 的过渡值，最近邻只会是 0 或 1，实为 \(out[2])")
        #expect(abs(out[3] - 1.0) < 1e-5, "末像素应为 1.0，实为 \(out[3])")
    }

    @Test("缩小后值域仍在 [0,1]")
    func downscaleStaysInUnitRange() throws {
        // 6×6 棋盘格（0/1 交替），是最容易在降采样加权平均里
        // 因浮点误差被推出 [0,1] 边界的构造。
        var mask = [Float](repeating: 0, count: 36)
        for y in 0..<6 {
            for x in 0..<6 {
                mask[y * 6 + x] = (x + y) % 2 == 0 ? 1 : 0
            }
        }
        let out = try #require(MaskResampling.resample(
            mask: mask, from: (width: 6, height: 6), to: (width: 3, height: 3)))
        #expect(out.count == 9)
        for v in out {
            #expect(v >= 0 && v <= 1, "值域越界：\(v)")
        }
    }

    @Test("非法尺寸返回 nil")
    func rejectsInvalidSizes() {
        // mask 长度与 from 尺寸不匹配
        #expect(MaskResampling.resample(
            mask: [Float](repeating: 0, count: 9),
            from: (width: 4, height: 4), to: (width: 2, height: 2)) == nil)
        // from 尺寸非法
        #expect(MaskResampling.resample(
            mask: [], from: (width: 0, height: 0), to: (width: 2, height: 2)) == nil)
        // to 尺寸非法
        #expect(MaskResampling.resample(
            mask: [Float](repeating: 0, count: 4),
            from: (width: 2, height: 2), to: (width: 0, height: 3)) == nil)
    }

    @Test("含 NaN 的输入不产生 NaN 输出")
    func nanInputProducesNoNaNOutput() throws {
        var mask = [Float](repeating: 0.5, count: 9) // 3×3
        mask[4] = .nan // 中心像素
        let out = try #require(MaskResampling.resample(
            mask: mask, from: (width: 3, height: 3), to: (width: 5, height: 5)))
        #expect(out.count == 25)
        for v in out {
            #expect(v.isFinite, "输出含非有限值：\(v)")
            #expect(v >= 0 && v <= 1, "输出越界：\(v)")
        }
    }
}
