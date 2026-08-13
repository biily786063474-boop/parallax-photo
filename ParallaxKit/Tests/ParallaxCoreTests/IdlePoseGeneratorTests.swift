import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("IdlePoseGenerator")
struct IdlePoseGeneratorTests {

    static let generator = IdlePoseGenerator()

    @Test("输出始终在振幅范围内")
    func staysWithinAmplitude() {
        let g = IdlePoseGenerator(amplitude: SIMD2(0.04, 0.03), distance: 0.35)
        for step in 0..<2000 {
            let pose = g.pose(at: TimeInterval(step) * 0.05)
            #expect(abs(pose.x) <= 0.04 + 1e-6)
            #expect(abs(pose.y) <= 0.03 + 1e-6)
            #expect(pose.z == 0.35)
        }
    }

    @Test("相邻帧之间变化足够小，不会产生跳变")
    func isContinuous() {
        var previous = Self.generator.pose(at: 0)
        // 按 120fps 采样，相邻帧位移应远小于毫米级
        for step in 1..<2000 {
            let current = Self.generator.pose(at: TimeInterval(step) / 120.0)
            let delta = simd_length(current - previous)
            #expect(delta < 0.001, "第 \(step) 帧跳变 \(delta) 米")
            previous = current
        }
    }

    @Test("两轴周期不成简单整数比，轨迹不会快速重复")
    func trajectoryDoesNotRepeatQuickly() {
        let g = Self.generator
        let start = g.pose(at: 0)
        var closestApproach = Float.greatestFiniteMagnitude
        // 在 60 秒内寻找是否回到起点附近（跳过开头几秒避免自比）
        for step in 100..<6000 {
            let t = TimeInterval(step) * 0.01
            closestApproach = min(closestApproach, simd_length(g.pose(at: t) - start))
        }
        // 轨迹会接近但不应精确重合
        #expect(closestApproach > 1e-4, "轨迹在 60 秒内精确重复了")
    }

    @Test("输出全部有限")
    func outputIsFinite() {
        for step in 0..<1000 {
            let pose = Self.generator.pose(at: TimeInterval(step) * 0.37)
            #expect(pose.x.isFinite && pose.y.isFinite && pose.z.isFinite)
        }
    }

    @Test("零时刻从中心附近出发")
    func startsNearCenter() {
        let pose = Self.generator.pose(at: 0)
        #expect(abs(pose.x) < 1e-6)
        #expect(abs(pose.y) < 1e-6)
    }

    // MARK: - 锚点支持（追踪丢失后应绕最后已知眼位摆动，而不是绕屏幕中心）

    @Test("offset(at: 0) 是零向量——李萨如两轴都从 sin(0)=0 出发")
    func offsetAtZeroIsZeroVector() {
        let offset = Self.generator.offset(at: 0)
        #expect(offset == SIMD3<Float>(0, 0, 0))
    }

    @Test("绕锚点摆动时，t=0 精确落在锚点上：接管瞬间不产生任何位移")
    func poseAroundAnchorStartsExactlyAtAnchorAtTimeZero() {
        let anchor = SIMD3<Float>(0.12, -0.08, 0.42)
        let pose = Self.generator.pose(at: 0, around: anchor)
        #expect(pose == anchor)
    }

    @Test("绕锚点摆动 == 锚点 + offset")
    func poseAroundAnchorEqualsAnchorPlusOffset() {
        let g = Self.generator
        let anchor = SIMD3<Float>(0.1, 0.05, 0.5)
        for step in 0..<200 {
            let t = TimeInterval(step) * 0.037
            let pose = g.pose(at: t, around: anchor)
            let expected = anchor + g.offset(at: t)
            #expect(simd_length(pose - expected) < 1e-6)
        }
    }

    @Test("既有 pose(at:) 等价于绕屏幕正前方 distance 处摆动")
    func defaultPoseEquivalentToAroundDefaultAnchor() {
        let g = Self.generator
        let defaultAnchor = SIMD3<Float>(0, 0, g.distance)
        for step in 0..<200 {
            let t = TimeInterval(step) * 0.053
            let viaDefault = g.pose(at: t)
            let viaAnchor = g.pose(at: t, around: defaultAnchor)
            #expect(simd_length(viaDefault - viaAnchor) < 1e-6)
        }
    }

    @Test("绕任意锚点摆动时，偏移量仍在振幅范围内")
    func offsetStaysWithinAmplitudeRegardlessOfAnchor() {
        let g = IdlePoseGenerator(amplitude: SIMD2(0.04, 0.03), distance: 0.35)
        let anchors: [SIMD3<Float>] = [
            SIMD3(0, 0, 0.35),
            SIMD3(1.0, -0.5, 2.0),
            SIMD3(-3.2, 4.1, 0.1),
        ]
        for anchor in anchors {
            for step in 0..<500 {
                let t = TimeInterval(step) * 0.05
                let pose = g.pose(at: t, around: anchor)
                let delta = pose - anchor
                #expect(abs(delta.x) <= 0.04 + 1e-6)
                #expect(abs(delta.y) <= 0.03 + 1e-6)
                #expect(delta.z == 0)
            }
        }
    }
}
