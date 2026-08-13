# Plan 2：渲染核心闭环 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iPhone 14 Pro Max 上跑起一条完整的视差链路——ARKit 眼位驱动离轴投影，深度网格实时变形，头动画面动。

**Architecture:** 复用 Plan 1 建成的 `ParallaxCore`（70 个测试全绿）。新增两层：`ParallaxCore` 里补一个把相机空间眼位换算到屏幕空间的纯函数（可 TDD），以及一个新的 iOS App target 承载 Metal 渲染与 ARKit 接入。素材先用程序化生成的彩色图 + 深度图，不依赖相册与 HEIC 解析。

**Tech Stack:** Swift 6 / Metal / ARKit / SwiftUI / xcodegen

## Global Constraints

- `ParallaxCore` **只许 import `Foundation` 与 `simd`**。渲染与 ARKit 相关代码一律放 App target。
- **归一化深度：`[0,1]`，0 = 最远，1 = 最近。** 转换只在 `DepthNormalization` 一处发生。
- **屏幕坐标系**：原点＝显示区中心，X 右，Y 上，Z 指向用户，单位米。
- **严格 TDD**（Task 1、3）：先写会失败的测试，跑一次确认它失败，再写实现。
- **补写的测试必须证明自己能失败**：临时破坏被测行为，看它变红，再恢复，把失败输出写进报告。
- **数值断言的边界要实测，不要估算。**
- Task 结束必须提交，提交信息用中文。

## 已由真机实测确定的事实（本计划的输入，不要重新推导）

来源：`docs/api-facts-arkit-depth.md` §6.2，iPad Pro 11 M4 实测。

| 事实 | 值 | 对本计划的含义 |
|---|---|---|
| 眼位单位 | **米** | 量纲直接用，不需换算 |
| 相机空间 Z | **为负**（实测 −0.45） | 换算到屏幕空间**必须翻转 Z** |
| 左右眼命名 | **镜像**（`leftEyeTransform` 指用户右眼） | **本计划用双眼中点，中点不受命名影响**——但单眼渲染时必须换向 |
| 人脸追踪帧率 | **60fps**，帧间隔 16.7ms 极稳 | One Euro 参数按 60Hz 定 |
| 深度数据类型 | `fdep`（depth，米），未滤波 | 缺失像素是 NaN——本计划的程序化素材不涉及，但相册路径必须处理 |

**设备参数**（`docs/api-facts-arkit-depth.md` §6.3，Apple 官方工程图纸）：

- iPhone 14 Pro Max：显示区 **71.21 × 154.39 mm**；摄像头 x=**0**（图纸只给 20.76mm 包络，填 0 而非猜方向），y=显示区半高 − 6.4mm

---

### Task 1: 相机空间眼位 → 屏幕空间

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Tracking/EyePoseMapper.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/EyePoseMapperTests.swift`

**Interfaces:**
- Consumes: `ScreenGeometry`（Plan 1 Task 3）
- Produces: `enum EyePoseMapper` — `static func screenSpaceEye(cameraSpaceEye: SIMD3<Float>, screen: ScreenGeometry) -> SIMD3<Float>`

> **这是 spec §6 步骤 [3]，也是整条链路唯一一处「实测事实落地成代码」的地方。**
> 推导（已在 spec 里写死，别凭直觉改）：
> ```
> cameraOffset ≡ 摄像头在屏幕坐标系中的位置 = camera − center
> 要求的是                                    eye − center
> eye − center = (eye − camera) + (camera − center)
>              = flipZ(cameraSpaceEye) + cameraOffset
> ```
> Z 翻转的依据是真机实测：相机空间 Z 为负（用户在相机看向的 −Z 侧），而屏幕空间 Z 指向用户。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/EyePoseMapperTests.swift`：

```swift
import Testing
import simd
@testable import ParallaxCore

@Suite("EyePoseMapper")
struct EyePoseMapperTests {

    /// iPhone 14 Pro Max，摄像头在顶部、水平居中
    static let iPhone = ScreenGeometry(
        width: 0.07121,
        height: 0.15439,
        cameraOffset: SIMD3(0, 0.15439 / 2 - 0.0064, 0)
    )

    @Test("Z 必须翻转：相机空间的负 Z 变成屏幕空间的正 Z")
    func flipsZ() {
        // 真机实测相机空间眼位是 (−0.0126, −0.1024, −0.4526)，Z 为负。
        // 屏幕空间 Z 指向用户，所以观看距离必须是正的。
        let cameraSpace = SIMD3<Float>(0, 0, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(screenSpace.z > 0, "Z 未翻转，观看距离成了负数：\(screenSpace.z)")
        #expect(abs(screenSpace.z - 0.35) < 1e-6)
    }

    @Test("眼睛正对摄像头时，屏幕空间位置恰好等于摄像头偏移")
    func eyeAlignedWithCameraLandsOnCameraOffset() {
        // 这条钉死加号：眼睛与摄像头在 X/Y 上重合时，
        // 「眼相对屏幕中心」就等于「摄像头相对屏幕中心」。
        // 用减号会得到反号的结果，差 2 倍偏移量。
        let cameraSpace = SIMD3<Float>(0, 0, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x - Self.iPhone.cameraOffset.x) < 1e-6)
        #expect(abs(screenSpace.y - Self.iPhone.cameraOffset.y) < 1e-6,
                "Y 未落在摄像头偏移上：\(screenSpace.y) vs \(Self.iPhone.cameraOffset.y)")
    }

    @Test("眼睛在摄像头下方 cameraOffset.y 处时，正对屏幕中心")
    func eyeBelowCameraLandsOnScreenCenter() {
        // 摄像头在屏幕上方约 71mm，所以眼睛比摄像头低 71mm 时才正对屏幕中心。
        let offsetY = Self.iPhone.cameraOffset.y
        let cameraSpace = SIMD3<Float>(0, -offsetY, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x) < 1e-6)
        #expect(abs(screenSpace.y) < 1e-6, "未落在屏幕中心：\(screenSpace.y)")
    }

    @Test("X 与 Y 平移量原样传递")
    func translatesLaterally() {
        let cameraSpace = SIMD3<Float>(0.03, -0.02, -0.4)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x - (0.03 + Self.iPhone.cameraOffset.x)) < 1e-6)
        #expect(abs(screenSpace.y - (-0.02 + Self.iPhone.cameraOffset.y)) < 1e-6)
    }

    @Test("非有限输入不产生 NaN")
    func rejectsNonFinite() {
        let out = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: SIMD3(.nan, .infinity, -0.35), screen: Self.iPhone
        )
        #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter EyePoseMapper
```

预期：**编译失败**，`cannot find 'EyePoseMapper' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Tracking/EyePoseMapper.swift`：

```swift
import Foundation
import simd

/// 把 ARKit 相机空间的眼位换算到屏幕坐标系。
///
/// 这是 spec §6 步骤 [3]，整条链路唯一一处把真机实测事实落地成代码的地方。
///
/// 推导（这里改错过一次，别凭直觉动）：
/// ```
/// cameraOffset ≡ 摄像头在屏幕坐标系中的位置 = camera − center
/// 要求的是                                    eye − center
/// eye − center = (eye − camera) + (camera − center)
///              = flipZ(cameraSpaceEye) + cameraOffset
/// ```
///
/// Z 翻转的依据是真机实测（`docs/api-facts-arkit-depth.md` §6.2 探针 P12）：
/// 相机空间眼位 Z 为负（用户在相机看向的 −Z 侧），而屏幕坐标系 Z 指向用户。
public enum EyePoseMapper {

    public static func screenSpaceEye(
        cameraSpaceEye: SIMD3<Float>,
        screen: ScreenGeometry
    ) -> SIMD3<Float> {
        // 非有限输入直接归零，绝不让 NaN 流进投影矩阵——
        // 一个 NaN 能让整帧画面消失，且在设备上极难定位来源。
        let safe = SIMD3<Float>(
            cameraSpaceEye.x.isFinite ? cameraSpaceEye.x : 0,
            cameraSpaceEye.y.isFinite ? cameraSpaceEye.y : 0,
            cameraSpaceEye.z.isFinite ? cameraSpaceEye.z : 0
        )
        let flipped = SIMD3<Float>(safe.x, safe.y, -safe.z)
        return flipped + screen.cameraOffset
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter EyePoseMapper
```

预期：**5 个测试全 PASS**，全量应为 75。

- [ ] **Step 5: 证明加号那条测试真能抓住减号**

把实现里 `return flipped + screen.cameraOffset` 临时改成 `- screen.cameraOffset`，跑：

```bash
swift test --package-path ParallaxKit --filter EyePoseMapper
```

预期：`eyeAlignedWithCameraLandsOnCameraOffset` 与 `eyeBelowCameraLandsOnScreenCenter` **变红**。把失败输出抄进报告，然后改回。

- [ ] **Step 6: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 相机空间眼位换算到屏幕空间

spec §6 步骤[3] 的落地。Z 翻转依据真机实测 P12（相机空间 Z 为负），
加号依据向量推导（eye−center = (eye−camera) + (camera−center)）。
加号/减号之差是 2 倍偏移量，iPhone 上约 142mm——测试直接钉死这一点。"
```

---

### Task 2: 程序化测试素材

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/SyntheticScene.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/SyntheticSceneTests.swift`

**Interfaces:**
- Consumes: `DepthMap`（Plan 1 Task 6）
- Produces: `enum SyntheticScene` — `static func layeredBars(width: Int, height: Int) -> (color: [UInt8], depth: DepthMap)`，color 为 RGBA8 排列

> **为什么先用程序化素材而不是相册照片**：视差效果的正确性靠「不同深度的东西反向移动」来判断。程序化素材可以把深度做成已知的分层，一眼就能看出哪层该动多少。真实照片的深度图有噪声、有空洞，会把「渲染错了」和「深度图本身就烂」这两件事混在一起。
>
> 生成一组竖条纹，每条纹在深度上分层——头左右移动时，近处条纹相对远处条纹的位移一眼可辨。

- [ ] **Step 1: 写失败的测试**

`ParallaxKit/Tests/ParallaxCoreTests/SyntheticSceneTests.swift`：

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter SyntheticScene
```

预期：**编译失败**，`cannot find 'SyntheticScene' in scope`。

- [ ] **Step 3: 写实现**

`ParallaxKit/Sources/ParallaxCore/Depth/SyntheticScene.swift`：

```swift
import Foundation

/// 程序化生成的测试素材。
///
/// 为什么不直接用相册照片：视差是否正确，靠「不同深度的内容反向移动」来判断。
/// 程序化素材的深度是已知的分层，一眼能看出哪层该动多少；真实照片的深度图
/// 有噪声有空洞，会把「渲染错了」和「深度图本身就烂」混成一件事。
public enum SyntheticScene {

    /// 竖条纹，每条在深度上分层。
    ///
    /// 头左右移动时，近处条纹相对远处条纹的位移一眼可辨——这是最容易判读的视差检验图案。
    /// 颜色按深度做冷暖渐变，让层次在静止时也看得出来。
    public static func layeredBars(
        width: Int,
        height: Int,
        barCount: Int = 8
    ) -> (color: [UInt8], depth: DepthMap)? {
        guard width > 0, height > 0, barCount > 0 else { return nil }

        var color = [UInt8](repeating: 0, count: width * height * 4)
        var depth = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let bar = (x * barCount) / width
                // 深度在 [0.15, 0.95] 之间分层，避开两端极值——
                // 极值处网格位移最大，容易掩盖中间层的表现
                let t = Float(bar) / Float(max(barCount - 1, 1))
                let d = 0.15 + 0.80 * t
                depth[y * width + x] = d

                // 近处偏暖、远处偏冷，静止时也能看出层次
                let index = (y * width + x) * 4
                color[index + 0] = UInt8(40 + 200 * d)          // R
                color[index + 1] = UInt8(60 + 120 * (1 - d))    // G
                color[index + 2] = UInt8(90 + 160 * (1 - d))    // B
                color[index + 3] = 255                          // A
            }
        }

        guard let map = DepthMap(width: width, height: height, values: depth) else {
            return nil
        }
        return (color, map)
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
swift test --package-path ParallaxKit --filter SyntheticScene
```

预期：**5 个测试全 PASS**，全量应为 80。

- [ ] **Step 5: 提交**

```bash
git add ParallaxKit
git commit -m "feat(core): 程序化分层测试素材

竖条纹按深度分层，头动时近条相对远条的位移一眼可辨。
先用它而不是相册照片，是为了把「渲染错了」和「深度图本身烂」分开——
真实照片的深度有噪声有空洞，两件事混在一起就没法定位问题。"
```

---

### Task 3: App target 脚手架与 Metal 渲染器

**Files:**
- Create: `App/project.yml`
- Create: `App/Sources/ParallaxApp.swift`
- Create: `App/Sources/ParallaxRenderer.swift`
- Create: `App/Sources/Shaders.metal`
- Modify: `Makefile`（加 app 目标）

**Interfaces:**
- Consumes: `OffAxisProjection`、`ScreenGeometry`、`DepthMap`、`SyntheticScene`
- Produces: 可 `make app-build` 构建的 iOS App target；`final class ParallaxRenderer: NSObject, MTKViewDelegate`

> **渲染方案**（spec §8）：高密度网格，顶点 z 由深度图位移，乘离轴投影矩阵。本任务先做**单层**，不做两层 LDI 与背景外扩——那是效果打磨，不是链路验证。
>
> **本任务无 Mac 端单元测试**（TDD 例外，同 Plan 1 Task 10/11）：Metal 渲染的正确性无法用断言表达，把关点是 `make app-build` 通过 + 真机肉眼验证。

- [ ] **Step 1: 写 xcodegen 工程描述**

`App/project.yml`：

```yaml
name: Parallax
options:
  bundleIdPrefix: com.biily.parallax
  deploymentTarget: { iOS: "17.0" }
  createIntermediateGroups: true
targets:
  Parallax:
    type: application
    platform: iOS
    sources: [Sources]
    dependencies:
      - package: ParallaxKit
        product: ParallaxCore
    info:
      path: Info.plist
      properties:
        CFBundleDisplayName: 视差
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        NSCameraUsageDescription: >-
          The front camera tracks your eye position on device so photos can shift
          perspective as you move. Camera images are never saved or sent anywhere.
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1,2"
        # 同 Probe：ARSessionDelegate 未标 @MainActor、ARSession 非 Sendable，
        # 用 Swift 5 语言模式避开严格并发在渲染循环里制造的摩擦。
        # ParallaxCore 仍由 Package.swift 决定，跑在 Swift 6 严格模式下。
        SWIFT_VERSION: "5.0"
packages:
  ParallaxKit:
    path: ../ParallaxKit
```

⚠️ **提交时不要 `git add App`**——xcodegen 会在 `App/` 下生成 `Parallax.xcodeproj` 与 `Info.plist`。先在根 `.gitignore` 追加：

```
App/*.xcodeproj/
App/Info.plist
```

- [ ] **Step 2: 写 Metal 着色器**

`App/Sources/Shaders.metal`：

```metal
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 projection;   // 离轴投影矩阵，由 ParallaxCore 在 CPU 侧算好
    float parallaxScale;   // 归一化深度差 → 米，艺术参数
    float zeroParallax;    // 零视差面所在的归一化深度
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// 网格顶点按深度图位移：深度大（近）的顶点朝观察者凸出。
// 位移量 z = (d − zeroParallax) * parallaxScale，与 spec 术语表一致。
vertex VertexOut parallaxVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]],
                                texture2d<float> depthTex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = grid[vid];

    float d = depthTex.sample(s, uv).r;
    float z = (d - u.zeroParallax) * u.parallaxScale;

    // 网格铺满屏幕平面：uv[0,1] → 屏幕坐标 [-w/2, w/2] × [-h/2, h/2]
    // 屏幕物理尺寸已烘进投影矩阵，这里用归一化坐标乘以它。
    float2 xy = (uv - 0.5) * float2(1.0, -1.0);

    VertexOut out;
    out.position = u.projection * float4(xy, z, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 parallaxFragment(VertexOut in [[stage_in]],
                                 texture2d<float> colorTex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return colorTex.sample(s, in.uv);
}
```

- [ ] **Step 3: 写渲染器**

实现 `App/Sources/ParallaxRenderer.swift`，职责：
- 建立 Metal device / pipeline / 顶点缓冲（网格 128×128）
- 把 `SyntheticScene` 的 color 与 depth 上传成纹理（depth 用 `.r32Float`）
- 每帧从外部取当前屏幕空间眼位，调 `OffAxisProjection.matrix` 算投影矩阵，写进 uniforms
- `MTKViewDelegate.draw` 里编码 draw call

关键点：
- 网格顶点是 `[SIMD2<Float>]` 的 uv 坐标，三角形用索引缓冲组织
- **屏幕物理尺寸通过 `ScreenGeometry` 传给 `OffAxisProjection`**，着色器里的 xy 是归一化的，物理尺度由投影矩阵负责
- `parallaxScale` 初值 0.02（2cm），`zeroParallax` 初值 0.5

- [ ] **Step 4: 写 App 入口与 ARKit 接入**

实现 `App/Sources/ParallaxApp.swift`，职责：
- SwiftUI `App` + `MTKView` 包装
- `ARSession` + `ARFaceTrackingConfiguration`，delegate 里取 `faceAnchor.transform * leftEyeTransform` 与右眼，取中点
- 用 `camera.viewMatrix(for: .portrait)` 变换到相机空间
- 调 `EyePoseMapper.screenSpaceEye` 得屏幕空间眼位
- 过 `OneEuroFilter3`（60Hz 参数）与 `ParallaxBudget.clamp`
- 追踪不可用时用 `IdlePoseGenerator` 兜底（这是 spec §9.2② 要求的首屏行为）
- 屏幕参数取 `DeviceProfileRegistry.profile(for:)`，机型标识用 `uname`

- [ ] **Step 5: 加 Makefile 目标并构建**

`Makefile` 追加：

```makefile
app:
	xcodegen generate --project App --spec App/project.yml

app-build: app
	xcodebuild -project App/Parallax.xcodeproj -scheme Parallax \
	           -sdk iphonesimulator \
	           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	           -quiet build
```

跑 `make app-build`，确认退出码 0。

- [ ] **Step 6: 提交**

只 `git add .gitignore App/project.yml App/Sources Makefile`。

---

### Task 4: 真机验证（需用户参与）

- [ ] **Step 1: 装到 iPhone 14 Pro Max**

```bash
xcodebuild -project App/Parallax.xcodeproj -scheme Parallax \
  -destination 'platform=iOS,id=<白梨的 UDID>' \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=D4FVS6QJXV \
  -derivedDataPath /tmp/parallax-app build
xcrun devicectl device install app --device <UDID> <path>/Parallax.app
xcrun devicectl device process launch --device <UDID> --console com.biily.parallax.Parallax
```

- [ ] **Step 2: 用户肉眼验证清单**

这部分只能由人判断，逐条确认：

| 检查项 | 期望 |
|---|---|
| 首屏 | 未授权相机时画面就在缓慢摆动（idle 兜底生效） |
| 授权后左右移头 | 近处条纹与远处条纹**朝相反方向**移动 |
| 幅度 | 头移动 5cm，画面有明显但不夸张的位移 |
| 跟手感 | 无可察觉延迟，无橡皮筋感 |
| 静止时 | 画面稳定，无抖动 |
| 遮住摄像头 | 平滑过渡到 idle，无跳变 |

**如果近远条纹同向移动**，说明 Z 翻转或加减号错了——回到 Task 1 的测试。

---

## 完成标准

- [ ] `make test` 全绿（80 个测试）
- [ ] `make app-build` 退出码 0
- [ ] 真机上头动画面动，且近远景反向
- [ ] 用户确认观感达标

## 不在本计划范围

两层 LDI 与背景外扩、相册导入与 HEIC 深度解析、人像遮罩边缘处理、参数调节 UI、导出。这些都是在核心链路被验证之后才有意义的打磨。
