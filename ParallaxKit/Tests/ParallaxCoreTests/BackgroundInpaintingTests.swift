import Testing
@testable import ParallaxCore

@Suite("BackgroundInpainting")
struct BackgroundInpaintingTests {

    /// 构造纯色图：w×h，全部 RGBA = (r,g,b,255)
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int, h: Int) -> [UInt8] {
        var out = [UInt8]()
        for _ in 0..<(w * h) { out.append(contentsOf: [r, g, b, 255]) }
        return out
    }

    @Test("没有洞时原样返回")
    func noHolesIsIdentity() throws {
        let pixels = solid(10, 20, 30, w: 4, h: 4)
        let mask = [Float](repeating: 0, count: 16)
        let out = try #require(BackgroundInpainting.fill(
            pixels: pixels, width: 4, height: 4, holeMask: mask))
        #expect(out == pixels)
    }

    @Test("洞被非洞邻域的颜色填上，不是黑色")
    func fillsHoleWithNeighbourColour() throws {
        var pixels = solid(200, 100, 50, w: 8, h: 8)
        var mask = [Float](repeating: 0, count: 64)
        // 中间 2×2 挖成洞，并把洞里的像素涂成黑色（模拟前景被剔除）
        for y in 3...4 {
            for x in 3...4 {
                mask[y * 8 + x] = 1
                let i = (y * 8 + x) * 4
                pixels[i] = 0; pixels[i+1] = 0; pixels[i+2] = 0
            }
        }
        let out = try #require(BackgroundInpainting.fill(
            pixels: pixels, width: 8, height: 8, holeMask: mask))
        // 洞里应被周围的 (200,100,50) 填上，允许金字塔插值带来的偏差
        let i = (3 * 8 + 3) * 4
        #expect(out[i] > 150, "洞未被填充，R=\(out[i])")
        #expect(abs(Int(out[i+1]) - 100) < 40, "G 偏离邻域太多：\(out[i+1])")
    }

    @Test("非洞区域一个像素都不许被改动")
    func preservesNonHolePixels() throws {
        var pixels = solid(200, 100, 50, w: 8, h: 8)
        var mask = [Float](repeating: 0, count: 64)
        for y in 3...4 { for x in 3...4 { mask[y * 8 + x] = 1 } }
        // 给一个非洞像素涂上独特颜色
        let mark = (0 * 8 + 0) * 4
        pixels[mark] = 7; pixels[mark+1] = 8; pixels[mark+2] = 9
        let out = try #require(BackgroundInpainting.fill(
            pixels: pixels, width: 8, height: 8, holeMask: mask))
        #expect(out[mark] == 7 && out[mark+1] == 8 && out[mark+2] == 9,
                "非洞像素被改动了")
    }

    @Test("全是洞时不崩溃，返回有限结果")
    func allHolesDegradesGracefully() throws {
        let pixels = solid(200, 100, 50, w: 4, h: 4)
        let mask = [Float](repeating: 1, count: 16)
        let out = try #require(BackgroundInpainting.fill(
            pixels: pixels, width: 4, height: 4, holeMask: mask))
        #expect(out.count == pixels.count)
    }

    @Test("尺寸不匹配返回 nil")
    func rejectsMismatchedSizes() {
        #expect(BackgroundInpainting.fill(
            pixels: [UInt8](repeating: 0, count: 16), width: 4, height: 4,
            holeMask: [Float](repeating: 0, count: 8)) == nil)
        #expect(BackgroundInpainting.fill(
            pixels: [], width: 0, height: 0,
            holeMask: []) == nil)
    }

    @Test("alpha 通道保持不透明")
    func keepsAlphaOpaque() throws {
        var pixels = solid(200, 100, 50, w: 8, h: 8)
        var mask = [Float](repeating: 0, count: 64)
        for y in 3...4 { for x in 3...4 { mask[y * 8 + x] = 1; pixels[(y*8+x)*4+3] = 0 } }
        let out = try #require(BackgroundInpainting.fill(
            pixels: pixels, width: 8, height: 8, holeMask: mask))
        for i in stride(from: 3, to: out.count, by: 4) {
            #expect(out[i] == 255, "第 \(i/4) 个像素的 alpha 不是 255")
        }
    }
}

/// `fillScalar`：`BackgroundInpainting.fill` 的单通道浮点版本，给背景层的
/// 深度图用——真机反馈"物品和背景衔接的地方还是有大量锯齿"追查下来，两层
/// LDI 里背景层深度被断崖式压到远平面（0）是背景层自身的几何台阶，跨越它的
/// 三角形同样会被拉成陡坡，锯齿从前景层转移到了背景层而不是被消除。
/// 修法与背景色的处理完全对称：外扩填补而不是硬编码成 0。
///
/// 测试结构故意跟上面 `BackgroundInpaintingTests` 逐条对应（无洞恒等、
/// 邻域填补、非洞值不改、全洞不崩、尺寸校验）——同一套 push-pull 金字塔
/// 思路，只是 RGB 三通道换成一个 Float，覆盖面理应完全对称。额外加一条
/// `maxAdjacentJumpShrinksAfterFill`，这条直接对应本次要修的问题本身：
/// 断崖式压平 vs 外扩填补，边界的最大跳变必须有数量级级别的差异。
@Suite("BackgroundInpainting.fillScalar")
struct BackgroundInpaintingScalarTests {

    @Test("没有洞时原样返回")
    func noHolesIsIdentity() throws {
        let values: [Float] = (0..<16).map { Float($0) / 16 }
        let mask = [Float](repeating: 0, count: 16)
        let out = try #require(BackgroundInpainting.fillScalar(
            values: values, width: 4, height: 4, holeMask: mask))
        #expect(out == values)
    }

    @Test("洞被非洞邻域的值填上，不是 0")
    func fillsHoleWithNeighbourValue() throws {
        var values = [Float](repeating: 0.9, count: 64) // 8x8，背景深度均一
        var mask = [Float](repeating: 0, count: 64)
        // 中间 2×2 挖成洞，洞里存的是前景真实深度（0.1，任意值——算法必须
        // 无视它，不是巧合般凑对了才通过）。
        for y in 3...4 {
            for x in 3...4 {
                mask[y * 8 + x] = 1
                values[y * 8 + x] = 0.1
            }
        }
        let out = try #require(BackgroundInpainting.fillScalar(
            values: values, width: 8, height: 8, holeMask: mask))
        let i = 3 * 8 + 3
        #expect(out[i] > 0.7, "洞未被周围背景值(0.9)填上，实际=\(out[i])")
    }

    @Test("非洞值一个都不许被改动")
    func preservesNonHoleValues() throws {
        var values = [Float](repeating: 0.9, count: 64)
        var mask = [Float](repeating: 0, count: 64)
        for y in 3...4 { for x in 3...4 { mask[y * 8 + x] = 1 } }
        // 给一个非洞像素标记一个独特值
        values[0] = 0.1234
        let out = try #require(BackgroundInpainting.fillScalar(
            values: values, width: 8, height: 8, holeMask: mask))
        #expect(out[0] == 0.1234, "非洞值被改动了：\(out[0])")
    }

    @Test("全是洞时不崩溃，返回有限结果")
    func allHolesDegradesGracefully() throws {
        let values = [Float](repeating: 0.5, count: 16)
        let mask = [Float](repeating: 1, count: 16)
        let out = try #require(BackgroundInpainting.fillScalar(
            values: values, width: 4, height: 4, holeMask: mask))
        #expect(out.count == values.count)
        #expect(out.allSatisfy { $0.isFinite }, "结果里出现了非有限值：\(out)")
    }

    @Test("尺寸不匹配返回 nil")
    func rejectsMismatchedSizes() {
        #expect(BackgroundInpainting.fillScalar(
            values: [Float](repeating: 0, count: 16), width: 4, height: 4,
            holeMask: [Float](repeating: 0, count: 8)) == nil)
        #expect(BackgroundInpainting.fillScalar(
            values: [], width: 0, height: 0, holeMask: []) == nil)
    }

    @Test("填补后相邻像素的最大跳变显著小于压到远平面")
    func maxAdjacentJumpShrinksAfterFill() throws {
        let width = 8, height = 8
        var values = [Float](repeating: 0.9, count: width * height) // 均一背景深度
        var mask = [Float](repeating: 0, count: width * height)
        for y in 3...4 {
            for x in 3...4 {
                mask[y * width + x] = 1
                values[y * width + x] = 0.1 // 洞里存前景真实深度，算法应无视它
            }
        }

        // "压平前"独立于 fillScalar 计算：直接复现上一轮真正在跑的代码
        // （`ParallaxRenderer.makeLayeredTextures` 里的 `backgroundDepthValues[i]
        // = 0`），不经过被测函数——否则如果被测函数本身被改坏，这条"压平前"
        // 基准也会跟着一起坏，测试就失去了对比意义。
        var compressedToFarPlane = values
        for i in 0..<compressedToFarPlane.count where mask[i] >= 0.5 {
            compressedToFarPlane[i] = 0
        }
        let jumpBefore = maxAdjacentJump(compressedToFarPlane, width: width, height: height)

        let filled = try #require(BackgroundInpainting.fillScalar(
            values: values, width: width, height: height, holeMask: mask))
        let jumpAfter = maxAdjacentJump(filled, width: width, height: height)

        #expect(jumpAfter < jumpBefore * 0.1,
                "填补后最大跳变(\(jumpAfter))未显著小于压平后的最大跳变(\(jumpBefore))")
    }

    /// 相邻像素（右邻 + 下邻）的最大绝对值跳变。
    private func maxAdjacentJump(_ values: [Float], width: Int, height: Int) -> Float {
        var maxJump: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                if x + 1 < width { maxJump = max(maxJump, abs(values[i] - values[i + 1])) }
                if y + 1 < height { maxJump = max(maxJump, abs(values[i] - values[i + width])) }
            }
        }
        return maxJump
    }
}
