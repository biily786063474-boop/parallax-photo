import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("OneEuroFilter")
struct OneEuroFilterTests {

    @Test("首次采样原样返回")
    func firstSampleIsPassthrough() {
        var f = OneEuroFilter()
        #expect(f.filter(3.5, timestamp: 0) == 3.5)
    }

    @Test("常量输入收敛到该常量")
    func constantInputConverges() {
        var f = OneEuroFilter()
        var out: Float = 0
        for i in 0..<200 {
            out = f.filter(5.0, timestamp: TimeInterval(i) / 60.0)
        }
        #expect(abs(out - 5.0) < 1e-3)
    }

    @Test("高频噪声被显著抑制")
    func suppressesNoise() {
        var f = OneEuroFilter(minCutoff: 1.0, beta: 0.0, derivativeCutoff: 1.0)
        var inputs: [Float] = []
        var outputs: [Float] = []
        // 确定性的伪随机噪声，围绕 0 摆动
        var seed: UInt64 = 42
        func nextNoise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
        }
        for i in 0..<300 {
            let x = nextNoise()
            inputs.append(x)
            outputs.append(f.filter(x, timestamp: TimeInterval(i) / 60.0))
        }
        // 丢掉前 50 个样本的收敛期
        let inVar = variance(Array(inputs.dropFirst(50)))
        let outVar = variance(Array(outputs.dropFirst(50)))
        #expect(outVar < inVar * 0.5, "输出方差 \(outVar) 未显著低于输入方差 \(inVar)")
    }

    @Test("阶跃响应单调趋近且不过冲")
    func stepResponseHasNoOvershoot() {
        var f = OneEuroFilter()
        for i in 0..<30 { _ = f.filter(0, timestamp: TimeInterval(i) / 60.0) }
        var previous: Float = 0
        for i in 30..<200 {
            let out = f.filter(1.0, timestamp: TimeInterval(i) / 60.0)
            #expect(out >= previous - 1e-6, "在第 \(i) 步出现回退，不是单调趋近")
            #expect(out <= 1.0 + 1e-4, "在第 \(i) 步过冲到 \(out)")
            previous = out
        }
        #expect(previous > 0.9, "200 步后仍未趋近目标，收敛太慢：\(previous)")
    }

    @Test("时间戳倒退或重复不产生 NaN")
    func handlesNonMonotonicTimestamps() {
        var f = OneEuroFilter()
        _ = f.filter(1.0, timestamp: 10.0)
        let repeated = f.filter(2.0, timestamp: 10.0)
        let backwards = f.filter(3.0, timestamp: 5.0)
        #expect(repeated.isFinite)
        #expect(backwards.isFinite)
    }

    @Test("非有限输入不污染内部状态")
    func rejectsNonFiniteInput() {
        var f = OneEuroFilter()
        _ = f.filter(1.0, timestamp: 0)
        _ = f.filter(.nan, timestamp: 1.0 / 60)
        _ = f.filter(.infinity, timestamp: 2.0 / 60)
        let out = f.filter(1.0, timestamp: 3.0 / 60)
        #expect(out.isFinite, "NaN/Inf 输入之后输出被污染了：\(out)")
    }

    @Test("三分量版本各轴独立")
    func threeComponentFiltersIndependently() {
        var f = OneEuroFilter3()
        var out = SIMD3<Float>()
        for i in 0..<200 {
            out = f.filter(SIMD3(1, 2, 3), timestamp: TimeInterval(i) / 60.0)
        }
        #expect(abs(out.x - 1) < 1e-3)
        #expect(abs(out.y - 2) < 1e-3)
        #expect(abs(out.z - 3) < 1e-3)
    }
}

private func variance(_ xs: [Float]) -> Float {
    guard xs.count > 1 else { return 0 }
    let mean = xs.reduce(0, +) / Float(xs.count)
    return xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(xs.count - 1)
}
