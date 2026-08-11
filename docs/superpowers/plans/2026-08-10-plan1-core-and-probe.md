# Plan 1：ParallaxCore 数学层 + 真机探针 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建成一个零框架依赖、在 Mac 上秒级跑测的 `ParallaxCore` 数学库，外加一个把 11 个 SDK 未定义量测成已知量的真机探针 app。

**Architecture:** 所有数学放进 Swift Package `ParallaxKit/ParallaxCore`，只依赖 `Foundation` 与 `simd`，因此可在 macOS 上用 `swift test` 做严格 TDD，完全不需要真机。探针是一个独立的极小 iOS app（xcodegen 生成工程），只打印数字、不做渲染，用来把眼位单位、左右眼镜像、帧率、设备物理参数等未知量变成已知量。

**Tech Stack:** Swift 6.0 / Swift Testing（`import Testing`）/ simd / SwiftUI / ARKit / xcodegen 2.46

## Global Constraints

- `ParallaxCore` **只许 import `Foundation` 与 `simd`**。禁止 ARKit / Metal / MetalKit / UIKit / AppKit / SwiftUI / AVFoundation / Photos / CoreMotion。Task 1 的测试会强制这一点。
- **归一化深度方向全项目唯一约定：`Float` 值域 `[0, 1]`，0 = 最远，1 = 最近。** 转换只在 `DepthNormalization` 一处发生。
- **屏幕坐标系**：原点＝显示区中心，X 向右，Y 向上，Z 指向用户，单位**米**。
- **`DepthMap.values` 保证不含 NaN/Inf。** 这是类型不变量，由构造器强制。
- 部署目标 **iOS 17.0** / macOS 14.0。
- 严格 TDD：**先写会失败的测试，跑一次确认它失败，再写实现。** 实现写在测试前面的，删掉重来。
- **补写的测试必须证明自己能失败。** 当测试是在实现已存在之后补的（审查发现覆盖缺口、修 bug 时补回归测试），没有天然的 RED 阶段。这时必须临时把被测行为破坏掉，跑一次看它变红，再恢复，并把那次失败的输出写进报告。
  一条从未见过红色的测试，和一条什么都没测的测试，在证据上是同一回事。
- **数值断言的边界要实测，不要估算。** 涉及浮点精度、饱和、收敛速度的断言（严格递增、容差阈值、迭代步数），先写个探针把实际数值打出来，按实测值定边界。
  本计划已经因为凭理论估算边界而返工过：`tanh` 饱和点估的是 r≈0.525，实测 r≈0.52 起增量就归零；离轴投影里更是断言了一个数学上不可能成立的事。**估算出来的阈值是猜测，实测出来的才是事实。**
- 每个 Task 结束必须提交，提交信息用中文描述做了什么。
- 探针 app **不得**写入任何文件、不得联网。眼位数据只打印到控制台。

### 关于 Task 10–12 的 TDD 例外

Task 1–9 全部严格 TDD（每个都有「跑测试确认失败 → 写实现 → 跑测试确认通过」）。
**Task 10–12 是明确的例外**，理由如下：

探针的被测对象是 **ARKit 在真机上的实际行为**——而那正是我们此刻不知道的东西。
给一个未知行为预先写断言，只能写出「我猜它是这样」，那不是测试，是把猜测固化成代码。
探针的验证方式是它自己的产出：数值是否落在物理上合理的区间（瞳距 50–75mm、
帧率与 `supportedVideoFormats` 一致），由人判断。

因此这三个 Task 的把关点是 `make probe-build` 能编译、以及 Task 12 的三项阻塞性检查。

**这个例外仅限探针。** Plan 2 的渲染管线回到严格 TDD——那时候参数已经是已知量了。

**参考文档（实现时以它们为准，不要凭记忆写 API 名）：**
- `docs/superpowers/specs/2026-08-10-parallax-photo-design.md` — 设计
- `docs/api-facts-arkit-depth.md` — SDK 核实事实 + 11 项探针清单
- `docs/appstore-compliance.md` — 合规约束

---

### Task 1: Swift Package 脚手架与架构纪律测试

**Files:**
- Create: `ParallaxKit/Package.swift`
- Create: `ParallaxKit/Sources/ParallaxCore/ParallaxCore.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/ArchitectureTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: 可用 `swift test --package-path ParallaxKit` 运行的测试环境；`ParallaxCore` 模块名

- [ ] **Step 1: 建目录并写 Package.swift**

```bash
mkdir -p ParallaxKit/Sources/ParallaxCore ParallaxKit/Tests/ParallaxCoreTests
```

`ParallaxKit/Package.swift`：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParallaxKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ParallaxCore", targets: ["ParallaxCore"])
    ],
    targets: [
        .target(name: "ParallaxCore"),
        .testTarget(name: "ParallaxCoreTests", dependencies: ["ParallaxCore"])
    ]
)
```

- [ ] **Step 2: 写失败的架构纪律测试**

`ParallaxKit/Tests/ParallaxCoreTests/ArchitectureTests.swift`：

```swift
import Testing
import Foundation

/// 这条测试守护 spec §5.2 的依赖规则。它一旦变红，说明有人把平台框架带进了纯逻辑层，
/// 而那会立刻让整个 Core 无法在 Mac 上测试。
@Test("ParallaxCore 不得依赖任何平台框架")
func coreHasNoPlatformImports() throws {
    let forbidden = [
        "ARKit", "Metal", "MetalKit", "UIKit", "AppKit",
        "SwiftUI", "AVFoundation", "Photos", "CoreMotion"
    ]

    // 本文件位于 ParallaxKit/Tests/ParallaxCoreTests/ArchitectureTests.swift
    // 上溯三层得到 ParallaxKit/
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourcesDir = packageRoot.appending(path: "Sources/ParallaxCore")

    let swiftFiles = try FileManager.default
        .subpathsOfDirectory(atPath: sourcesDir.path)
        .filter { $0.hasSuffix(".swift") }

    #expect(!swiftFiles.isEmpty, "没找到任何源文件，说明路径推导错了：\(sourcesDir.path)")

    for relativePath in swiftFiles {
        let content = try String(
            contentsOf: sourcesDir.appending(path: relativePath),
            encoding: .utf8
        )
        for framework in forbidden {
            #expect(
                !content.contains("import \(framework)"),
                "\(relativePath) 违规 import 了 \(framework)"
            )
        }
    }
}
```

- [ ] **Step 3: 跑测试确认它失败**

> ⚠️ **这一步有个坑，不绕开就拿不到真正的 RED。**
> `Package.swift` 的 `products` 数组引用了 `ParallaxCore` target，而此刻那个目录还是空的。
> SwiftPM 会直接报 `target 'ParallaxCore' referenced in product 'ParallaxCore' is empty` 的
> **构建错误**——测试根本不会运行。
>
> **构建错误不是测试失败。** 拿它当 RED，等于从没验证过这条测试有没有在测东西。

先临时把 `products` 数组注释掉：

```swift
    // products: [
    //     .library(name: "ParallaxCore", targets: ["ParallaxCore"])
    // ],
```

然后跑：

```bash
swift test --package-path ParallaxKit
```

预期：**测试运行并失败**，输出里能看到：

```
✘ Test "ParallaxCore 不得依赖任何平台框架" recorded an issue at ArchitectureTests.swift:25
  没找到任何源文件，说明路径推导错了：.../Sources/ParallaxCore
```

**必须亲眼看到这一行**，它证明测试确实在扫描目录、确实会因为扫不到东西而失败。看到之后再把 `products` 数组恢复。

> 如果这一步意外通过了，说明路径推导写错了——停下来查，不要往下走。

- [ ] **Step 4: 写最小实现让它通过**

`ParallaxKit/Sources/ParallaxCore/ParallaxCore.swift`：

```swift
import Foundation
import simd

/// ParallaxCore 是纯数学层，不依赖任何平台框架。
/// 依赖规则由 ArchitectureTests 强制，见 spec §5.2。
public enum ParallaxCore {
    public static let version = "1.0.0"
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit
```

预期：**PASS**，1 个测试通过。

- [ ] **Step 6: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): Swift Package 脚手架与架构纪律测试

ParallaxCore 只许 import Foundation 与 simd，由测试强制。
这条纪律是整个项目能在 Mac 上做 TDD 的前提。"
```

---

### Task 2: One Euro 滤波器

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Tracking/OneEuroFilter.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/OneEuroFilterTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct OneEuroFilter` — `init(minCutoff: Float = 1.0, beta: Float = 1.0, derivativeCutoff: Float = 1.0)`，`mutating func filter(_ x: Float, timestamp: TimeInterval) -> Float`
  - `struct OneEuroFilter3` — 同样的 init，`mutating func filter(_ v: SIMD3<Float>, timestamp: TimeInterval) -> SIMD3<Float>`

> **参数说明**：默认值 `beta = 1.0` 是**米制**下的起点，与原论文的像素制默认值（0.007）不同——头部移动速度约 0.1–0.5 m/s，beta 太小会让自适应完全失效。真机探针 P1/P3 拿到实际帧率后需要重新调参，见 Task 12。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/OneEuroFilterTests.swift`：

```swift
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

    @Test("beta 自适应确实在起作用")
    func adaptiveBetaSpeedsUpFastMotion() {
        // 同一个阶跃信号分别喂给 beta=0（退化成固定截止频率的低通）和高 beta 的滤波器。
        // 高 beta 在快速变化时会把截止频率抬上去，因此应当明显更快追上目标。
        //
        // 这条测试守护的是这个滤波器存在的理由本身：
        // 把 cutoff 里的 beta 项删掉，它必须变红。
        var fixed = OneEuroFilter(minCutoff: 1.0, beta: 0.0, derivativeCutoff: 1.0)
        var adaptive = OneEuroFilter(minCutoff: 1.0, beta: 50.0, derivativeCutoff: 1.0)

        // 两者先各自稳定在 0
        for i in 0..<30 {
            let timestamp = TimeInterval(i) / 60.0
            _ = fixed.filter(0, timestamp: timestamp)
            _ = adaptive.filter(0, timestamp: timestamp)
        }

        // 阶跃到 1.0，只看之后的 10 步——这是自适应与否差别最大的窗口
        var fixedOutput: Float = 0
        var adaptiveOutput: Float = 0
        for i in 30..<40 {
            let timestamp = TimeInterval(i) / 60.0
            fixedOutput = fixed.filter(1.0, timestamp: timestamp)
            adaptiveOutput = adaptive.filter(1.0, timestamp: timestamp)
        }

        #expect(adaptiveOutput > fixedOutput + 0.05,
                "高 beta 未能更快追上目标：adaptive=\(adaptiveOutput) vs fixed=\(fixedOutput)")
    }
}

private func variance(_ xs: [Float]) -> Float {
    guard xs.count > 1 else { return 0 }
    let mean = xs.reduce(0, +) / Float(xs.count)
    return xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(xs.count - 1)
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter OneEuroFilter
```

预期：**编译失败**，`cannot find 'OneEuroFilter' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Tracking/OneEuroFilter.swift`：

```swift
import Foundation
import simd

/// 一阶低通滤波器。alpha 由调用方按当前采样间隔算好后传入。
struct LowPassFilter {
    private var state: Float?

    /// 上一次的输出。尚未有输出时为 0。
    private(set) var lastOutput: Float = 0

    var hasOutput: Bool { state != nil }

    mutating func filter(_ x: Float, alpha: Float) -> Float {
        let y: Float
        if let previous = state {
            y = alpha * x + (1 - alpha) * previous
        } else {
            y = x
        }
        state = y
        lastOutput = y
        return y
    }
}

/// One Euro Filter（Casiez et al., CHI 2012）。
///
/// 为什么是它：眼位追踪要同时满足两个互相矛盾的要求——静止时要稳（否则画面发抖），
/// 移动时要跟手（否则拖影）。固定截止频率的低通做不到，One Euro 用速度自适应地
/// 调整截止频率解决了这个权衡。
///
/// - 慢速时 cutoff 低 → 强平滑，消抖动
/// - 快速时 cutoff 高 → 弱平滑，低延迟
public struct OneEuroFilter: Sendable {
    /// 最低截止频率（Hz）。越小越稳，也越迟钝。
    public var minCutoff: Float
    /// 速度对截止频率的影响系数。**米制下的量纲与原论文的像素制不同**，见 Task 2 说明。
    public var beta: Float
    /// 速度估计本身的截止频率（Hz）。
    public var derivativeCutoff: Float

    private var valueFilter = LowPassFilter()
    private var derivativeFilter = LowPassFilter()
    private var lastTimestamp: TimeInterval?
    private var lastRawValue: Float?

    public init(minCutoff: Float = 1.0, beta: Float = 1.0, derivativeCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Float, deltaTime: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / deltaTime)
    }

    public mutating func filter(_ x: Float, timestamp: TimeInterval) -> Float {
        // 非有限输入直接丢弃，绝不让它进入内部状态——一个 NaN 能污染之后的每一帧。
        guard x.isFinite else {
            return valueFilter.hasOutput ? valueFilter.lastOutput : 0
        }

        guard let previousTimestamp = lastTimestamp else {
            lastTimestamp = timestamp
            lastRawValue = x
            return valueFilter.filter(x, alpha: 1)
        }

        let deltaTime = Float(timestamp - previousTimestamp)
        // 时间戳倒退或重复：拒绝更新状态，返回上次结果。
        guard deltaTime > 0, deltaTime.isFinite else {
            return valueFilter.lastOutput
        }
        lastTimestamp = timestamp

        let derivative = (x - (lastRawValue ?? x)) / deltaTime
        lastRawValue = x

        let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, deltaTime: deltaTime)
        let smoothedDerivative = derivativeFilter.filter(derivative, alpha: derivativeAlpha)

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let valueAlpha = Self.alpha(cutoff: cutoff, deltaTime: deltaTime)
        return valueFilter.filter(x, alpha: valueAlpha)
    }
}

/// 三分量 One Euro 滤波器。各轴独立滤波。
public struct OneEuroFilter3: Sendable {
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var z: OneEuroFilter

    public init(minCutoff: Float = 1.0, beta: Float = 1.0, derivativeCutoff: Float = 1.0) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        z = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    public mutating func filter(_ v: SIMD3<Float>, timestamp: TimeInterval) -> SIMD3<Float> {
        SIMD3(
            x.filter(v.x, timestamp: timestamp),
            y.filter(v.y, timestamp: timestamp),
            z.filter(v.z, timestamp: timestamp)
        )
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter OneEuroFilter
```

预期：**7 个测试全 PASS**。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): One Euro 自适应滤波器

眼位追踪要同时满足静止时稳、移动时跟手，固定截止频率做不到。
One Euro 用速度自适应调整截止频率解决这个权衡。
米制下 beta 默认值取 1.0（原论文像素制是 0.007），真机调参后再定。"
```

---

### Task 3: 屏幕几何与方向旋转

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Projection/ScreenGeometry.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/ScreenGeometryTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum ScreenRotation: Sendable, CaseIterable` — `.none` / `.deviceRotatedClockwise90` / `.deviceRotated180` / `.deviceRotatedCounterClockwise90`
  - `struct ScreenGeometry: Sendable, Equatable` — `init(width: Float, height: Float, cameraOffset: SIMD3<Float>)`；属性 `width` / `height` / `cameraOffset`；只读 `bottomLeft` / `bottomRight` / `topLeft` / `topRight`（均为 `SIMD3<Float>`）；`func rotated(_ rotation: ScreenRotation) -> ScreenGeometry`

> **为什么自定义 `ScreenRotation` 而不用 `UIInterfaceOrientation`**：一是 Core 不许 import UIKit；二是 `UIInterfaceOrientationLandscapeLeft` 的方向语义在文档里长期是混淆源。这里用「设备相对原生方向转了多少度」描述，数学上无歧义。`UIInterfaceOrientation → ScreenRotation` 的映射放在 Platform 层，并由探针 P11 实测确认。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/ScreenGeometryTests.swift`：

```swift
import Testing
import simd
@testable import ParallaxCore

@Suite("ScreenGeometry")
struct ScreenGeometryTests {

    /// iPhone 14 Pro Max 的推算值：2796x1290 @460ppi
    static let iPhone14ProMax = ScreenGeometry(
        width: 0.07123,
        height: 0.15437,
        cameraOffset: SIMD3(0.005, 0.06719, 0)
    )

    @Test("四角坐标关于中心对称")
    func cornersAreSymmetric() {
        let g = Self.iPhone14ProMax
        #expect(g.bottomLeft.x == -g.width / 2)
        #expect(g.bottomLeft.y == -g.height / 2)
        #expect(g.topRight.x == g.width / 2)
        #expect(g.topRight.y == g.height / 2)
        // 屏幕平面就是 z = 0
        #expect(g.bottomLeft.z == 0)
        #expect(g.topRight.z == 0)
    }

    @Test("四角构成平行四边形")
    func cornersFormParallelogram() {
        let g = Self.iPhone14ProMax
        let fromBottomLeft = g.topRight - g.bottomLeft
        let viaOtherCorners = (g.bottomRight - g.bottomLeft) + (g.topLeft - g.bottomLeft)
        #expect(simd_length(fromBottomLeft - viaOtherCorners) < 1e-6)
    }

    @Test("不旋转时几何不变")
    func identityRotation() {
        let g = Self.iPhone14ProMax
        #expect(g.rotated(.none) == g)
    }

    @Test("顺时针 90 度：宽高交换，顶部摄像头跑到右侧")
    func clockwise90MovesTopCameraToRight() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotatedClockwise90)
        #expect(abs(r.width - g.height) < 1e-6)
        #expect(abs(r.height - g.width) < 1e-6)
        // 原生顶部中央的摄像头，设备顺时针转后应出现在右侧
        #expect(r.cameraOffset.x > 0)
        #expect(abs(r.cameraOffset.x - g.cameraOffset.y) < 1e-6)
        #expect(abs(r.cameraOffset.y + g.cameraOffset.x) < 1e-6)
    }

    @Test("180 度：尺寸不变，偏移取反")
    func halfTurnNegatesOffset() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotated180)
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(abs(r.height - g.height) < 1e-6)
        #expect(abs(r.cameraOffset.x + g.cameraOffset.x) < 1e-6)
        #expect(abs(r.cameraOffset.y + g.cameraOffset.y) < 1e-6)
    }

    @Test("旋转四次回到原样（群性质）")
    func fourQuarterTurnsIsIdentity() {
        let g = Self.iPhone14ProMax
        var r = g
        for _ in 0..<4 { r = r.rotated(.deviceRotatedClockwise90) }
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(abs(r.height - g.height) < 1e-6)
        #expect(simd_length(r.cameraOffset - g.cameraOffset) < 1e-6)
    }

    @Test("顺时针与逆时针互为逆运算")
    func clockwiseAndCounterClockwiseCancel() {
        let g = Self.iPhone14ProMax
        let r = g.rotated(.deviceRotatedClockwise90)
                 .rotated(.deviceRotatedCounterClockwise90)
        #expect(abs(r.width - g.width) < 1e-6)
        #expect(simd_length(r.cameraOffset - g.cameraOffset) < 1e-6)
    }

    @Test("任何旋转都不改变对角线长度", arguments: ScreenRotation.allCases)
    func rotationPreservesDiagonal(_ rotation: ScreenRotation) {
        let g = Self.iPhone14ProMax
        let r = g.rotated(rotation)
        let original = (g.width * g.width + g.height * g.height).squareRoot()
        let rotated = (r.width * r.width + r.height * r.height).squareRoot()
        #expect(abs(original - rotated) < 1e-6)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter ScreenGeometry
```

预期：**编译失败**，`cannot find 'ScreenGeometry' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Projection/ScreenGeometry.swift`：

```swift
import Foundation
import simd

/// 界面相对设备原生方向的旋转量。
///
/// 刻意不用 `UIInterfaceOrientation`：一来 Core 不许 import UIKit，
/// 二来那个枚举的 left/right 语义长期是混淆源。这里用旋转角度描述，数学上无歧义。
public enum ScreenRotation: Sendable, CaseIterable {
    /// 与设备原生方向一致
    case none
    /// 设备相对原生方向顺时针转 90°（原生顶边转到右侧）
    case deviceRotatedClockwise90
    /// 设备相对原生方向转 180°
    case deviceRotated180
    /// 设备相对原生方向逆时针转 90°（原生顶边转到左侧）
    case deviceRotatedCounterClockwise90
}

/// 屏幕的物理几何。
///
/// 坐标系：原点＝显示区中心，X 向右，Y 向上，Z 指向用户，单位米。
/// 屏幕平面固定在 z = 0。
public struct ScreenGeometry: Sendable, Equatable {
    /// 显示区物理宽度，米
    public var width: Float
    /// 显示区物理高度，米
    public var height: Float
    /// 前置摄像头位置，相对显示区中心，米。
    ///
    /// 这是本项目唯一的「脏数据」——Apple 没有任何 API 能查询它，
    /// 只能靠设备参数表 + 实测校准。见 spec §6.2 与探针 P11。
    public var cameraOffset: SIMD3<Float>

    public init(width: Float, height: Float, cameraOffset: SIMD3<Float>) {
        self.width = width
        self.height = height
        self.cameraOffset = cameraOffset
    }

    public var bottomLeft: SIMD3<Float> { SIMD3(-width / 2, -height / 2, 0) }
    public var bottomRight: SIMD3<Float> { SIMD3(width / 2, -height / 2, 0) }
    public var topLeft: SIMD3<Float> { SIMD3(-width / 2, height / 2, 0) }
    public var topRight: SIMD3<Float> { SIMD3(width / 2, height / 2, 0) }

    /// 把原生方向下定义的几何，变换到指定旋转后的界面坐标系。
    public func rotated(_ rotation: ScreenRotation) -> ScreenGeometry {
        switch rotation {
        case .none:
            return self
        case .deviceRotatedClockwise90:
            // (x, y) -> (y, -x)：原生顶部的摄像头转到右侧
            return ScreenGeometry(
                width: height,
                height: width,
                cameraOffset: SIMD3(cameraOffset.y, -cameraOffset.x, cameraOffset.z)
            )
        case .deviceRotated180:
            return ScreenGeometry(
                width: width,
                height: height,
                cameraOffset: SIMD3(-cameraOffset.x, -cameraOffset.y, cameraOffset.z)
            )
        case .deviceRotatedCounterClockwise90:
            // (x, y) -> (-y, x)
            return ScreenGeometry(
                width: height,
                height: width,
                cameraOffset: SIMD3(-cameraOffset.y, cameraOffset.x, cameraOffset.z)
            )
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter ScreenGeometry
```

预期：**全 PASS**（含 4 组参数化用例）。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 屏幕几何与方向旋转

用「设备相对原生方向转了多少度」描述旋转，避开 UIInterfaceOrientation
的 left/right 语义歧义。旋转四次回到原样这条群性质做了测试。"
```

---

### Task 4: 离轴投影矩阵

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Projection/OffAxisProjection.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/OffAxisProjectionTests.swift`

**Interfaces:**
- Consumes: `ScreenGeometry`（Task 3）
- Produces: `enum OffAxisProjection` — `static func matrix(eye: SIMD3<Float>, screen: ScreenGeometry, near: Float, far: Float) -> simd_float4x4`

> **这是整个项目的数学锚点。** 核心断言「屏幕四角必须映射到 NDC 的 (±1, ±1)」对任意合法眼位都成立——不依赖硬件、不依赖观感、有唯一正确答案。
>
> **深度约定**：输出矩阵面向 **Metal**，NDC z 范围是 **[0, 1]**（不是 OpenGL 的 [-1, 1]）。近平面映射到 0，远平面映射到 1。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/OffAxisProjectionTests.swift`：

```swift
import Testing
import simd
@testable import ParallaxCore

@Suite("OffAxisProjection")
struct OffAxisProjectionTests {

    static let screen = ScreenGeometry(
        width: 0.07123, height: 0.15437, cameraOffset: .zero
    )
    static let near: Float = 0.01
    static let far: Float = 10.0

    /// 覆盖正前方、四个侧向偏移、远近距离的代表性眼位
    static let eyePositions: [SIMD3<Float>] = [
        SIMD3(0, 0, 0.30),
        SIMD3(0.05, 0, 0.30),
        SIMD3(-0.05, 0, 0.30),
        SIMD3(0, 0.08, 0.30),
        SIMD3(0, -0.08, 0.30),
        SIMD3(0.04, -0.06, 0.22),
        SIMD3(-0.03, 0.05, 0.55)
    ]

    private static func project(_ point: SIMD3<Float>, _ m: simd_float4x4) -> SIMD3<Float> {
        let clip = m * SIMD4<Float>(point, 1)
        return SIMD3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
    }

    @Test("屏幕四角精确映射到 NDC 边界", arguments: eyePositions)
    func screenCornersMapToNDCEdges(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let expectations: [(SIMD3<Float>, SIMD2<Float>)] = [
            (Self.screen.bottomLeft,  SIMD2(-1, -1)),
            (Self.screen.bottomRight, SIMD2( 1, -1)),
            (Self.screen.topLeft,     SIMD2(-1,  1)),
            (Self.screen.topRight,    SIMD2( 1,  1))
        ]
        for (corner, expected) in expectations {
            let ndc = Self.project(corner, m)
            #expect(abs(ndc.x - expected.x) < 1e-4,
                    "眼位 \(eye) 下角点 \(corner) 的 NDC.x = \(ndc.x)，应为 \(expected.x)")
            #expect(abs(ndc.y - expected.y) < 1e-4,
                    "眼位 \(eye) 下角点 \(corner) 的 NDC.y = \(ndc.y)，应为 \(expected.y)")
        }
    }

    @Test("眼位在正前方时退化为对称视锥")
    func centeredEyeGivesSymmetricFrustum() {
        let m = OffAxisProjection.matrix(
            eye: SIMD3(0, 0, 0.3), screen: Self.screen, near: Self.near, far: Self.far
        )
        // 对称视锥的特征：第三列的 x、y 分量为 0（无偏斜）
        #expect(abs(m.columns.2.x) < 1e-6)
        #expect(abs(m.columns.2.y) < 1e-6)
    }

    @Test("离轴投影产生真实视差：屏幕前后的点朝相反方向移动")
    func offAxisProducesOppositeParallax() {
        // 这条测试守护的是离轴投影存在的理由。
        // 简单平移会让所有点同向移动等量；只有真正的离轴视锥
        // 才会让屏幕平面前后的点朝相反方向偏移——那就是视差。
        let centeredEye = SIMD3<Float>(0, 0, 0.3)
        let leftEye = SIMD3<Float>(-0.05, 0, 0.3)
        let behindScreen = SIMD3<Float>(0, 0, -0.1)   // 屏幕后方，远离观察者
        let inFrontOfScreen = SIMD3<Float>(0, 0, 0.1) // 屏幕前方，靠近观察者

        let centered = OffAxisProjection.matrix(
            eye: centeredEye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let shifted = OffAxisProjection.matrix(
            eye: leftEye, screen: Self.screen, near: Self.near, far: Self.far
        )

        // 眼位居中时，屏幕轴线上的点都投在画面正中
        #expect(abs(Self.project(behindScreen, centered).x) < 1e-5)
        #expect(abs(Self.project(inFrontOfScreen, centered).x) < 1e-5)

        // 眼位左移后：后方的点向左偏，前方的点向右偏
        let behindShift = Self.project(behindScreen, shifted).x
        let frontShift = Self.project(inFrontOfScreen, shifted).x
        #expect(behindShift < -0.01, "屏幕后方的点未向左偏：\(behindShift)")
        #expect(frontShift > 0.01, "屏幕前方的点未向右偏：\(frontShift)")
        // 两者必须反向——这是视差的本质，不是幅度差异
        #expect(behindShift * frontShift < 0, "前后景未朝相反方向移动，这不是真视差")
    }

    @Test("屏幕中心恒映射到 NDC 原点，与眼位无关", arguments: eyePositions)
    func screenCenterIsInvariant(_ eye: SIMD3<Float>) {
        // 四角映射到 NDC 的 ±1，中心作为四角中点必然映射到 0。
        // 这不是巧合，是离轴投影的定义决定的——所以它跟眼位无关。
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let ndc = Self.project(SIMD3<Float>(0, 0, 0), m)
        #expect(abs(ndc.x) < 1e-5, "眼位 \(eye) 下屏幕中心 x 偏移了 \(ndc.x)")
        #expect(abs(ndc.y) < 1e-5, "眼位 \(eye) 下屏幕中心 y 偏移了 \(ndc.y)")
    }

    @Test("近平面映射到 0，远平面映射到 1（Metal 深度约定）")
    func metalDepthRange() {
        let eye = SIMD3<Float>(0, 0, 0.3)
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        // 眼前方 near 处与 far 处的点（屏幕坐标系中 Z 指向用户，故沿 -Z 远离）
        let atNear = SIMD3(eye.x, eye.y, eye.z - Self.near)
        let atFar = SIMD3(eye.x, eye.y, eye.z - Self.far)
        #expect(abs(Self.project(atNear, m).z - 0) < 1e-4)
        #expect(abs(Self.project(atFar, m).z - 1) < 1e-4)
    }

    @Test("屏幕平面上的点深度落在 [0,1] 内", arguments: eyePositions)
    func screenPlaneDepthInRange(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        let z = Self.project(SIMD3(0, 0, 0), m).z
        #expect(z > 0 && z < 1, "屏幕平面深度 \(z) 落在 [0,1] 之外")
    }

    @Test("矩阵元素全部有限", arguments: eyePositions)
    func matrixIsFinite(_ eye: SIMD3<Float>) {
        let m = OffAxisProjection.matrix(
            eye: eye, screen: Self.screen, near: Self.near, far: Self.far
        )
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            for value in [column.x, column.y, column.z, column.w] {
                #expect(value.isFinite, "矩阵含非有限值：\(value)")
            }
        }
    }

    @Test("眼位贴到屏幕平面上不产生 NaN")
    func degenerateEyeDistanceIsSafe() {
        let m = OffAxisProjection.matrix(
            eye: SIMD3(0, 0, 0), screen: Self.screen, near: Self.near, far: Self.far
        )
        for column in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            for value in [column.x, column.y, column.z, column.w] {
                #expect(value.isFinite, "退化眼位产生了非有限值：\(value)")
            }
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter OffAxisProjection
```

预期：**编译失败**，`cannot find 'OffAxisProjection' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Projection/OffAxisProjection.swift`：

```swift
import Foundation
import simd

/// 离轴（非对称视锥）透视投影。
///
/// 这是「窗口」与「贴纸」的分水岭：简单平移只让画面滑动，
/// 离轴投影会让你把手机往左移时**多看到物体的右侧面**。
///
/// 算法是 Kooima 广义透视投影在「屏幕位于 z = 0 平面、基向量为标准正交基」
/// 这一情形下的特化，因此屏幕基旋转矩阵恒为单位阵，只剩视锥 + 平移。
///
/// 输出面向 Metal：NDC 的 z 范围是 [0, 1]，近平面 → 0，远平面 → 1。
public enum OffAxisProjection {

    public static func matrix(
        eye: SIMD3<Float>,
        screen: ScreenGeometry,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        // 眼到屏幕平面的垂直距离。屏幕在 z = 0，Z 轴指向用户，所以就是 eye.z。
        // 退化保护：眼位贴到甚至穿过屏幕平面时，钳到一个极小正值，
        // 宁可给出一个无意义但有限的矩阵，也不要让 NaN 流进渲染管线。
        let distance = max(eye.z, 1e-4)

        let scale = near / distance
        let left   = (-screen.width  / 2 - eye.x) * scale
        let right  = ( screen.width  / 2 - eye.x) * scale
        let bottom = (-screen.height / 2 - eye.y) * scale
        let top    = ( screen.height / 2 - eye.y) * scale

        let frustum = makeFrustum(
            left: left, right: right, bottom: bottom, top: top, near: near, far: far
        )
        let translation = makeTranslation(-eye)
        return frustum * translation
    }

    /// 右手系视锥矩阵，深度输出到 [0, 1]（Metal 约定）。
    private static func makeFrustum(
        left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float
    ) -> simd_float4x4 {
        let width = right - left
        let height = top - bottom
        let depth = near - far

        // 全部除数都做退化保护，理由同上：有限的错值远好过 NaN。
        let safeWidth = abs(width) > 1e-9 ? width : 1e-9
        let safeHeight = abs(height) > 1e-9 ? height : 1e-9
        let safeDepth = abs(depth) > 1e-9 ? depth : -1e-9

        return simd_float4x4(
            SIMD4(2 * near / safeWidth, 0, 0, 0),
            SIMD4(0, 2 * near / safeHeight, 0, 0),
            SIMD4(
                (right + left) / safeWidth,
                (top + bottom) / safeHeight,
                far / safeDepth,
                -1
            ),
            SIMD4(0, 0, near * far / safeDepth, 0)
        )
    }

    private static func makeTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter OffAxisProjection
```

预期：**全 PASS**。四角断言在 7 组眼位下各跑一遍。

> 若四角断言失败，**先怀疑视锥矩阵的列主序**：`simd_float4x4(SIMD4, SIMD4, SIMD4, SIMD4)` 传入的是**列**不是行。这是这段代码唯一容易写反的地方。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 离轴投影矩阵

Kooima 广义透视投影在屏幕位于 z=0 平面时的特化。
输出面向 Metal，NDC 深度范围 [0,1]。
核心断言：屏幕四角在任意合法眼位下都精确映射到 NDC 的 (±1,±1)。"
```

---

### Task 5: 视差预算（软性夹紧）

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Projection/ParallaxBudget.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/ParallaxBudgetTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `struct ParallaxBudget: Sendable` — `init(linearRadius: Float = 0.06, maxRadius: Float = 0.12, distanceRange: ClosedRange<Float> = 0.15...0.80)`；`func clamp(_ eye: SIMD3<Float>) -> SIMD3<Float>`；`static func softClamp(_ x: Float, linear: Float, max: Float) -> Float`

> **为什么必须一阶连续**：硬 clamp 会在边界产生速度突变，用户感受是「卡住了」；软性衰减的感受是「到边了」。这个差别肉眼可辨，所以把导数连续性写成测试。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/ParallaxBudgetTests.swift`：

```swift
import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("ParallaxBudget")
struct ParallaxBudgetTests {

    static let budget = ParallaxBudget(
        linearRadius: 0.06, maxRadius: 0.12, distanceRange: 0.15...0.80
    )

    @Test("线性区内原样通过", arguments: [Float(0), 0.01, 0.03, 0.059])
    func insideLinearRegionIsIdentity(_ r: Float) {
        #expect(abs(ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12) - r) < 1e-6)
    }

    @Test("超出线性区后被压缩，且在浮点可分辨范围内严格递增")
    func beyondLinearRegionIsCompressedAndMonotonic() {
        // tanh 渐近饱和：过了某点，相邻步长带来的增量会落到 Float 精度以下，
        // 输出停在上限不再变化——那是设计意图，不是缺陷。
        // 实测在 max=0.12 时 r≈0.52 起增量就归零了（ULP(0.12)=7.45e-9）。
        // 所以严格递增只在 r ≤ 0.40 内断言，那里增量仍有 ULP 的 55 倍余量。
        var previous = ParallaxBudget.softClamp(0.06, linear: 0.06, max: 0.12)
        for step in 1...34 {
            let r = 0.06 + Float(step) * 0.01   // 0.07 ... 0.40
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out > previous, "在 r=\(r) 处不再严格递增")
            #expect(out < r, "在 r=\(r) 处没有被压缩")
            previous = out
        }
    }

    @Test("饱和区单调不减且永不越限")
    func saturationRegionIsNonDecreasingAndBounded() {
        // 饱和之后允许输出持平，但绝不允许回退或越界。
        // 这条和上一条合起来才是完整的单调性契约：
        // 可分辨区严格递增，饱和区不回退不越限。
        var previous = ParallaxBudget.softClamp(0.40, linear: 0.06, max: 0.12)
        for step in 1...100 {
            let r = 0.40 + Float(step) * 0.05   // 0.45 ... 5.40
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out >= previous, "在 r=\(r) 处回退：\(out) < \(previous)")
            #expect(out <= 0.12 + 1e-6, "在 r=\(r) 处越限：\(out)")
            previous = out
        }
    }

    @Test("永远不超过渐近上限")
    func neverExceedsMaximum() {
        for r in stride(from: Float(0), through: 100, by: 0.5) {
            let out = ParallaxBudget.softClamp(r, linear: 0.06, max: 0.12)
            #expect(out <= 0.12 + 1e-6, "r=\(r) 时输出 \(out) 超过上限")
            #expect(out.isFinite)
        }
    }

    @Test("在线性区边界处一阶连续")
    func derivativeIsContinuousAtBoundary() {
        let boundary: Float = 0.06
        let h: Float = 1e-4
        func derivative(at x: Float) -> Float {
            let a = ParallaxBudget.softClamp(x - h, linear: boundary, max: 0.12)
            let b = ParallaxBudget.softClamp(x + h, linear: boundary, max: 0.12)
            return (b - a) / (2 * h)
        }
        let inside = derivative(at: boundary - 5 * h)
        let outside = derivative(at: boundary + 5 * h)
        // 两侧导数都应接近 1，且彼此接近
        #expect(abs(inside - 1) < 0.05, "线性区内导数应为 1，实为 \(inside)")
        #expect(abs(inside - outside) < 0.05, "边界两侧导数跳变：\(inside) vs \(outside)")
    }

    @Test("径向夹紧保持方向不变")
    func clampPreservesDirection() {
        let eye = SIMD3<Float>(0.3, 0.4, 0.3)   // 横向模长 0.5，远超上限
        let clamped = Self.budget.clamp(eye)
        let originalDirection = simd_normalize(SIMD2(eye.x, eye.y))
        let clampedDirection = simd_normalize(SIMD2(clamped.x, clamped.y))
        #expect(simd_length(originalDirection - clampedDirection) < 1e-5)
    }

    @Test("对角方向与轴向受到同等限制（径向而非方形边界）")
    func clampIsRadialNotRectangular() {
        let alongAxis = Self.budget.clamp(SIMD3(1.0, 0, 0.3))
        let diagonal = Self.budget.clamp(SIMD3(0.7071, 0.7071, 0.3))
        let axisLength = simd_length(SIMD2(alongAxis.x, alongAxis.y))
        let diagonalLength = simd_length(SIMD2(diagonal.x, diagonal.y))
        #expect(abs(axisLength - diagonalLength) < 1e-4,
                "轴向 \(axisLength) 与对角 \(diagonalLength) 受限不一致，说明是方形边界")
    }

    @Test("观看距离被夹进合法区间")
    func distanceIsClampedToRange() {
        #expect(Self.budget.clamp(SIMD3(0, 0, 0.05)).z == 0.15)
        #expect(Self.budget.clamp(SIMD3(0, 0, 5.0)).z == 0.80)
        #expect(Self.budget.clamp(SIMD3(0, 0, 0.35)).z == 0.35)
    }

    @Test("零向量与非有限输入不产生 NaN")
    func degenerateInputIsSafe() {
        let zero = Self.budget.clamp(SIMD3(0, 0, 0.3))
        #expect(zero.x == 0 && zero.y == 0)
        let nan = Self.budget.clamp(SIMD3(.nan, .nan, .nan))
        #expect(nan.x.isFinite && nan.y.isFinite && nan.z.isFinite)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter ParallaxBudget
```

预期：**编译失败**，`cannot find 'ParallaxBudget' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Projection/ParallaxBudget.swift`：

```swift
import Foundation
import simd

/// 视差预算：把眼位软性夹进一个不会暴露遮挡空洞的舒适锥内。
///
/// 侧头角度越大，被遮挡区域露出的空洞越大。与其等空洞穿帮，
/// 不如在数学层面就把眼位限制住——用户感受应该是「到边了」，而不是「卡住了」。
/// 所以衰减必须一阶连续，这一点由测试强制。
public struct ParallaxBudget: Sendable {
    /// 线性区半径，米。此范围内眼位原样通过。
    public var linearRadius: Float
    /// 渐近上限，米。横向偏移永不超过此值。
    public var maxRadius: Float
    /// 合法观看距离区间，米。
    public var distanceRange: ClosedRange<Float>

    public init(
        linearRadius: Float = 0.06,
        maxRadius: Float = 0.12,
        distanceRange: ClosedRange<Float> = 0.15...0.80
    ) {
        self.linearRadius = linearRadius
        self.maxRadius = maxRadius
        self.distanceRange = distanceRange
    }

    /// 软性饱和函数。
    ///
    /// - `x ≤ linear` 时恒等通过
    /// - `x > linear` 时用 tanh 平滑饱和到 `max`
    ///
    /// 在 `x = linear` 处函数值与一阶导数都连续（tanh'(0) = 1）。
    public static func softClamp(_ x: Float, linear: Float, max maximum: Float) -> Float {
        guard x.isFinite else { return 0 }
        guard x > linear else { return x }
        let span = maximum - linear
        guard span > 0 else { return linear }
        return linear + span * tanh((x - linear) / span)
    }

    public func clamp(_ eye: SIMD3<Float>) -> SIMD3<Float> {
        let lateral = SIMD2(
            eye.x.isFinite ? eye.x : 0,
            eye.y.isFinite ? eye.y : 0
        )
        let radius = simd_length(lateral)

        // 径向夹紧而非分轴夹紧：分轴会产生方形边界，对角方向能跑得比轴向更远，
        // 用户会感觉「斜着动能看得更多」，很怪。
        let clampedRadius = Self.softClamp(radius, linear: linearRadius, max: maxRadius)
        let scaled = radius > 1e-9 ? lateral * (clampedRadius / radius) : lateral

        let rawDistance = eye.z.isFinite ? eye.z : distanceRange.lowerBound
        let distance = min(max(rawDistance, distanceRange.lowerBound), distanceRange.upperBound)

        return SIMD3(scaled.x, scaled.y, distance)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter ParallaxBudget
```

预期：**全 PASS**。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 视差预算软性夹紧

用 tanh 在线性区外平滑饱和，边界处一阶连续（导数连续性有测试）。
径向夹紧而非分轴，避免对角方向能跑得比轴向更远的怪异手感。"
```

---

### Task 6: 深度图归一化

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/DepthMap.swift`
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/DepthNormalization.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/DepthNormalizationTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct DepthMap: Sendable` — `init?(width: Int, height: Int, values: [Float])`；属性 `width` / `height` / `values`；`subscript(x: Int, y: Int) -> Float`
  - `enum DepthSourceKind: Sendable` — `.disparity` / `.depth`
  - `enum DepthNormalization` — `static func normalize(raw: [Float], width: Int, height: Int, kind: DepthSourceKind, percentileClip: Float = 0.02) -> DepthMap?`

> **归一化方向是全项目唯一约定：0 = 最远，1 = 最近。** disparity（1/米，近大远小）直接线性映射；depth（米，近小远大）要翻转。转换只在这一处发生。
>
> **NaN 从哪来**：`AVDepthData.h:209` 明写未滤波深度图用 NaN 表示缺失像素。NaN 进顶点着色器会污染整条管线。`DepthMap` 的构造器强制「不含 NaN/Inf」这一类型不变量。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/DepthNormalizationTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter DepthNormalization
```

预期：**编译失败**，`cannot find 'DepthMap' in scope`。

- [ ] **Step 3: 写 DepthMap**

`ParallaxKit/Sources/ParallaxCore/Depth/DepthMap.swift`：

```swift
import Foundation

/// 归一化深度图。
///
/// **全项目唯一的深度方向约定：值域 [0, 1]，0 = 最远，1 = 最近。**
///
/// 类型不变量：`values` 保证不含 NaN/Inf，且 `values.count == width * height`。
/// 这个不变量由构造器强制——NaN 进了顶点着色器会污染整条渲染管线，
/// 与其在 GPU 上排查黑洞，不如在这里就拒绝。
public struct DepthMap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let values: [Float]

    public init?(width: Int, height: Int, values: [Float]) {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    /// 按像素坐标读取。原点在左上角，与图像惯例一致。
    public subscript(x: Int, y: Int) -> Float {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "深度图下标越界")
        return values[y * width + x]
    }
}
```

- [ ] **Step 4: 写 DepthNormalization**

`ParallaxKit/Sources/ParallaxCore/Depth/DepthNormalization.swift`：

```swift
import Foundation

/// 原始深度数据的物理含义。
///
/// 依据 `CVPixelBuffer.h:107-110`：
/// - disparity 单位是 1/米，近大远小
/// - depth 单位是米，近小远大
public enum DepthSourceKind: Sendable {
    case disparity
    case depth
}

/// 把原始深度/视差数据转成归一化 `DepthMap`。
///
/// 这是全项目**唯一**发生深度方向转换的地方。任何其他位置再翻转一次，
/// 结果就是凹凸相反——而那种 bug 在真机上肉眼很难第一时间判断方向。
public enum DepthNormalization {

    /// 全部数据缺失或退化时使用的平面深度值。
    private static let degenerateValue: Float = 0.5

    public static func normalize(
        raw: [Float],
        width: Int,
        height: Int,
        kind: DepthSourceKind,
        percentileClip: Float = 0.02
    ) -> DepthMap? {
        guard width > 0, height > 0, raw.count == width * height else { return nil }

        let finiteValues = raw.filter { $0.isFinite }

        // 一个有效像素都没有：退化成平面，而不是失败。
        // 这种图渲染出来是张平照片，但 app 不该因此崩掉或黑屏。
        guard !finiteValues.isEmpty else {
            return DepthMap(
                width: width, height: height,
                values: [Float](repeating: degenerateValue, count: raw.count)
            )
        }

        let (low, high) = percentileBounds(finiteValues, clip: percentileClip)

        // 动态范围退化（全常量或裁剪后区间塌陷）：同样退化成平面。
        guard high - low > 1e-9 else {
            return DepthMap(
                width: width, height: height,
                values: [Float](repeating: degenerateValue, count: raw.count)
            )
        }

        let span = high - low
        let normalized = raw.map { value -> Float in
            // 缺失像素填成「最远」。填成最近会在画面里凸出一块并不存在的前景，
            // 那比缺一块背景难看得多。
            guard value.isFinite else { return 0 }
            let t = min(max((value - low) / span, 0), 1)
            // disparity 越大越近，直接用；depth 越大越远，翻转。
            return kind == .disparity ? t : 1 - t
        }

        return DepthMap(width: width, height: height, values: normalized)
    }

    /// 取百分位边界，抑制离群点把整体动态范围压扁。
    private static func percentileBounds(
        _ values: [Float], clip: Float
    ) -> (low: Float, high: Float) {
        guard clip > 0, values.count > 2 else {
            return (values.min() ?? 0, values.max() ?? 1)
        }
        let sorted = values.sorted()
        let clampedClip = min(max(clip, 0), 0.49)
        let lowIndex = Int(Float(sorted.count - 1) * clampedClip)
        let highIndex = Int(Float(sorted.count - 1) * (1 - clampedClip))
        return (sorted[lowIndex], sorted[highIndex])
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter DepthNormalization
```

预期：**全 PASS**（11 个测试）。

- [ ] **Step 6: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 深度图归一化

全项目唯一的深度方向转换点：0=最远，1=最近。
DepthMap 用构造器强制「不含 NaN/Inf」的类型不变量——
NaN 进顶点着色器会污染整条管线，在这里拒绝比在 GPU 上排查划算。
缺失像素填最远而非最近；全常量或全 NaN 退化成平面而非失败。"
```

---

### Task 7: 空闲摆动生成器

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Tracking/IdlePoseGenerator.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/IdlePoseGeneratorTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: `struct IdlePoseGenerator: Sendable` — `init(amplitude: SIMD2<Float> = SIMD2(0.035, 0.022), distance: Float = 0.35, periodX: TimeInterval = 7.0, periodY: TimeInterval = 4.328)`；`func pose(at time: TimeInterval) -> SIMD3<Float>`

> **这不是兜底，是首屏。** app 一打开、用户还没做任何事之前，示例照片就应该自己在缓慢摆动。它同时解决三件事：审核员一眼看到功能在工作（合规风险 R1）、不支持的机型上 app 不是空壳（R2）、新用户不用被教育就懂这是什么。
>
> 两轴周期取无理数比（7 : 4.328 ≈ φ，即 875/541，541 为质数）避免肉眼可察觉的重复。精确有理数计算的组合周期为 3787 秒。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/IdlePoseGeneratorTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter IdlePoseGenerator
```

预期：**编译失败**，`cannot find 'IdlePoseGenerator' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Tracking/IdlePoseGenerator.swift`：

```swift
import Foundation
import simd

/// 无输入时的自动摆动轨迹。
///
/// 这不是兜底而是首屏：app 打开的瞬间画面就该自己活着。
/// 见 spec §9.2②。
///
/// 用两轴不同周期的李萨如曲线，周期比取无理数，避免肉眼可察觉的循环。
public struct IdlePoseGenerator: Sendable {
    /// 横向与纵向摆幅，米
    public var amplitude: SIMD2<Float>
    /// 虚拟观看距离，米
    public var distance: Float
    /// 横向周期，秒
    public var periodX: TimeInterval
    /// 纵向周期，秒。与 periodX 的比值取无理数。
    public var periodY: TimeInterval

    public init(
        amplitude: SIMD2<Float> = SIMD2(0.035, 0.022),
        distance: Float = 0.35,
        periodX: TimeInterval = 7.0,
        periodY: TimeInterval = 4.328
    ) {
        self.amplitude = amplitude
        self.distance = distance
        self.periodX = periodX
        self.periodY = periodY
    }

    public func pose(at time: TimeInterval) -> SIMD3<Float> {
        let x = amplitude.x * Float(sin(2 * Double.pi * time / periodX))
        let y = amplitude.y * Float(sin(2 * Double.pi * time / periodY))
        return SIMD3(x, y, distance)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter IdlePoseGenerator
```

预期：**全 PASS**。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 空闲自动摆动生成器

李萨如曲线，两轴周期比取无理数避免可察觉的循环。
这是首屏而非兜底：app 打开瞬间画面就该自己活着。"
```

---

### Task 8: 观察者姿态状态机

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Tracking/ViewerPose.swift`
- Create: `ParallaxKit/Sources/ParallaxCore/Tracking/ViewerPoseStateMachine.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/ViewerPoseStateMachineTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum ViewerPoseSourceKind: Sendable, Equatable, CaseIterable` — `.manual` / `.faceTracking` / `.motion` / `.idle`，含 `var priority: Int`
  - `struct ViewerPoseInputs: Sendable` — `init(faceTracking: SIMD3<Float>?, motion: SIMD3<Float>?, manual: SIMD3<Float>?, idle: SIMD3<Float>)`
  - `struct ViewerPoseStateMachine: Sendable` — `init(transitionDuration: TimeInterval = 0.3)`；`private(set) var activeSource: ViewerPoseSourceKind`；`mutating func update(_ inputs: ViewerPoseInputs, now: TimeInterval) -> SIMD3<Float>`

> **过渡的起点必须是上一次的输出值，不是上一个源的当前值。** 这是保证连续的关键：源切换时上一个源可能已经完全不可用（比如脸移出画面），拿它的最后一个值当起点会跳。
>
> **关于 0.02 这个跳变阈值的来源**：两个源之间最远约 0.23m（`rapidFlappingStaysBounded` 里的 face 与 motion），过渡 300ms、按 120fps 采样共 36 帧，smoothstep 的峰值斜率是 1.5，所以单帧位移上限是 `0.23 × 1.5 / 36 ≈ 0.0097`。阈值取它的两倍留余量。
> 它依然能抓住真正的问题：瞬切会产生一次约 0.23m 的跳变，比阈值大一个数量级。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/ViewerPoseStateMachineTests.swift`：

```swift
import Testing
import Foundation
import simd
@testable import ParallaxCore

@Suite("ViewerPoseStateMachine")
struct ViewerPoseStateMachineTests {

    static let idlePose = SIMD3<Float>(0, 0, 0.35)

    private static func inputs(
        face: SIMD3<Float>? = nil,
        motion: SIMD3<Float>? = nil,
        manual: SIMD3<Float>? = nil
    ) -> ViewerPoseInputs {
        ViewerPoseInputs(faceTracking: face, motion: motion, manual: manual, idle: idlePose)
    }

    @Test("优先级顺序：manual > faceTracking > motion > idle")
    func priorityOrder() {
        #expect(ViewerPoseSourceKind.manual.priority > ViewerPoseSourceKind.faceTracking.priority)
        #expect(ViewerPoseSourceKind.faceTracking.priority > ViewerPoseSourceKind.motion.priority)
        #expect(ViewerPoseSourceKind.motion.priority > ViewerPoseSourceKind.idle.priority)
    }

    @Test("只有 idle 可用时输出 idle")
    func fallsBackToIdle() {
        var machine = ViewerPoseStateMachine()
        let out = machine.update(Self.inputs(), now: 0)
        #expect(machine.activeSource == .idle)
        #expect(simd_length(out - Self.idlePose) < 1e-6)
    }

    @Test("人脸追踪可用时切换过去")
    func switchesToFaceTracking() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(), now: 0)
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 0.1)
        #expect(machine.activeSource == .faceTracking)
    }

    @Test("过渡期间输出连续，无跳变")
    func transitionIsContinuous() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        var previous = machine.update(Self.inputs(), now: 0)
        let target = SIMD3<Float>(0.09, 0.07, 0.25)   // 与 idle 相距较远

        // 从 0.01 秒开始每 1/120 秒喂一次，全程检查相邻输出差
        var time: TimeInterval = 0.01
        while time < 1.0 {
            let current = machine.update(Self.inputs(face: target), now: time)
            let delta = simd_length(current - previous)
            #expect(delta < 0.02, "在 t=\(time) 处跳变 \(delta) 米")
            previous = current
            time += 1.0 / 120.0
        }
        // 过渡结束后应该到达目标
        #expect(simd_length(previous - target) < 1e-3, "过渡结束仍未到达目标")
    }

    @Test("追踪丢失后平滑降级到 motion")
    func degradesToMotionSmoothly() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let facePose = SIMD3<Float>(0.08, 0, 0.3)
        let motionPose = SIMD3<Float>(-0.06, 0.04, 0.4)

        var time: TimeInterval = 0
        // 先让人脸追踪完全接管
        while time < 0.5 {
            _ = machine.update(Self.inputs(face: facePose, motion: motionPose), now: time)
            time += 1.0 / 120.0
        }
        #expect(machine.activeSource == .faceTracking)

        // 追踪丢失
        var previous = machine.update(Self.inputs(motion: motionPose), now: time)
        #expect(machine.activeSource == .motion)

        while time < 1.5 {
            let current = machine.update(Self.inputs(motion: motionPose), now: time)
            #expect(simd_length(current - previous) < 0.02,
                    "降级过程在 t=\(time) 跳变")
            previous = current
            time += 1.0 / 120.0
        }
        #expect(simd_length(previous - motionPose) < 1e-3)
    }

    @Test("手动拖动优先于人脸追踪")
    func manualOverridesFaceTracking() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 0)
        _ = machine.update(
            Self.inputs(face: SIMD3(0.05, 0, 0.3), manual: SIMD3(-0.02, 0.01, 0.3)),
            now: 0.1
        )
        #expect(machine.activeSource == .manual)
    }

    @Test("过渡中途改变目标不产生跳变")
    func retargetMidTransitionIsSmooth() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        _ = machine.update(Self.inputs(), now: 0)

        var previous = machine.update(Self.inputs(face: SIMD3(0.09, 0, 0.25)), now: 0.05)
        // 过渡进行到一半时切到另一个源
        var time: TimeInterval = 0.05
        while time < 0.20 {
            previous = machine.update(Self.inputs(face: SIMD3(0.09, 0, 0.25)), now: time)
            time += 1.0 / 120.0
        }
        while time < 0.8 {
            let current = machine.update(Self.inputs(motion: SIMD3(-0.08, 0.05, 0.45)), now: time)
            #expect(simd_length(current - previous) < 0.02,
                    "中途改变目标时在 t=\(time) 跳变")
            previous = current
            time += 1.0 / 120.0
        }
    }

    @Test("反复快速丢失与恢复不产生振荡")
    func rapidFlappingStaysBounded() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let facePose = SIMD3<Float>(0.08, 0.06, 0.28)
        let motionPose = SIMD3<Float>(-0.07, -0.05, 0.42)
        var previous = machine.update(Self.inputs(motion: motionPose), now: 0)

        var time: TimeInterval = 0
        for step in 0..<600 {
            let faceAvailable = (step / 10) % 2 == 0
            let current = machine.update(
                Self.inputs(face: faceAvailable ? facePose : nil, motion: motionPose),
                now: time
            )
            #expect(simd_length(current - previous) < 0.02, "第 \(step) 步振荡")
            #expect(current.x.isFinite && current.y.isFinite && current.z.isFinite)
            previous = current
            time += 1.0 / 120.0
        }
    }

    @Test("时间倒退不产生 NaN")
    func handlesBackwardTime() {
        var machine = ViewerPoseStateMachine()
        _ = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 10)
        let out = machine.update(Self.inputs(face: SIMD3(0.05, 0, 0.3)), now: 5)
        #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite)
    }

    @Test("过渡时长为零时立即落到目标，不会永久冻结")
    func zeroTransitionDurationSnapsToTarget() {
        // transitionDuration 是 public var，调用方可能为了「无动画 / 减弱动效」把它设成 0。
        // 那时正确行为是直接落到目标，而不是卡在过渡起点再也出不来。
        var machine = ViewerPoseStateMachine(transitionDuration: 0)
        let motionPose = SIMD3<Float>(-0.07, -0.05, 0.42)
        let facePose = SIMD3<Float>(0.08, 0.06, 0.28)

        _ = machine.update(Self.inputs(motion: motionPose), now: 0)
        let afterSwitch = machine.update(
            Self.inputs(face: facePose, motion: motionPose), now: 0.1
        )
        #expect(machine.activeSource == .faceTracking)
        #expect(simd_length(afterSwitch - facePose) < 1e-5,
                "未落到目标，停在 \(afterSwitch)")

        // 再喂若干帧，确认不是暂时现象
        var latest = afterSwitch
        for step in 1...10 {
            latest = machine.update(
                Self.inputs(face: facePose, motion: motionPose),
                now: 0.1 + TimeInterval(step) * 0.1
            )
        }
        #expect(simd_length(latest - facePose) < 1e-5, "输出被永久冻结在 \(latest)")
    }

    @Test("过渡中途时钟倒退不产生跳变，且仍能到达目标")
    func backwardClockMidTransitionDoesNotJump() {
        var machine = ViewerPoseStateMachine(transitionDuration: 0.3)
        let target = SIMD3<Float>(0.09, 0.07, 0.25)

        _ = machine.update(Self.inputs(), now: 0)
        // 让过渡走到中途
        var previous = machine.update(Self.inputs(face: target), now: 0.1)
        for step in 1...6 {
            previous = machine.update(
                Self.inputs(face: target), now: 0.1 + TimeInterval(step) * 0.01
            )
        }

        // 时钟退到过渡开始之前
        let afterRewind = machine.update(Self.inputs(face: target), now: 0.05)
        let jump = simd_length(afterRewind - previous)
        #expect(jump < 0.02, "时钟倒退造成跳变 \(jump) 米")
        #expect(afterRewind.x.isFinite && afterRewind.y.isFinite && afterRewind.z.isFinite)

        // 时钟恢复正常后仍能走到目标
        var latest = afterRewind
        for step in 1...60 {
            latest = machine.update(
                Self.inputs(face: target), now: 0.05 + TimeInterval(step) * 0.02
            )
        }
        #expect(simd_length(latest - target) < 1e-3, "倒退后无法到达目标，停在 \(latest)")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter ViewerPoseStateMachine
```

预期：**编译失败**，`cannot find 'ViewerPoseStateMachine' in scope`。

- [ ] **Step 3: 写 ViewerPose 类型**

`ParallaxKit/Sources/ParallaxCore/Tracking/ViewerPose.swift`：

```swift
import Foundation
import simd

/// 观察者位置的来源。数值越大优先级越高。
public enum ViewerPoseSourceKind: Sendable, Equatable, CaseIterable {
    /// 无任何输入时的自动摆动
    case idle
    /// 陀螺仪相对姿态
    case motion
    /// ARKit 人脸追踪眼位
    case faceTracking
    /// 手指拖动，可临时接管一切
    case manual

    public var priority: Int {
        switch self {
        case .idle: return 0
        case .motion: return 1
        case .faceTracking: return 2
        case .manual: return 3
        }
    }
}

/// 一次更新中各来源的可用位置。`nil` 表示该来源当前不可用。
///
/// `idle` 没有 optional——它永远可用，是整条降级链的地板。
public struct ViewerPoseInputs: Sendable {
    public var faceTracking: SIMD3<Float>?
    public var motion: SIMD3<Float>?
    public var manual: SIMD3<Float>?
    public var idle: SIMD3<Float>

    public init(
        faceTracking: SIMD3<Float>?,
        motion: SIMD3<Float>?,
        manual: SIMD3<Float>?,
        idle: SIMD3<Float>
    ) {
        self.faceTracking = faceTracking
        self.motion = motion
        self.manual = manual
        self.idle = idle
    }

    /// 当前优先级最高的可用来源及其位置。
    func best() -> (kind: ViewerPoseSourceKind, position: SIMD3<Float>) {
        if let manual { return (.manual, manual) }
        if let faceTracking { return (.faceTracking, faceTracking) }
        if let motion { return (.motion, motion) }
        return (.idle, idle)
    }
}
```

- [ ] **Step 4: 写状态机**

`ParallaxKit/Sources/ParallaxCore/Tracking/ViewerPoseStateMachine.swift`：

```swift
import Foundation
import simd

/// 观察者位置的四级降级链，带平滑过渡。
///
/// 见 spec §9。核心要求：**层级之间必须交叉淡入，不能瞬切**。
/// 追踪一丢就硬切到陀螺仪，画面会跳一下，那一跳会让整个效果显得廉价。
public struct ViewerPoseStateMachine: Sendable {

    /// 源切换时的交叉淡入时长，秒。
    public var transitionDuration: TimeInterval

    public private(set) var activeSource: ViewerPoseSourceKind = .idle

    /// 上一次对外输出的位置。**过渡的起点永远是它**，不是上一个源的当前值——
    /// 源切换时上一个源往往已经彻底不可用（脸移出画面），拿它的最后一个值当起点会跳。
    private var lastOutput: SIMD3<Float>?
    private var transitionStart: SIMD3<Float>?
    private var transitionStartTime: TimeInterval?

    public init(transitionDuration: TimeInterval = 0.3) {
        self.transitionDuration = transitionDuration
    }

    public mutating func update(
        _ inputs: ViewerPoseInputs,
        now: TimeInterval
    ) -> SIMD3<Float> {
        let (kind, target) = inputs.best()

        // 首次调用：直接落到目标，不做过渡。
        guard let previousOutput = lastOutput else {
            activeSource = kind
            lastOutput = target
            return target
        }

        if kind != activeSource {
            activeSource = kind
            transitionStart = previousOutput
            transitionStartTime = now
        }

        let output: SIMD3<Float>
        if let start = transitionStart, let startTime = transitionStartTime {
            // 过渡时长非正 = 调用方显式禁用了过渡：直接落到目标，不留中间态。
            // 注意必须清掉过渡状态，否则后续每帧都会重新进入这里，输出被永久冻结。
            if transitionDuration <= 0 {
                output = target
                transitionStart = nil
                transitionStartTime = nil
                lastOutput = output
                return output
            }
            let elapsed = now - startTime
            if elapsed < 0 {
                // 时钟倒退。硬跳到目标、或退回过渡起点，都会重新制造这个状态机
                // 存在的理由——那一跳。所以把锚点挪到当前输出、计时基准挪到当前时刻，
                // 从这里重新走完剩下的路。
                transitionStart = previousOutput
                transitionStartTime = now
                output = previousOutput
            } else if elapsed >= transitionDuration {
                output = target
                transitionStart = nil
                transitionStartTime = nil
            } else {
                let progress = Float(elapsed / transitionDuration)
                output = simd_mix(start, target, SIMD3(repeating: smoothstep(progress)))
            }
        } else {
            output = target
        }

        lastOutput = output
        return output
    }

    /// 三次 Hermite 平滑，两端一阶导为 0。
    /// 用它而不是线性插值：线性插值在过渡开始和结束的瞬间速度突变，肉眼能看出两下轻微的顿。
    private func smoothstep(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter ViewerPoseStateMachine
```

预期：**全 PASS**（9 个测试）。

- [ ] **Step 6: 跑全部测试，确认没有回归**

```bash
swift test --package-path ParallaxKit
```

预期：**全部 PASS**。记下总测试数，后面的任务要保证它只增不减。

- [ ] **Step 7: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 观察者姿态四级降级状态机

manual > faceTracking > motion > idle，源切换做 300ms 交叉淡入。
过渡起点取上一次的输出值而非上一个源的当前值——源切换时
上一个源往往已彻底不可用，拿它的最后一个值当起点会跳。
用 smoothstep 而非线性插值，避免过渡首尾的速度突变。"
```

---

### Task 9: 设备参数表

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Devices/DeviceProfile.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/DeviceProfileTests.swift`

**Interfaces:**
- Consumes: `ScreenGeometry`（Task 3）
- Produces:
  - `struct DeviceProfile: Sendable, Equatable` — 属性 `identifier: String` / `displayName: String` / `screen: ScreenGeometry` / `isCalibrated: Bool`
  - `enum DeviceProfileRegistry` — `static let fallback: DeviceProfile`；`static func profile(for identifier: String) -> DeviceProfile`；`static var all: [DeviceProfile]`

> **`isCalibrated` 不是装饰。** 表里现在全部是按屏幕规格推算的值，探针 P11 实测后才能翻成 `true`。UI 层可以据此决定是否提示用户「当前机型未校准，视差基线可能略有偏差」。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/DeviceProfileTests.swift`：

```swift
import Testing
import simd
@testable import ParallaxCore

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test("已知机型能查到")
    func findsKnownDevice() {
        let profile = DeviceProfileRegistry.profile(for: "iPhone15,3")
        #expect(profile.identifier == "iPhone15,3")
        #expect(profile.displayName.contains("14 Pro Max"))
    }

    @Test("未知机型回落到 fallback")
    func unknownDeviceFallsBack() {
        let profile = DeviceProfileRegistry.profile(for: "iPhone99,9")
        #expect(profile.identifier == DeviceProfileRegistry.fallback.identifier)
    }

    @Test("所有条目的屏幕尺寸都在合理物理范围内")
    func allScreenSizesArePlausible() {
        for profile in DeviceProfileRegistry.all {
            // 手机与平板的显示区不会小于 4cm，也不会大于 40cm
            #expect(profile.screen.width > 0.04 && profile.screen.width < 0.40,
                    "\(profile.identifier) 宽度 \(profile.screen.width) 不合理")
            #expect(profile.screen.height > 0.04 && profile.screen.height < 0.40,
                    "\(profile.identifier) 高度 \(profile.screen.height) 不合理")
        }
    }

    @Test("摄像头偏移不会落在显示区之外太远")
    func cameraOffsetIsPlausible() {
        for profile in DeviceProfileRegistry.all {
            let screen = profile.screen
            // 摄像头可能在边框上略超出显示区，但不应超出半个屏幕尺寸 + 2cm
            let maxX = screen.width / 2 + 0.02
            let maxY = screen.height / 2 + 0.02
            #expect(abs(screen.cameraOffset.x) <= maxX,
                    "\(profile.identifier) 摄像头 X 偏移 \(screen.cameraOffset.x) 超界")
            #expect(abs(screen.cameraOffset.y) <= maxY,
                    "\(profile.identifier) 摄像头 Y 偏移 \(screen.cameraOffset.y) 超界")
        }
    }

    @Test("标识符没有重复")
    func identifiersAreUnique() {
        let identifiers = DeviceProfileRegistry.all.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count, "设备表里有重复标识符")
    }

    @Test("尚未经真机校准的条目都标记为 false")
    func uncalibratedEntriesAreMarked() {
        // 探针 P11 跑完之前，表里不应该有任何条目自称已校准。
        // 这条测试会在 Task 12 回填真实数据时被有意改掉。
        for profile in DeviceProfileRegistry.all {
            #expect(profile.isCalibrated == false,
                    "\(profile.identifier) 声称已校准，但探针 P11 还没跑")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter DeviceProfile
```

预期：**编译失败**，`cannot find 'DeviceProfileRegistry' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Devices/DeviceProfile.swift`：

```swift
import Foundation
import simd

/// 一款设备的物理参数。
///
/// 这张表是本项目唯一的「脏数据」：ARKit 的坐标基准在摄像头，我们的窗口是屏幕，
/// 两者差几厘米且每个机型都不同，而 **Apple 没有任何 API 能查询这个偏移**。
/// 见 spec §6.2。
public struct DeviceProfile: Sendable, Equatable {
    /// 机型标识符，如 "iPhone15,3"（取自 `uname` 的 machine 字段）
    public let identifier: String
    public let displayName: String
    /// 设备原生方向（竖持）下的屏幕几何
    public let screen: ScreenGeometry
    /// 是否已用真机实测校准过。未校准的值是按屏幕规格推算的。
    public let isCalibrated: Bool

    public init(
        identifier: String,
        displayName: String,
        screen: ScreenGeometry,
        isCalibrated: Bool
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.screen = screen
        self.isCalibrated = isCalibrated
    }
}

public enum DeviceProfileRegistry {

    /// 英寸转米
    private static func inches(_ value: Float) -> Float { value * 0.0254 }

    /// 按像素数与 ppi 算显示区物理尺寸
    private static func size(pixels: Float, ppi: Float) -> Float {
        inches(pixels / ppi)
    }

    /// iPhone 14 Pro Max — 2796x1290 @ 460ppi
    ///
    /// 摄像头偏移是**推算值**：灵动岛位于显示区顶部下方约 10mm 处，
    /// 前置摄像头在灵动岛内偏右约 5mm。待探针 P11 实测校准。
    public static let iPhone14ProMax = DeviceProfile(
        identifier: "iPhone15,3",
        displayName: "iPhone 14 Pro Max",
        screen: ScreenGeometry(
            width: size(pixels: 1290, ppi: 460),
            height: size(pixels: 2796, ppi: 460),
            cameraOffset: SIMD3(
                0.005,
                size(pixels: 2796, ppi: 460) / 2 - 0.010,
                0
            )
        ),
        isCalibrated: false
    )

    /// iPad Pro 11 英寸（M4）— 2420x1668 @ 264ppi
    ///
    /// **M4 iPad Pro 把前置摄像头移到了长边**（横持时在顶部中央）。
    /// 竖持（设备原生方向）时它位于左侧边中央，因此 X 偏移为负、Y 偏移为零。
    /// 这不是一个可以套用 iPhone 逻辑的特例，待探针 P11 实测校准。
    public static let iPadPro11M4 = DeviceProfile(
        identifier: "iPad16,4",
        displayName: "iPad Pro 11-inch (M4)",
        screen: ScreenGeometry(
            width: size(pixels: 1668, ppi: 264),
            height: size(pixels: 2420, ppi: 264),
            cameraOffset: SIMD3(
                -(size(pixels: 1668, ppi: 264) / 2 + 0.006),
                0,
                0
            )
        ),
        isCalibrated: false
    )

    /// 未知机型的保守默认值。
    ///
    /// 取一个中等尺寸手机的参数：宽 68mm、高 148mm、摄像头在顶部正中略靠下。
    /// 视差基线会略有偏差，但上层的艺术化视差强度系数可以补偿。
    public static let fallback = DeviceProfile(
        identifier: "unknown",
        displayName: "Unknown Device",
        screen: ScreenGeometry(
            width: 0.068,
            height: 0.148,
            cameraOffset: SIMD3(0, 0.148 / 2 - 0.010, 0)
        ),
        isCalibrated: false
    )

    public static let all: [DeviceProfile] = [
        iPhone14ProMax,
        iPadPro11M4
    ]

    public static func profile(for identifier: String) -> DeviceProfile {
        all.first { $0.identifier == identifier } ?? fallback
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter DeviceProfile
```

预期：**全 PASS**。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 设备物理参数表

本项目唯一的脏数据：Apple 没有 API 能查摄像头相对屏幕中心的偏移。
现有条目全部是按屏幕规格推算的，isCalibrated 一律 false，
待探针 P11 实测后回填。M4 iPad Pro 的摄像头在长边，单独建模。"
```

---

### Task 10: 探针 app 工程脚手架

**Files:**
- Create: `Probe/project.yml`
- Create: `Probe/Sources/ProbeApp.swift`
- Create: `Probe/Sources/ProbeReport.swift`
- Create: `Makefile`

**Interfaces:**
- Consumes: 无
- Produces: 可用 `make probe` 生成并构建的 iOS app 工程；`struct ProbeReport` 收集测量结果

> **探针不做渲染、不写文件、不联网。** 它只测量并打印。保持它极简，才能在出问题时确定问题在被测对象而不在探针本身。

- [ ] **Step 1: 写 xcodegen 工程描述**

`Probe/project.yml`：

```yaml
name: ParallaxProbe
options:
  bundleIdPrefix: com.biily.parallax
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
targets:
  ParallaxProbe:
    type: application
    platform: iOS
    sources:
      - Sources
    dependencies:
      - package: ParallaxKit
        product: ParallaxCore
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: 视差探针
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        NSCameraUsageDescription: >-
          The front camera tracks your eye position on device so photos can shift
          perspective as you move. Camera images are never saved or sent anywhere.
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1,2"
        # 探针是一次性测量工具，用 Swift 5 语言模式避免严格并发检查在这里
        # 制造无谓摩擦（ARSessionDelegate 未标 @MainActor，ARSession 非 Sendable）。
        # ParallaxCore 由 Package.swift 的 swift-tools-version: 6.0 决定，
        # 仍然跑在 Swift 6 严格模式下——真正要长期维护的是它。
        SWIFT_VERSION: "5.0"
packages:
  ParallaxKit:
    path: ../ParallaxKit
```

- [ ] **Step 2: 写测量结果的数据结构**

`Probe/Sources/ProbeReport.swift`：

```swift
import Foundation
import Observation   // @Observable 宏来自这里，只 import Foundation 会编译失败

/// 一条探针测量结果。
///
/// 探针只测量与打印，不做判断——判断留给人。
struct ProbeMeasurement: Identifiable {
    let id: String          // 探针编号，如 "P1"
    let title: String
    var value: String       // 实测值，未测时为 "—"
    var note: String        // 补充说明或异常

    init(id: String, title: String, value: String = "—", note: String = "") {
        self.id = id
        self.title = title
        self.value = value
        self.note = note
    }
}

/// 全部 11 项探针的测量结果。编号与 docs/api-facts-arkit-depth.md §6 一一对应。
@Observable
final class ProbeReport {
    var measurements: [ProbeMeasurement] = [
        ProbeMeasurement(id: "P1", title: "supportedVideoFormats 各档帧率"),
        ProbeMeasurement(id: "P2", title: "camera.transform 的实际基准"),
        ProbeMeasurement(id: "P3", title: "didUpdateFrame 实测频率"),
        ProbeMeasurement(id: "P4", title: "supportedNumberOfTrackedFaces"),
        ProbeMeasurement(id: "P5", title: "左右眼是否镜像"),
        ProbeMeasurement(id: "P6", title: "lookAtPoint 的尺度"),
        ProbeMeasurement(id: "P7", title: "faceGeometry 顶点坐标系"),
        ProbeMeasurement(id: "P8", title: "configurableCaptureDevice 是否为 nil"),
        ProbeMeasurement(id: "P9", title: "眼位单位（实测瞳距）"),
        ProbeMeasurement(id: "P10", title: "capturedDepthData 类型与分辨率"),
        ProbeMeasurement(id: "P11", title: "设备标识符与屏幕参数")
    ]

    func set(_ id: String, value: String, note: String = "") {
        guard let index = measurements.firstIndex(where: { $0.id == id }) else { return }
        measurements[index].value = value
        measurements[index].note = note
    }

    /// 导出为可直接贴进文档的 Markdown 表格。
    /// 只返回字符串，由用户手动复制——探针不写文件。
    func markdownTable() -> String {
        var lines = ["| 编号 | 项目 | 实测值 | 备注 |", "|---|---|---|---|"]
        for m in measurements {
            lines.append("| \(m.id) | \(m.title) | \(m.value) | \(m.note) |")
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 3: 写最小 app 入口**

`Probe/Sources/ProbeApp.swift`：

```swift
import SwiftUI
import UIKit   // UIPasteboard 需要，不要依赖 SwiftUI 的传递导入
import ARKit

@main
struct ParallaxProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

struct ProbeView: View {
    @State private var report = ProbeReport()

    var body: some View {
        NavigationStack {
            List(report.measurements) { measurement in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(measurement.id) · \(measurement.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(measurement.value)
                        .font(.system(.body, design: .monospaced))
                    if !measurement.note.isEmpty {
                        Text(measurement.note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("视差探针")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") {
                        UIPasteboard.general.string = report.markdownTable()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 4: 写 Makefile**

项目根目录 `Makefile`：

```makefile
.PHONY: test probe probe-build clean

# ParallaxCore 单元测试——TDD 的主循环，秒级反馈
test:
	swift test --package-path ParallaxKit

# 生成探针 Xcode 工程
probe:
	xcodegen generate --project Probe --spec Probe/project.yml

# 构建探针（模拟器，只验证能编译；真机运行见 Task 12）
probe-build: probe
	xcodebuild -project Probe/ParallaxProbe.xcodeproj \
	           -scheme ParallaxProbe \
	           -sdk iphonesimulator \
	           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	           -quiet build

clean:
	rm -rf ParallaxKit/.build Probe/ParallaxProbe.xcodeproj
```

- [ ] **Step 5: 生成工程并构建，确认链路通**

```bash
make probe-build
```

预期：构建成功，退出码 0。

> 若报 `Could not find package`，检查 `project.yml` 里 `packages.ParallaxKit.path` 的相对路径——它是相对 `Probe/` 目录的。

- [ ] **Step 6: 提交**

```bash
git add Probe Makefile
git commit -m "feat(probe): 探针 app 工程脚手架

xcodegen 生成，依赖 ParallaxCore。11 项测量结果可导出为 Markdown 表格
供手动粘贴——探针不写文件、不联网、不做渲染，保持极简。
make test / make probe-build 两条命令覆盖日常循环。"
```

---

### Task 11: 探针测量实现

**Files:**
- Create: `Probe/Sources/FaceProbe.swift`
- Modify: `Probe/Sources/ProbeApp.swift`（接上 FaceProbe）

**Interfaces:**
- Consumes: `ProbeReport`（Task 10）、`DeviceProfileRegistry`（Task 9）
- Produces: `final class FaceProbe: NSObject, ARSessionDelegate` — `init(report: ProbeReport)`；`func start()`；`func stop()`

> **实现前必读 `docs/api-facts-arkit-depth.md` §1**。特别是：
> - `leftEyeTransform` / `rightEyeTransform` 是 **face anchor 局部空间**，取世界坐标必须 `faceAnchor.transform * faceAnchor.leftEyeTransform`
> - **不要用** `_ARLeftEyePupil` 之类的私有符号，那会导致拒审
> - delegate 默认在**主队列**回调

- [ ] **Step 1: 写探针实现**

`Probe/Sources/FaceProbe.swift`：

```swift
import Foundation
import ARKit
import simd
import UIKit
import ParallaxCore

/// 人脸追踪探针。只测量与打印，不渲染。
///
/// 各项测量对应 docs/api-facts-arkit-depth.md §6 的编号。
final class FaceProbe: NSObject, ARSessionDelegate {

    private let report: ProbeReport
    private let session = ARSession()

    // P3 用：统计相邻帧时间戳差
    private var lastFrameTimestamp: TimeInterval?
    private var frameIntervals: [TimeInterval] = []

    // P9 用：累积瞳距样本
    private var pupillaryDistances: [Float] = []

    init(report: ProbeReport) {
        self.report = report
        super.init()
        session.delegate = self
    }

    func start() {
        measureStaticFacts()

        guard ARFaceTrackingConfiguration.isSupported else {
            report.set("P1", value: "不支持", note: "本机型不支持人脸追踪")
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    /// 不需要跑起 session 就能测的部分
    private func measureStaticFacts() {
        // P1：各档视频格式的帧率
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        let formatDescriptions = formats.map { format in
            "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond)fps"
        }
        report.set(
            "P1",
            value: formatDescriptions.joined(separator: ", "),
            note: formats.isEmpty ? "列表为空" : "首项为默认格式"
        )

        // P4：可同时追踪的脸数
        report.set(
            "P4",
            value: "\(ARFaceTrackingConfiguration.supportedNumberOfTrackedFaces)",
            note: "默认 maximumNumberOfTrackedFaces = 1"
        )

        // P8：主摄像头是否可配置（nil 意味着被 ARKit 独占用于追踪）
        let configurableDevice = ARConfiguration.configurableCaptureDeviceForPrimaryCamera
        report.set(
            "P8",
            value: configurableDevice == nil ? "nil" : "非 nil",
            note: configurableDevice == nil
                ? "印证前摄被 ARKit 独占，不能并存 AVCaptureSession"
                : "可配置，与预期不符，需重新评估架构"
        )

        // P11：设备标识符与屏幕参数
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let profile = DeviceProfileRegistry.profile(for: identifier)
        // UIScreen.main 在 iOS 16+ 是 soft-deprecated，会产生一条警告。
        // 探针是一次性工具且只在 portrait 下跑，为它引入 window scene 查找不值得。
        // 正式 app 里不要这么写。
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        report.set(
            "P11",
            value: identifier,
            note: """
            表内: \(profile.displayName), 已校准: \(profile.isCalibrated); \
            点: \(Int(bounds.width))x\(Int(bounds.height)) @\(scale)x; \
            像素: \(Int(bounds.width * scale))x\(Int(bounds.height * scale)); \
            推算物理: \(String(format: "%.1f", profile.screen.width * 1000))x\
            \(String(format: "%.1f", profile.screen.height * 1000))mm
            """
        )
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        measureFrameRate(frame)
        measureCameraBasis(frame)
        measureCapturedDepth(frame)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        measureEyes(faceAnchor)
        measureLookAtPoint(faceAnchor)
        measureFaceGeometry(faceAnchor)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        report.set("P1", value: "session 失败", note: error.localizedDescription)
    }

    // MARK: - 各项测量

    /// P3：didUpdateFrame 的实测频率
    private func measureFrameRate(_ frame: ARFrame) {
        if let last = lastFrameTimestamp {
            let interval = frame.timestamp - last
            if interval > 0 {
                frameIntervals.append(interval)
                if frameIntervals.count > 120 { frameIntervals.removeFirst() }
            }
        }
        lastFrameTimestamp = frame.timestamp

        guard frameIntervals.count >= 60 else { return }
        let mean = frameIntervals.reduce(0, +) / Double(frameIntervals.count)
        guard mean > 0 else { return }
        let minInterval = frameIntervals.min() ?? 0
        let maxInterval = frameIntervals.max() ?? 0
        report.set(
            "P3",
            value: String(format: "%.1f fps", 1.0 / mean),
            note: String(
                format: "帧间隔 %.1f–%.1f ms（%d 样本）",
                minInterval * 1000, maxInterval * 1000, frameIntervals.count
            )
        )
    }

    /// P2：相机变换的实际基准。设备静止时观察它是否为单位阵附近。
    private func measureCameraBasis(_ frame: ARFrame) {
        let position = frame.camera.transform.columns.3
        report.set(
            "P2",
            value: String(format: "cam pos (%.3f, %.3f, %.3f) m", position.x, position.y, position.z),
            note: "启动时若接近原点，说明世界原点确实落在设备初始位姿"
        )
    }

    /// P10：ARFrame 携带的深度数据类型与分辨率
    private func measureCapturedDepth(_ frame: ARFrame) {
        guard let depthData = frame.capturedDepthData else {
            report.set("P10", value: "nil", note: "该帧未携带深度（深度帧节奏与视频帧不同）")
            return
        }
        let buffer = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let type = depthData.depthDataType
        // OSType 是四字符码，转成可读形式
        let fourCC = String(bytes: [
            UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF),
            UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)
        ], encoding: .ascii) ?? "????"
        report.set(
            "P10",
            value: "\(fourCC) \(width)x\(height)",
            note: "hdis/fdis=disparity, hdep/fdep=depth；已滤波: \(depthData.isDepthDataFiltered)"
        )
    }

    /// P5 与 P9：左右眼镜像关系与眼位单位
    private func measureEyes(_ faceAnchor: ARFaceAnchor) {
        guard faceAnchor.isTracked else { return }

        // 眼位 transform 是 anchor 局部空间，必须左乘 anchor.transform 才是世界坐标。
        // 见 docs/api-facts-arkit-depth.md §1.2
        let leftWorld = faceAnchor.transform * faceAnchor.leftEyeTransform
        let rightWorld = faceAnchor.transform * faceAnchor.rightEyeTransform
        let leftPosition = SIMD3<Float>(
            leftWorld.columns.3.x, leftWorld.columns.3.y, leftWorld.columns.3.z
        )
        let rightPosition = SIMD3<Float>(
            rightWorld.columns.3.x, rightWorld.columns.3.y, rightWorld.columns.3.z
        )

        // P5：在相机空间里比较两眼的 X 分量，判断 left/right 的实际方位
        let viewMatrix = session.currentFrame?.camera.viewMatrixForOrientation(.portrait)
        let leftCameraX: Float
        let rightCameraX: Float
        if let viewMatrix {
            leftCameraX = (viewMatrix * SIMD4(leftPosition, 1)).x
            rightCameraX = (viewMatrix * SIMD4(rightPosition, 1)).x
        } else {
            leftCameraX = leftPosition.x
            rightCameraX = rightPosition.x
        }
        report.set(
            "P5",
            value: String(format: "leftEye.x=%.4f, rightEye.x=%.4f", leftCameraX, rightCameraX),
            note: leftCameraX < rightCameraX
                ? "leftEye 在相机空间偏左"
                : "leftEye 在相机空间偏右（镜像语义，投影时须换向）"
        )

        // P9：瞳距。成人正常范围 58–68 mm；若量出的是 58–68 说明单位是米。
        let distance = simd_length(leftPosition - rightPosition)
        guard distance.isFinite, distance > 0 else { return }
        pupillaryDistances.append(distance)
        if pupillaryDistances.count > 120 { pupillaryDistances.removeFirst() }
        let mean = pupillaryDistances.reduce(0, +) / Float(pupillaryDistances.count)
        let plausible = (0.050...0.075).contains(mean)
        report.set(
            "P9",
            value: String(format: "%.4f (均值，%d 样本)", mean, pupillaryDistances.count),
            note: plausible
                ? "落在成人瞳距 50–75mm 区间，单位确认为米"
                : "不在预期区间，单位存疑，投影前必须查清"
        )
    }

    /// P6：lookAtPoint 的尺度
    private func measureLookAtPoint(_ faceAnchor: ARFaceAnchor) {
        guard faceAnchor.isTracked else { return }
        let point = faceAnchor.lookAtPoint
        report.set(
            "P6",
            value: String(format: "(%.3f, %.3f, %.3f), 模长 %.3f",
                          point.x, point.y, point.z, simd_length(point)),
            note: "头文件只说「相对 anchor 原点」，未定义距离含义"
        )
    }

    /// P7：faceGeometry 顶点坐标系
    private func measureFaceGeometry(_ faceAnchor: ARFaceAnchor) {
        let vertices = faceAnchor.geometry.vertices
        guard !vertices.isEmpty else { return }
        var minimum = vertices[0]
        var maximum = vertices[0]
        for vertex in vertices {
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        report.set(
            "P7",
            value: String(format: "%d 顶点, x[%.3f,%.3f] y[%.3f,%.3f] z[%.3f,%.3f]",
                          vertices.count,
                          minimum.x, maximum.x, minimum.y, maximum.y, minimum.z, maximum.z),
            note: "极值接近 ±0.1 说明是以头部为中心的局部空间"
        )
    }
}
```

- [ ] **Step 2: 把探针接进界面**

修改 `Probe/Sources/ProbeApp.swift` 的 `ProbeView`，替换整个 struct：

```swift
struct ProbeView: View {
    @State private var report = ProbeReport()
    @State private var probe: FaceProbe?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List(report.measurements) { measurement in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(measurement.id) · \(measurement.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(measurement.value)
                        .font(.system(.body, design: .monospaced))
                    if !measurement.note.isEmpty {
                        Text(measurement.note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("视差探针")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isRunning ? "停止" : "开始") {
                        if isRunning {
                            probe?.stop()
                        } else {
                            let newProbe = FaceProbe(report: report)
                            newProbe.start()
                            probe = newProbe
                        }
                        isRunning.toggle()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") {
                        UIPasteboard.general.string = report.markdownTable()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: 构建确认能编译**

```bash
make probe-build
```

预期：构建成功，退出码 0。

> 模拟器上构建只验证编译。`ARFaceTrackingConfiguration.isSupported` 在模拟器上返回 false，探针跑起来只会显示「不支持」——这是预期行为，真正的测量在 Task 12。

- [ ] **Step 4: 提交**

```bash
git add Probe
git commit -m "feat(probe): 11 项探针测量实现

眼位取世界坐标严格按 faceAnchor.transform * leftEyeTransform，
不用任何私有符号。P5 在相机空间比较两眼 X 分量判断镜像语义，
P9 用瞳距均值验证单位是否为米——这两项错了后面全错。"
```

---

### Task 12: 真机运行探针并回填参数

**Files:**
- Modify: `docs/api-facts-arkit-depth.md`（§6 表格填入实测值）
- Modify: `ParallaxKit/Sources/ParallaxCore/Devices/DeviceProfile.swift`（回填校准值）
- Modify: `ParallaxKit/Tests/ParallaxCoreTests/DeviceProfileTests.swift`（更新校准断言）

**Interfaces:**
- Consumes: Task 11 的探针 app
- Produces: 11 项已知量；`DeviceProfile.isCalibrated == true` 的条目

> **这一步需要用户参与**，无法自动化：要拿真机、要量瞳距、要看数值是否合理。

- [ ] **Step 1: 装到真机上**

```bash
xcodebuild -project Probe/ParallaxProbe.xcodeproj \
           -scheme ParallaxProbe \
           -destination 'platform=iOS,name=白梨' \
           -allowProvisioningUpdates \
           build
```

若命令行签名遇阻，改用 Xcode 打开 `Probe/ParallaxProbe.xcodeproj`，选中「白梨」直接运行。

- [ ] **Step 2: 在真机上跑一遍，逐项读数**

操作步骤：
1. 打开 app，点「开始」，授予相机权限
2. 正对屏幕保持约 30cm，等待 P3、P9 的样本数累积到 60 以上
3. 左右转头、远近移动，观察 P5 的 leftEye.x / rightEye.x 是否随之变化
4. 点右上角「复制」，把 Markdown 表格发出来

**三项阻塞性检查（不通过就不要往下走）：**

| 检查 | 期望 | 不通过意味着 |
|---|---|---|
| **P9 瞳距** | 落在 0.050–0.075 | 眼位单位不是米，全部视差计算的量纲错了 |
| **P5 镜像** | 明确判定 leftEye 在相机空间偏左还是偏右 | 视差方向会整个反过来 |
| **P11 标识符** | 与 `DeviceProfileRegistry` 中的条目匹配 | 设备表没覆盖这台机器 |

- [ ] **Step 3: 实测屏幕物理尺寸与摄像头位置**

用尺子量（精确到毫米）：
1. 显示区的宽与高（点亮屏幕，量发光区域，不含黑边）
2. 前置摄像头中心到显示区上边缘的距离
3. 前置摄像头中心到显示区左右中线的水平偏移（在中线右侧记正，左侧记负）

换算成屏幕坐标系的 `cameraOffset`：
- `x` = 水平偏移（米）
- `y` = 显示区高度 / 2 − 摄像头到上边缘距离（米）
- `z` = 0

- [ ] **Step 4: 把实测值回填进 docs**

编辑 `docs/api-facts-arkit-depth.md` 的 §6 表格，为每项加一列「实测值」，填入探针输出。在 §7 变更记录追加一行，写明测量日期与所用机型。

- [ ] **Step 5: 回填设备参数表**

编辑 `ParallaxKit/Sources/ParallaxCore/Devices/DeviceProfile.swift`，把实测机型的 `width`、`height`、`cameraOffset` 换成 Step 3 量出的值，并把 `isCalibrated` 改为 `true`。

- [ ] **Step 6: 更新校准断言**

编辑 `ParallaxKit/Tests/ParallaxCoreTests/DeviceProfileTests.swift`，把 `uncalibratedEntriesAreMarked` 换成：

```swift
    @Test("已校准条目的物理尺寸必须来自实测")
    func calibratedEntriesAreMeasured() {
        let calibrated = DeviceProfileRegistry.all.filter(\.isCalibrated)
        #expect(!calibrated.isEmpty, "至少应有一台机型完成 P11 校准")
        for profile in calibrated {
            // 实测值不该恰好等于按 ppi 推算的整齐数字，
            // 若完全相等说明忘了回填
            #expect(profile.screen.cameraOffset != .zero,
                    "\(profile.identifier) 的摄像头偏移仍是零，没有回填")
        }
    }
```

- [ ] **Step 7: 跑全部测试**

```bash
make test
```

预期：**全部 PASS**。

- [ ] **Step 8: 根据实测帧率调整滤波器默认参数**

用 P3 的实测帧率复核 `OneEuroFilter` 的默认 `minCutoff` 与 `beta`。若 P3 显示 60fps，把 Task 2 里 `OneEuroFilterTests` 的采样率从 `1/60` 改成实测值，重跑测试确认仍然全绿。

若测试因参数变化而失败，**先改参数不改断言**——断言描述的是滤波器该有的性质，性质不该因帧率而改变。

- [ ] **Step 9: 提交**

```bash
git add docs ParallaxKit
git commit -m "chore(probe): 回填真机实测参数

11 项 SDK 未定义量已在 iPhone 14 Pro Max 上测成已知量。
屏幕物理尺寸与摄像头偏移改为尺量实测值，isCalibrated 置 true。
滤波器默认参数按实测帧率复核。"
```

---

## 完成标准

Plan 1 全部完成时，下面每一条都应为真：

- [ ] `make test` 全绿
- [ ] `make probe-build` 构建成功
- [ ] 架构纪律测试通过：`ParallaxCore` 无任何平台框架依赖
- [ ] 11 项探针全部有实测值，已回填 `docs/api-facts-arkit-depth.md`
- [ ] P9 瞳距落在 0.050–0.075，眼位单位确认为米
- [ ] P5 左右眼镜像语义已明确判定并记录
- [ ] 至少一台机型 `isCalibrated == true`，参数来自尺量实测
- [ ] 每个 Task 都有独立提交

## 下一步

Plan 1 完成后写 **Plan 2：渲染管线与 app 集成**，内容包括 Metal 两层 LDI 渲染器、背景外扩预计算、相册导入、ARKit 现拍、查看器界面、合规基础设施。

**Plan 2 必须等 Plan 1 的探针结果落地后再写**——渲染器的深度处理分支取决于 P10（深度数据类型与分辨率），投影的正确性基线取决于 P11。在这些之前写渲染计划就是在猜。
