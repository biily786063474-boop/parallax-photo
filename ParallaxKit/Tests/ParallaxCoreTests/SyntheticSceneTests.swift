import Testing
@testable import ParallaxCore

@Suite("SyntheticScene")
struct SyntheticSceneTests {

    @Test("尺寸与像素数一致")
    func dimensionsMatch() throws {
        let scene = try #require(SyntheticScene.layeredBars(width: 64, height: 32))
        #expect(scene.depth.width == 64)
        #expect(scene.depth.height == 32)
        #expect(scene.color.count == 64 * 32 * 4, "RGBA8 应为 w*h*4 字节")
    }

    @Test("深度分层：存在多个不同的深度值")
    func hasMultipleDepthLayers() throws {
        let scene = try #require(SyntheticScene.layeredBars(width: 64, height: 32))
        let distinct = Set(scene.depth.values.map { Int($0 * 100) })
        #expect(distinct.count >= 3, "只有 \(distinct.count) 个深度层，看不出视差")
    }

    @Test("深度落在归一化区间内且无 NaN")
    func depthIsNormalized() throws {
        let scene = try #require(SyntheticScene.layeredBars(width: 64, height: 32))
        for value in scene.depth.values {
            #expect(value.isFinite)
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test("同一竖条内深度一致，跨条不同")
    func barsAreDepthUniform() throws {
        let scene = try #require(SyntheticScene.layeredBars(width: 64, height: 32))
        // 取两行，同一 x 处深度应相同（条纹是竖的）
        for x in 0..<64 {
            #expect(scene.depth[x, 0] == scene.depth[x, 31],
                    "第 \(x) 列上下深度不一致，条纹不是竖直的")
        }
    }

    @Test("非法尺寸返回 nil")
    func rejectsInvalidSize() {
        #expect(SyntheticScene.layeredBars(width: 0, height: 32) == nil)
        #expect(SyntheticScene.layeredBars(width: 64, height: -1) == nil)
    }
}
