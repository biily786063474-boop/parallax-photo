import Testing
import Foundation
@testable import ParallaxCore

@Suite("DepthNormalization")
struct DepthNormalizationTests {

    @Test("尺寸与数据量不匹配时构造失败")
    func rejectsMismatchedSize() {
        #expect(DepthMap(width: 2, height: 2, values: [1, 2, 3]) == nil)
        #expect(DepthMap(width: 0, height: 5, values: []) == nil)
    }

    @Test("含非有限值时构造失败")
    func rejectsNonFiniteValues() {
        #expect(DepthMap(width: 2, height: 1, values: [0.5, .nan]) == nil)
        #expect(DepthMap(width: 2, height: 1, values: [0.5, .infinity]) == nil)
    }

    @Test("合法数据构造成功且可下标访问")
    func acceptsValidData() throws {
        let map = try #require(DepthMap(width: 2, height: 2, values: [0, 0.25, 0.5, 1]))
        #expect(map[0, 0] == 0)
        #expect(map[1, 0] == 0.25)
        #expect(map[0, 1] == 0.5)
        #expect(map[1, 1] == 1)
    }

    @Test("disparity：值越大越近，映射到越接近 1")
    func disparityMapsLargeToNear() throws {
        let raw: [Float] = [0, 1, 2, 3]
        let map = try #require(DepthNormalization.normalize(
            raw: raw, width: 2, height: 2, kind: .disparity, percentileClip: 0
        ))
        #expect(map.values[0] < map.values[3])
        #expect(abs(map.values[0] - 0) < 1e-5)
        #expect(abs(map.values[3] - 1) < 1e-5)
    }

    @Test("depth：值越大越远，映射到越接近 0")
    func depthMapsLargeToFar() throws {
        let raw: [Float] = [0.5, 1.0, 1.5, 2.0]   // 米
        let map = try #require(DepthNormalization.normalize(
            raw: raw, width: 2, height: 2, kind: .depth, percentileClip: 0
        ))
        #expect(map.values[0] > map.values[3], "0.5 米应该比 2.0 米更近")
        #expect(abs(map.values[0] - 1) < 1e-5)
        #expect(abs(map.values[3] - 0) < 1e-5)
    }

    @Test("输出永远落在 [0,1] 且不含 NaN")
    func outputIsAlwaysNormalized() throws {
        let raw: [Float] = [.nan, 0, 100, -5, .infinity, 3, 3, 3]
        let map = try #require(DepthNormalization.normalize(
            raw: raw, width: 4, height: 2, kind: .disparity
        ))
        for value in map.values {
            #expect(value.isFinite, "输出含非有限值")
            #expect(value >= 0 && value <= 1, "输出 \(value) 越界")
        }
    }

    @Test("缺失像素被填成最远，不是最近")
    func missingPixelsBecomeFarthest() throws {
        // 缺失像素通常在物体边缘或远处，填成最近会在画面里凸出一块假前景
        let raw: [Float] = [1, 2, 3, .nan]
        let map = try #require(DepthNormalization.normalize(
            raw: raw, width: 2, height: 2, kind: .disparity, percentileClip: 0
        ))
        #expect(abs(map.values[3] - 0) < 1e-5, "NaN 应填成 0（最远），实为 \(map.values[3])")
    }

    @Test("全为常量时退化为平面而非崩溃")
    func constantInputDegradesGracefully() throws {
        let map = try #require(DepthNormalization.normalize(
            raw: [7, 7, 7, 7], width: 2, height: 2, kind: .disparity
        ))
        for value in map.values {
            #expect(value.isFinite)
            #expect(abs(value - 0.5) < 1e-5, "常量深度应退化为 0.5 的平面")
        }
    }

    @Test("全为 NaN 时退化为平面")
    func allNaNDegradesGracefully() throws {
        let map = try #require(DepthNormalization.normalize(
            raw: [.nan, .nan, .nan, .nan], width: 2, height: 2, kind: .disparity
        ))
        for value in map.values {
            #expect(abs(value - 0.5) < 1e-5)
        }
    }

    @Test("百分位裁剪抑制离群点对动态范围的压缩")
    func percentileClipPreservesDynamicRange() throws {
        // 99 个值在 [0,1]，一个离群点 1000。不裁剪的话正常范围会被压成几乎全 0。
        var raw = (0..<99).map { Float($0) / 98.0 }
        raw.append(1000)
        let clipped = try #require(DepthNormalization.normalize(
            raw: raw, width: 10, height: 10, kind: .disparity, percentileClip: 0.02
        ))
        let unclipped = try #require(DepthNormalization.normalize(
            raw: raw, width: 10, height: 10, kind: .disparity, percentileClip: 0
        ))
        let clippedSpread = clipped.values[0..<99].max()! - clipped.values[0..<99].min()!
        let unclippedSpread = unclipped.values[0..<99].max()! - unclipped.values[0..<99].min()!
        #expect(clippedSpread > unclippedSpread * 10,
                "裁剪后动态范围 \(clippedSpread) 未显著优于未裁剪 \(unclippedSpread)")
    }

    @Test("空输入返回 nil")
    func emptyInputReturnsNil() {
        #expect(DepthNormalization.normalize(
            raw: [], width: 0, height: 0, kind: .disparity
        ) == nil)
    }
}
