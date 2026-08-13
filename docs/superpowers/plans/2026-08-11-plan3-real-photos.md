# Plan 3：接入真实照片 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** 让 app 能打开你相册里的人像照片，用照片自带的深度图做视差——从「验证机制」变成「能玩自己的照片」。

**Architecture:** 可测的部分留在 `ParallaxCore`：深度像素解包（含 `bytesPerRow` padding 处理）是纯数据变换，可在 Mac 上完整 TDD。与 `AVDepthData` / `PHPicker` / `ImageIO` 打交道的部分放 App target，薄到不值得测。

**Tech Stack:** Swift 6 / PhotosUI / ImageIO / AVFoundation / Metal

## Global Constraints

- `ParallaxCore` **只许 import `Foundation` 与 `simd`**。AVFoundation / Photos / ImageIO 一律在 App target。
- **归一化深度：[0,1]，0 = 最远，1 = 最近。** 转换只在 `DepthNormalization` 一处发生。
- **严格 TDD**（Task 1）；补写的测试必须证明自己能失败。
- **数值断言的边界要实测，不要估算。**
- 提交信息用中文；提交时逐项 add，不要 `git add App`。

## 已核实的 SDK 事实（本计划的输入，见 `docs/api-facts-arkit-depth.md` §2）

| 事实 | 依据 |
|---|---|
| `PHPickerViewController` **不需要相册权限** | 官方示例代码明写 |
| `PHPickerFilter.depthEffectPhotosFilter`（iOS 16+）可只显示有景深的照片 | `PhotosUI/PHPicker.h:92` |
| PhotoKit **不直接返回 `AVDepthData`**，必须走 `CGImageSource` | 全 Photos.framework 无深度 API |
| 取 aux 数据：`CGImageSourceCopyAuxiliaryDataInfoAtIndex` + `kCGImageAuxiliaryDataTypeDisparity` / `...Depth` | `CGImageSource.h:236`、`CGImageProperties.h:815-816` |
| 结果字典直接喂 `AVDepthData.depthDataFromDictionaryRepresentation(_:error:)`（**类工厂不是 init**） | `AVDepthData.h:90,99` |
| HEIC 是多图容器，取主图**必须**用 `CGImageSourceGetPrimaryImageIndex` | `CGImageSource.h:226` |
| **未滤波深度图用 `NaN` 表示缺失像素** | `AVDepthData.h:209` |
| disparity 单位 1/米（近大远小），depth 单位米（近小远大） | `CVPixelBuffer.h:107-110` |
| 真机实测：iPad 前摄给的是 `fdep` 640×480，**未滤波** | §6.2 探针 P10 |
| `AVDepthData` 是 non-rectilinear 的，只能做渲染特效不能关联 3D 点 | `AVDepthData.h:71` |

---

### Task 1: 深度像素解包（Core，严格 TDD）

**Files:**
- Create: `ParallaxKit/Sources/ParallaxCore/Depth/DepthPixelUnpacking.swift`
- Test: `ParallaxKit/Tests/ParallaxCoreTests/DepthPixelUnpackingTests.swift`

**Interfaces:**
- Produces:
  - `enum DepthPixelFormat: Sendable` — `.float16` / `.float32`
  - `enum DepthPixelUnpacking` — `static func unpack(bytes: [UInt8], format: DepthPixelFormat, width: Int, height: Int, bytesPerRow: Int) -> [Float]?`

> **这一层存在的唯一理由是 `bytesPerRow`。**
> `CVPixelBuffer` 的每行字节数通常**大于** `width × 每像素字节数`——为了内存对齐会有 padding。
> 按 `width` 硬算偏移会逐行累积错位，画面表现为「深度图倾斜/撕裂」，但又不是全错，
> 是最难定位的那类 bug。把它隔离成纯数据变换，就能在 Mac 上用构造的 padding 数据测死。

- [ ] **Step 1: 写失败的测试**

```swift
import Testing
import Foundation
@testable import ParallaxCore

@Suite("DepthPixelUnpacking")
struct DepthPixelUnpackingTests {

    /// 把 Float32 数组按指定 bytesPerRow 打包成带 padding 的字节流
    private func packFloat32(_ rows: [[Float]], bytesPerRow: Int) -> [UInt8] {
        var out = [UInt8]()
        for row in rows {
            var rowBytes = [UInt8]()
            for v in row { withUnsafeBytes(of: v) { rowBytes.append(contentsOf: $0) } }
            rowBytes.append(contentsOf: [UInt8](repeating: 0xAB, count: bytesPerRow - rowBytes.count))
            out.append(contentsOf: rowBytes)
        }
        return out
    }

    @Test("无 padding 时逐值还原")
    func unpacksTightlyPacked() throws {
        let rows: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let bytes = packFloat32(rows, bytesPerRow: 12)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 3, height: 2, bytesPerRow: 12
        ))
        #expect(out == [1, 2, 3, 4, 5, 6])
    }

    @Test("有 padding 时必须跳过填充字节")
    func skipsRowPadding() throws {
        // 每行 3 个 Float32 = 12 字节，但 bytesPerRow 是 32（padding 20 字节）
        let rows: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let bytes = packFloat32(rows, bytesPerRow: 32)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 3, height: 2, bytesPerRow: 32
        ))
        #expect(out == [1, 2, 3, 4, 5, 6],
                "padding 未被跳过，读到了填充字节：\(out)")
    }

    @Test("Float16 正确转成 Float")
    func unpacksFloat16() throws {
        let values: [Float16] = [0.5, 1.0, 2.0, 4.0]
        var bytes = [UInt8]()
        for v in values { withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) } }
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float16, width: 4, height: 1, bytesPerRow: 8
        ))
        #expect(out == [0.5, 1.0, 2.0, 4.0])
    }

    @Test("NaN 原样保留——过滤是 DepthNormalization 的职责，不是这里的")
    func preservesNaN() throws {
        let rows: [[Float]] = [[Float.nan, 1.0]]
        let bytes = packFloat32(rows, bytesPerRow: 8)
        let out = try #require(DepthPixelUnpacking.unpack(
            bytes: bytes, format: .float32, width: 2, height: 1, bytesPerRow: 8
        ))
        #expect(out[0].isNaN, "NaN 被提前吞掉了，DepthNormalization 就看不到缺失像素")
        #expect(out[1] == 1.0)
    }

    @Test("字节数不足时返回 nil 而不是崩溃")
    func rejectsTruncatedInput() {
        #expect(DepthPixelUnpacking.unpack(
            bytes: [0, 0, 0, 0], format: .float32, width: 3, height: 2, bytesPerRow: 12
        ) == nil)
    }

    @Test("非法尺寸返回 nil")
    func rejectsInvalidGeometry() {
        #expect(DepthPixelUnpacking.unpack(
            bytes: [UInt8](repeating: 0, count: 64), format: .float32,
            width: 0, height: 2, bytesPerRow: 12) == nil)
        // bytesPerRow 小于一行实际所需
        #expect(DepthPixelUnpacking.unpack(
            bytes: [UInt8](repeating: 0, count: 64), format: .float32,
            width: 4, height: 2, bytesPerRow: 8) == nil)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
swift test --package-path ParallaxKit --filter DepthPixelUnpacking
```

预期：编译失败，`cannot find 'DepthPixelUnpacking' in scope`。

- [ ] **Step 3: 写实现**

要点：
- `float16` 每像素 2 字节，`float32` 每像素 4 字节
- 逐行按 `bytesPerRow` 步进，每行只取前 `width × bytesPerPixel` 字节
- 校验 `bytes.count >= height × bytesPerRow`，不足返回 nil
- 校验 `bytesPerRow >= width × bytesPerPixel`，否则返回 nil
- **NaN 原样透传**，不要在这里过滤——那是 `DepthNormalization` 的职责，提前吞掉会让缺失像素信息丢失
- 用 `withUnsafeBytes` + `loadUnaligned(fromByteOffset:as:)` 读取（`bytesPerRow` 的 padding 可能导致非对齐访问）

- [ ] **Step 4: 跑测试确认通过**，全量应为 97 + 6

- [ ] **Step 5: 证明 padding 测试真能抓住 bug**

把实现里的行步进临时改成 `width * bytesPerPixel`（即忽略 `bytesPerRow`），跑测试确认 `skipsRowPadding` 变红。抄失败输出进报告，改回。

- [ ] **Step 6: 提交**

---

### Task 2: 照片深度加载（App 层）

**Files:**
- Create: `App/Sources/DepthPhotoLoader.swift`
- Modify: `App/Sources/ParallaxApp.swift`（加选照片入口）

**Interfaces:**
- Consumes: `DepthPixelUnpacking`、`DepthNormalization`、`DepthMap`
- Produces: `enum DepthPhotoLoader` — `static func load(from data: Data) -> (color: CGImage, depth: DepthMap)?`

> **本任务无 Mac 端单元测试**（TDD 例外，同探针与渲染器）：它的被测对象是真实 HEIC 文件的解析，构造合成 HEIC 比测它本身还复杂。把关点是 `make app-build` 通过 + 真机能打开你相册里的照片。

实现要点（**API 名以 `docs/api-facts-arkit-depth.md` §2 为准，不要凭记忆写**）：

1. `CGImageSourceCreateWithData` → **`CGImageSourceGetPrimaryImageIndex`**（HEIC 多图容器，别硬写 0）
2. `CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, primaryIndex, kCGImageAuxiliaryDataTypeDisparity)`；为 nil 再试 `kCGImageAuxiliaryDataTypeDepth`
3. 结果字典 → **`AVDepthData.depthDataFromDictionaryRepresentation(_:error:)`**（类工厂）
4. 按 `depthData.depthDataType` 判断是 disparity 还是 depth，对应 `DepthSourceKind` 的 `.disparity` / `.depth`
   - 四字符码：`hdis`/`fdis` = disparity，`hdep`/`fdep` = depth
5. `depthDataMap` 是 `CVPixelBuffer`：`CVPixelBufferLockBaseAddress` → `CVPixelBufferGetBaseAddress` / `GetBytesPerRow` / `GetWidth` / `GetHeight` → 拷成 `[UInt8]` → **`DepthPixelUnpacking.unpack`** → **`DepthNormalization.normalize`**
   - **务必配对 `CVPixelBufferUnlockBaseAddress`**，用 `defer`
6. 彩色图：`CGImageSourceCreateImageAtIndex(src, primaryIndex, nil)`
7. **方向**：`AVDepthData.depthDataByApplyingExifOrientation(_:)` 与彩色图的方向必须一致，否则深度和颜色对不上。EXIF 方向从 `CGImageSourceCopyPropertiesAtIndex` 取
8. 任何一步失败都返回 nil，**不要崩溃**

App 层入口：
- 工具栏加一个「选照片」按钮，弹 `PHPickerViewController`
- `PHPickerConfiguration` 设 `filter = .depthEffectPhotos`（iOS 16+），这样列表里只出现有景深的照片，从源头减少挫败
- 选中后取 `itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier)` 拿 `Data`
- 成功 → 交给渲染器换纹理；失败 → 屏幕上给一句可行动的提示（**不是「加载失败」，而是说明这张照片没有深度信息、建议选人像模式拍的**）

---

### Task 3: 渲染器接受动态素材

**Files:**
- Modify: `App/Sources/ParallaxRenderer.swift`

要点：
- 现在纹理是启动时用 `SyntheticScene` 建的一次性资源，改成可替换
- 彩色纹理从 `CGImage` 上传（注意 `CGImage` 的 bytesPerRow 同样可能有 padding，用 `CGContext` 重绘到紧凑缓冲最省事）
- 深度纹理仍是 `.r32Float`
- 换图时视差强度可能要重算：程序化条纹的深度是满量程分层，真实照片的深度分布集中得多。**先保持 `parallaxScale` 不变，真机看了再调**——这是需要你肉眼定的参数
- 保留程序化素材作为启动默认，这样首屏行为不变

---

### Task 4: 真机验证（需用户参与）

装到 iPhone 14 Pro Max 后逐条确认：

| 检查项 | 期望 |
|---|---|
| 点「选照片」 | 只列出有景深的照片（人像模式拍的） |
| 选一张人像照 | 照片显示出来，头动时人物与背景**反向移动** |
| 边缘 | 人物边缘会有拉伸——**这是预期的**，两层 LDI 是下一步的事 |
| 视差强度 | 是否需要调 `parallaxScale`（真实照片的深度分布比条纹图集中得多） |
| 选一张普通照片（若能选到） | 给出可行动的提示，不崩溃 |

## 完成标准

- [ ] `swift test --package-path ParallaxKit` 全绿（103）
- [ ] `make app-build` 退出码 0
- [ ] 真机上能打开相册人像照片并看到视差
- [ ] 用户确认观感

## 不在本计划范围

两层 LDI 与背景外扩、人像遮罩边缘处理、app 内拍照、作品库、导出、参数调节 UI。
