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
}
