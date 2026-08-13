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
