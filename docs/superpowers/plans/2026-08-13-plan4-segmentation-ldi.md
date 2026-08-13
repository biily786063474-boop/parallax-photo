# Plan 4：分割遮罩与两层 LDI 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** 根治人物轮廓的锯齿——用 Vision 的人像实例分割拿到精确边界，把画面拆成前景层与外扩背景层分别渲染，边缘用遮罩 alpha 羽化。

**Architecture:** 分割与纹理上传在 App target（Vision / CoreVideo / Metal）；**背景外扩填补是纯数据变换，放 `ParallaxCore` 完整 TDD**——这是本计划最容易出错也最值得测的一块。渲染改成两趟：背景层先画（外扩图，位移小），前景层后画（遮罩内区域，深度位移大，遮罩外 discard）。

**Tech Stack:** Swift 6 / Vision / Metal / CoreVideo

## Global Constraints

- `ParallaxCore` **只许 import `Foundation` 与 `simd`**。Vision / CoreVideo / Metal 一律在 App target。
- **归一化深度：[0,1]，0 = 最远，1 = 最近。** 转换只在 `DepthNormalization` 一处发生。
- **严格 TDD**（Task 1、2）；补写的测试必须证明自己能失败。
- **数值断言的边界要实测，不要估算。**
- **不要改动 `parallaxScale = 0.125` / `zeroParallax = 0.68`**——这是用户在真机上调出来的实测值。
- 提交信息用中文；逐项 add，不要 `git add App`。

## 已核实的事实（本计划的输入，不要重新调研）

来自本机 SDK 头文件与实测（Xcode 26.6 / iOS SDK 26.5）：

| 事实 | 依据 |
|---|---|
| `VNGeneratePersonInstanceMaskRequest` 可用性 `ios(17.0)` —— **部署目标内直接可用，无需 `#available`** | `Vision.framework/Headers/VNGeneratePersonInstanceMaskRequest.h:19` |
| `results` 为 `[VNInstanceMaskObservation]`，**能区分多个人** | 同上 `:25` |
| **Swift 拼写**（编译器裁决，与 ObjC 直译不同）：`obs.generateScaledMaskForImage(forInstances:from:)` | `swiftc -typecheck` 实测 |
| 该方法输出**精确等于输入分辨率**、`OneComponent32Float`、**IOSurface-backed**（可直接进 `CVMetalTextureCache`） | 实测 |
| `instanceMask` 属性是固定 512×512 的低分辨率标签图，**不要用它做渲染** | `VNObservation.h:752-766` + 实测 |
| 完全离线 —— 55 个 Vision 头文件检索无任何联网暗示；`sandbox-exec` 断网实测输出逐字节一致 | 实测 |
| 静态图复用 request 实例安全（时序状态需带时间戳的 `CMSampleBuffer` 才触发） | `VNStatefulRequest.h:17` + 实测 |
| 首次调用有 **0.7–2.3s 冷启动**（模型加载），需预热 | 实测（Mac，iPhone 只会更慢） |
| 用户照片实测：`disparityAux=true`、**`portraitMatteAux=false`** —— 内嵌人像遮罩不可依赖 | 真机诊断日志 |

⚠️ **两个坑**：
1. `generateScaledMaskForImage` 必须传**执行该请求的同一个** `VNImageRequestHandler`（它要重读源图），别提前释放。
2. handler 一定要传 `CGImagePropertyOrientation`，否则遮罩相对照片是转过的。

---

### Task 1: 背景外扩填补（Core，严格 TDD）

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/BackgroundInpainting.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/BackgroundInpaintingTests.swift`

**Interfaces:**
- Produces: `enum BackgroundInpainting` — `static func fill(pixels: [UInt8], width: Int, height: Int, holeMask: [Float], threshold: Float = 0.5) -> [UInt8]?`
  - `pixels` 为 RGBA8；`holeMask` 与图同尺寸，**值 ≥ threshold 视为「洞」**（即前景，需要被背景填掉）

> **为什么这块值得单独 TDD**：前景被剔除后，底下露出的必须是合理的背景像素，否则就是黑洞。填补算法是纯数据变换——输入像素数组加一张洞遮罩，输出填好的像素数组，**不涉及任何图形 API**，可以在 Mac 上用构造的小图测死。而它一旦写错，表现是「人物边缘拖出彩色残影」，在真机上极难判断是填补错了还是渲染错了。

**算法**：push-pull（金字塔）。向下采样时只统计非洞像素的加权平均，向上采样时用低层结果填补高层的洞。比逐像素扩散快得多，且填出的颜色更平滑。

- [ ] **Step 1: 写失败的测试**

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**（预期 `cannot find 'BackgroundInpainting' in scope`）
- [ ] **Step 3: 写实现**（push-pull 金字塔）
- [ ] **Step 4: 跑测试确认通过**，全量应为 108 + 6
- [ ] **Step 5: 空转验证**——把实现临时改成「原样返回 pixels」（即不填补），确认 `fillsHoleWithNeighbourColour` 变红，抄输出进报告，改回
- [ ] **Step 6: 提交**

---

### Task 2: 遮罩重采样（Core，严格 TDD）

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/MaskResampling.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/MaskResamplingTests.swift`

**Interfaces:**
- Produces: `enum MaskResampling` — `static func resample(mask: [Float], from: (width: Int, height: Int), to: (width: Int, height: Int)) -> [Float]?`

> **为什么需要它**：Vision 的 `generateScaledMaskForImage` 输出等于**原图**分辨率，而深度图是另一个分辨率（真机实测 iPad 前摄给的是 640×480，相册照片的深度图通常也远小于彩色图）。要在同一套网格上同时采样颜色、深度、遮罩，三者的尺寸关系必须理清。双线性重采样是纯数据变换，可测死。

测试至少覆盖：等尺寸时原样返回、放大后四角值不变、缩小后值域仍在 `[0,1]`、非法尺寸返回 nil、含 NaN 的输入不产生 NaN 输出。

同样要做空转验证（把双线性改成最近邻，确认某条测试能区分）。

---

### Task 3: 分割遮罩加载（App 层）

**Files:**
- Create: `App/Sources/PersonMaskLoader.swift`
- Modify: `App/Sources/DepthPhotoLoader.swift`（返回值加遮罩）

> **TDD 例外**：Vision 请求的正确性无法用断言表达，把关点是 `make app-build` 通过 + 真机看到边缘改善。

要点：

1. `VNGeneratePersonInstanceMaskRequest` + `VNImageRequestHandler(cgImage:orientation:options:)`
2. **orientation 必须传**，与 `DepthPhotoLoader` 里给彩色图和深度图用的是同一个 EXIF 方向
3. `obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)` —— **传同一个 handler**
4. 输出是 `OneComponent32Float` 的 `CVPixelBuffer`：`CVPixelBufferLockBaseAddress` + `defer` unlock，**用 `CVPixelBufferGetBytesPerRow` 读，不要假设 `width * 4`**（这与 Plan 3 Task 1 的 `bytesPerRow` 是同一类坑，可以复用 `DepthPixelUnpacking`）
5. **降级链**：无人 → `VNGenerateForegroundInstanceMaskRequest`（iOS 17 可用，调用形状一致）→ 仍无 → 返回 nil，渲染退回单层模式
6. **冷启动预热**：app 启动后在后台跑一次空请求，避免用户选第一张照片时卡 1–2 秒

---

### Task 4: 两层渲染

**Files:**
- Modify: `App/Sources/ParallaxRenderer.swift`、`App/Sources/Shaders.metal`

设计：

**背景层**（先画）
- 纹理 = `BackgroundInpainting.fill` 后的图
- 深度用背景区域的深度（前景处的深度已无意义，用填补后的深度或统一压到远平面）
- 正常绘制，不 discard

**前景层**（后画，开深度测试）
- 纹理 = 原图
- 片元着色器采样遮罩：**alpha 低于阈值直接 `discard_fragment()`**
- 边缘用遮罩 alpha 做 `smoothstep` 羽化混合，避免硬切出剪影感

**关键**：这样跨越前景/背景边界的三角形，其落在遮罩外的片元被丢弃，露出下层已填补的背景——**锯齿的成因（被拉伸的跨界三角形）就不存在了**。

单层回退：无遮罩时（非人像照、分割失败）走原来的单层路径，不能因为拿不到遮罩就黑屏。

---

### Task 5: 真机验证（需用户参与）

| 检查项 | 期望 |
|---|---|
| 人物轮廓 | 锯齿显著减轻，边缘柔和不像贴纸 |
| 大角度侧头 | 人物边缘露出的是**合理背景**而非黑洞或彩色残影 |
| 非人像照片 | 优雅退回单层，不崩溃不黑屏 |
| 选第一张照片 | 无明显卡顿（冷启动已预热） |
| 帧率 | 两层绘制后仍跟随刷新率 |

## 完成标准

- [ ] `swift test --package-path ParallaxKit` 全绿（108 + 新增）
- [ ] `make app-build` 退出码 0
- [ ] 真机上人物边缘锯齿显著改善
- [ ] 用户确认观感

## 不在本计划范围

app 内拍照、作品库、导出、非人像照片的深度估计、`portraitEffectsMatte` 路径（实测用户照片里没有，不值得为它写分支）。
