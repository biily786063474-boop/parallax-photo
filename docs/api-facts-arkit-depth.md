# ARKit 与深度 API 事实汇编

> **本文性质**：全部结论来自本机 SDK 头文件的实际内容核实，**不是记忆、不是网络二手资料**。
> 实现时以本文为准；本文没写的、或标注「需真机验证」的，不许凭印象假设。
>
> **核实环境**：Xcode 26.6（Build 17F113）／Swift 6.3.3／iOS SDK 26.5
> `$SDK` = `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk`
> `$AR` = `$SDK/System/Library/Frameworks/ARKit.framework/Headers`
> `$AV` = `$SDK/System/Library/Frameworks/AVFoundation.framework/Headers`
>
> 核实日期：2026-08-10

---

## 一、ARKit 人脸追踪

### 1.1 ARFaceTrackingConfiguration

| 事实 | 内容 | 依据 |
|---|---|---|
| 类名 | `ARFaceTrackingConfiguration : ARConfiguration` | `$AR/ARConfiguration.h:366` |
| 可用性 | `API_AVAILABLE(ios(11.0))` | `$AR/ARConfiguration.h:365` |
| 支持判定 | `isSupported` **不在本类声明**，继承自基类 `ARConfiguration` 的类属性 `@property (class, nonatomic, readonly) BOOL isSupported;` | `$AR/ARConfiguration.h:127` |
| 同时追踪脸数 | `maximumNumberOfTrackedFaces`（可写，**默认 1**）／`supportedNumberOfTrackedFaces`（类属性，只读，iOS 13+） | `$AR/ARConfiguration.h:373-379`、`:368-371` |
| 世界追踪开关 | `worldTrackingEnabled`（getter `isWorldTrackingEnabled`，iOS 13+，**默认关闭**）；开启后**改用后置摄像头**追踪设备位姿，此时 camera transform 与 ARFaceAnchor transform 都在世界坐标空间 | `$AR/ARConfiguration.h:386-392` |
| 能力查询 | `supportsWorldTracking`（类属性，iOS 13+） | `$AR/ARConfiguration.h:381-384` |

**本项目决策**：不开启 `worldTrackingEnabled`，保持默认。我们不需要后置摄像头，开启只会增加功耗与发热。

### 1.2 ARFaceAnchor —— 眼位来自哪里

| 事实 | 内容 | 依据 |
|---|---|---|
| 类声明 | `ARFaceAnchor : ARAnchor <ARTrackable>`，`NS_SWIFT_SENDABLE` | `$AR/ARFaceAnchor.h:81-83` |
| 左眼 | `@property (readonly) simd_float4x4 leftEyeTransform;`（iOS 12+） | `$AR/ARFaceAnchor.h:93` |
| 右眼 | `@property (readonly) simd_float4x4 rightEyeTransform;`（iOS 12+） | `$AR/ARFaceAnchor.h:98` |
| **⚠️ 坐标系** | 头文件原文：「The left eye's rotation and translation **relative to the anchor's origin**.」→ **face anchor 局部空间，不是世界空间** | `$AR/ARFaceAnchor.h:90-91`、`:95-96` |
| 注视点 | `@property (readonly) simd_float3 lookAtPoint;`（iOS 12+），同样相对 anchor 原点 | `$AR/ARFaceAnchor.h:100-103` |
| anchor 自身 | 继承 `ARAnchor.transform`，注释明写 **in world coordinates** | `$AR/ARAnchor.h:72-75` |
| 有效性 | 走 `ARTrackable.isTracked`；注释明写它用于判定 transform 的 **validity** | `$AR/ARAnchor.h:34-44` |
| 不可自造 | `initWithTransform:` / `initWithName:transform:` 均 `NS_UNAVAILABLE` | `$AR/ARFaceAnchor.h:111-113` |

**因此，取世界坐标眼位的唯一正确写法：**

```
worldEye = faceAnchor.transform * faceAnchor.leftEyeTransform
```

**⚠️ 镜像陷阱**：头文件对 **blendShapes** 明确说明了镜像语义（「if the detected person has a closed right eye, the eye on the left side of the captured image will appear closed」，`$AR/ARFaceAnchor.h:14-21`），但**对 `leftEyeTransform` / `rightEyeTransform` 没有任何镜像说明**。左右眼是否镜像 → 见 §6 真机探针 P5。

**⚠️ 禁用私有符号**：`ARKit.tbd` 中存在 `_ARLeftEyePupil`、`_ARRightEyePupil`、`_ARLeftEyeInnerCorner`、`_ARRightEyeOuterCorner` 等眼部关键点符号，但**公开头文件中一个都没有声明**。这些是私有 API，使用会导致拒审。本项目只用 `leftEyeTransform`、`rightEyeTransform`、`lookAtPoint` 三个公开属性。

### 1.3 世界原点位置：SDK 无定义 —— 必须绕开

**穷举检索结论**：整个 ARKit 头文件目录中，唯一提及 "world origin" 的位置是 `-[ARSession setWorldOrigin:]`（`$AR/ARSession.h:122-128`），**没有任何一处说明 session 启动时原点落在哪里**。「原点在设备初始位姿」是在线文档的说法，不在 SDK 契约中。

**有契约的替代路径**：`ARCamera` 提供了明确注释的变换方法。

| 方法 | 注释关键句 | 依据 |
|---|---|---|
| `- (simd_float4x4)viewMatrixForOrientation:(UIInterfaceOrientation)orientation;`<br>**Swift 实测为 `viewMatrix(for:)`** | 「transform geometry **from world space into camera space** for a given orientation」 | `$AR/ARCamera.h:130-136`；Swift 名由 Task 11 编译实测确认 |
| `- (simd_float4x4)projectionMatrixForOrientation:viewportSize:zNear:zFar:` | — | `$AR/ARCamera.h:90-103` |
| `- (CGPoint)projectPoint:orientation:viewportSize:` | 返回视口坐标，**原点在左上角** | `$AR/ARCamera.h:105-113` |
| `intrinsics` (`simd_float3x3`) | `fx/fy` 像素焦距，`px/py` 主点，**原点在左上角像素中心** | `$AR/ARCamera.h:54-64` |
| `transform` | 「camera's rotation and translation **in world coordinates**」 | `$AR/ARCamera.h:25-28` |
| `eulerAngles` | x=Pitch, y=Yaw, z=Roll（弧度）；施加顺序 roll → pitch → yaw | `$AR/ARCamera.h:30-42` |

**本项目决策**：眼位换算**只走 `viewMatrixForOrientation:`**，得到相机空间坐标，再加一个「摄像头 → 屏幕中心」的设备物理偏移得到屏幕空间。**永不假设世界原点位置。**

世界坐标轴向的唯一 SDK 明文（供参考，本项目不依赖）：`ARWorldAlignmentGravity` 定义重力方向为 `(0, -1, 0)`；`ARWorldAlignmentGravityAndHeading` 额外定义真北为 `(0, 0, -1)`。默认值为 `ARWorldAlignmentGravity`。依据：`$AR/ARConfiguration.h:71-85`、`:140-144`。

### 1.4 单位：米（推定成立，需实测确认）

`$AR/ARFaceAnchor.h` 全文**不含 "meter" 字样**，`ARAnchor.h` / `ARCamera.h` / `ARFaceGeometry.h` 同样没有。

框架级米制约定的直接证据（其他头文件）：`ARHitTestResult.h:53`「distance from the camera to the intersection **in meters**」、`ARDepthData.h:30`「per-pixel depth data (**in meters**)」、`ARWorldMap.h:27/:32`、`ARReferenceImage.h:31`、`ARBodyAnchor.h:27`（骨架默认身高 1.71 meters）。

由于 `ARFaceAnchor.transform` 与上述类型共享同一世界坐标空间（`ARAnchor.h:73`），米制**推定成立**。但严格说眼位单位在头文件中无直接书面依据 → 见 §6 真机探针 P9（量瞳距验证，成人约 0.050–0.075 m）。

### 1.5 视频格式与帧率

| 事实 | 内容 | 依据 |
|---|---|---|
| 类型 | `ARVideoFormat`，Swift 名 `ARConfiguration.VideoFormat`（iOS 11.3+） | `$AR/ARVideoFormat.h:17-19` |
| 帧率查询 | `@property (readonly) NSInteger framesPerSecond;` | `$AR/ARVideoFormat.h:38-41` |
| 支持列表 | `ARConfiguration.supportedVideoFormats`（类属性），注释：「**The first element in the list is the default format**」 | `$AR/ARConfiguration.h:129-133` |
| 设置 | `ARConfiguration.videoFormat` | `$AR/ARConfiguration.h:135-138` |
| iOS 26 新增 | `defaultColorSpace`、`defaultPhotoSettings` | `$AR/ARVideoFormat.h:56`、`:65` |

**⚠️ 头文件中不存在任何帧率数值常量或上限声明。**「人脸追踪 60fps」无 SDK 依据 → 见 §6 真机探针 P1。

### 1.6 无 View 运行：API 层面无阻碍

1. `ARSession : NSObject`，接口只有 `delegate` / `delegateQueue` / `currentFrame` / `configuration` / `runWithConfiguration:options:` / `pause`，**没有任何 view、layer、renderer 属性**。依据：`$AR/ARSession.h:51-107`。
2. 框架在头文件层面就分离了 UI：`ARSession.h` / `ARConfiguration.h` / `ARFaceAnchor.h` / `ARFrame.h` / `ARCamera.h` 归入 `ARKitCore.h`；`ARSCNView.h` / `ARSKView.h` / `ARCoachingOverlayView.h` 归入 `ARKitUI.h`。依据：`$AR/ARKit.h:15-25`、`$AR/ARKitCore.h:15-54`、`$AR/ARKitUI.h:10-17`。
3. `ARSCNView` 的 `session` 是 strong 可写属性 —— **view 持有 session，反向无依赖**。依据：`$AR/ARSCNView.h:24-35`。
4. `ARFrame.capturedImage` 是 `CVPixelBufferRef`，可直接进自建 Metal 管线。依据：`$AR/ARFrame.h:80-83`。
5. **仍需相机权限**：`ARErrorCodeCameraUnauthorized = 103`。依据：`$AR/ARError.h:27-28`。

### 1.7 ARSessionDelegate 线程与频率

| 事实 | 内容 | 依据 |
|---|---|---|
| 逐帧回调 | `- (void)session:(ARSession *)session didUpdateFrame:(ARFrame *)frame;` | `$AR/ARSession.h:337-343` |
| **线程（明文）** | `delegateQueue` 注释：「If not provided or nil, delegate calls will be performed on the **main queue**.」 | `$AR/ARSession.h:66-70` |
| 拉模式 | `ARSession.currentFrame`（`nonatomic, copy, readonly`），可在渲染循环主动拉取 | `$AR/ARSession.h:72-75` |
| Sendable | `ARFrame` / `ARCamera` / `ARFaceAnchor` / `ARFaceGeometry` 都标了 `NS_SWIFT_SENDABLE`；**`ARSession` 没有** → 帧数据可跨线程传递，session 操作不可 | `$AR/ARFrame.h:72`、`$AR/ARCamera.h:22`、`$AR/ARFaceAnchor.h:82` vs `$AR/ARSession.h:51-52` |
| 中断 | `sessionWasInterrupted:` 注释：「when video capture is interrupted... （see `AVCaptureSessionInterruptionReason`）」「**No additional frame updates will be delivered until the interruption has ended**」 | `$AR/ARSession.h:263-273` |
| 失败 | `session:didFailWithError:`；错误码 `ARErrorCodeUnsupportedConfiguration=100`、`SensorUnavailable=101`、`SensorFailed=102`、`CameraUnauthorized=103` | `$AR/ARSession.h:253`、`$AR/ARError.h:17-28` |

**⚠️ 头文件不含任何回调频率承诺** → 见 §6 真机探针 P3。
**⚠️ 头文件中没有任何「不要长期持有 ARFrame」的注释**（grep `hold|retain|release|memory` 在 `ARFrame.h`/`ARSession.h` 零命中）。该说法来自在线文档，本项目仍按「用完即弃」实现——这同时是合规要求（见 `appstore-compliance.md`）。

### 1.8 iOS 26 在 ARKit 中的全部新增（共 3 处）

`grep -rn "ios(26" $AR/` 全目录仅三条命中：

- `ARVideoFormat.defaultColorSpace` — `$AR/ARVideoFormat.h:56`
- `ARVideoFormat.defaultPhotoSettings` — `$AR/ARVideoFormat.h:65`
- `-[ARSession captureHighResolutionFrameUsingPhotoSettings:completion:]` — `$AR/ARSession.h:233-235`

补充：全目录 `API_AVAILABLE(ios(x))` 版本号最高的几档是 `14.5` → `16.0` → `26.0`，**iOS 17／18 期间 ARKit 公开头文件没有任何新增**。

### 1.9 不存在的东西（明确的负面结论）

- **整个 iOS 26.5 SDK 中不存在任何公开的 gaze / eye-tracking API。** `grep -rn "eyeTracking\|EyeTracking"` 全 Frameworks headers **零命中**；`gaze` 的命中全部是 NaturalLanguage 的 "Gazetteer"（词表，与视线无关）与 UIScrollView 中一条 visionOS 注释。
- ARKit 路径**不提供** `portraitEffectsMatte`（`ARMatteGenerator.h` 是给 people occlusion 用的，不是人像抠图 matte）。

---

## 二、深度数据

### 2.1 AVDepthData

依据：`$AV/AVDepthData.h`

| 成员 | 准确 ObjC 签名 | 行号 |
|---|---|---|
| 从字典构造 | `+ (nullable instancetype)depthDataFromDictionaryRepresentation:(NSDictionary *)imageSourceAuxDataInfoDictionary error:(NSError **)outError;` — **类工厂，不是 init** | :99 |
| 类型转换 | `- (instancetype)depthDataByConvertingToDepthDataType:(OSType)depthDataType;` | :114 |
| 方向校正 | `- (instancetype)depthDataByApplyingExifOrientation:(CGImagePropertyOrientation)exifOrientation;` | :129 |
| 像素数据 | `@property(readonly) CVPixelBufferRef depthDataMap NS_RETURNS_INNER_POINTER;` | :191 |
| 数据类型 | `@property(readonly) OSType depthDataType;` | :181 |
| 质量 | `@property(readonly) AVDepthDataQuality depthDataQuality;`（`Low` / `High`） | :201、:32-33 |
| 精度 | `@property(readonly) AVDepthDataAccuracy depthDataAccuracy;`（`Relative` / `Absolute`） | :221、:50-51 |
| 是否已滤波 | `@property(readonly, getter=isDepthDataFiltered) BOOL depthDataFiltered;` | :211 |
| 可用类型 | `@property(readonly) NSArray<NSNumber *> *availableDepthDataTypes NS_REFINED_FOR_SWIFT;` | :156 |
| 标定数据 | `@property(nullable, readonly) AVCameraCalibrationData *cameraCalibrationData;` | :231 |
| 直接 init | `AV_INIT_UNAVAILABLE` — **不能直接 init** | :82 |

**⚠️ 传入 `availableDepthDataTypes` 之外的类型给 `depthDataByConvertingToDepthDataType:` 会抛 `NSInvalidArgumentException`**（:112）。

**⚠️ 用 `depthDataByReplacingDepthDataMapWithPixelBuffer:error:` 生成的新对象，`cameraCalibrationData` 永远返回 nil**（:144-146）。

### 2.2 ⚠️ 本项目最重要的一条限制

`$AV/AVDepthData.h:71` 原文：深度／视差图是 **non-rectilinear（未做镜头畸变校正）**的，其数值被 warp 成与配套 YUV 图相同的镜头畸变特性。因此：

> AVDepthData **可以作为深度代理，用于对配套图像做渲染特效；但不能用来关联 3D 空间中的点**。

**对本项目的含义**：我们做的是**艺术化的视差渲染**，不是物理精确的三维重建。观察者一侧（眼位 → 离轴投影）物理正确；被观察的照片一侧是近似。

**因此 spec 中不得承诺「几何精确」，验收标准中不得出现无法验证的 3D 精度指标。** 若将来要做真 3D，必须先用 `cameraCalibrationData` 做 rectify。

### 2.3 视差与深度的定义

依据：`$SDK/System/Library/Frameworks/CoreVideo.framework/Headers/CVPixelBuffer.h:107-110`，`$AV/AVDepthData.h:68-69`

```
kCVPixelFormatType_DisparityFloat16 = 'hdis'
kCVPixelFormatType_DisparityFloat32 = 'fdis'
kCVPixelFormatType_DepthFloat16     = 'hdep'
kCVPixelFormatType_DepthFloat32     = 'fdep'
```

- **disparity**：「normalized shift when comparing two images. Units are **1/meters**: `( pixelShift / (pixelFocalLength * baselineInMeters) )`」
- **depth**：「the depth (distance to an object) **in meters**」

**⚠️ 未滤波的 depth map 用 `NaN` 表示缺失像素**（`$AV/AVDepthData.h:209`）。滤波（hole-fill）后可用性更好，但「不再适合 CV 任务」。→ 本项目必须在数据进入 GPU 前处理 NaN。

### 2.4 从 HEIC 读取内嵌深度

`$SDK/System/Library/Frameworks/ImageIO.framework/Headers/CGImageSource.h:236`：

```
CFDictionaryRef CGImageSourceCopyAuxiliaryDataInfoAtIndex(
    CGImageSourceRef isrc, size_t index, CFStringRef auxiliaryImageDataType);
```

返回 nil 表示该图不含此类 aux 数据（:234）。

辅助数据类型常量（`ImageIO/CGImageProperties.h`）：

| 常量 | 行号 | 可用性 |
|---|---|---|
| `kCGImageAuxiliaryDataTypeDepth` | :815 | iOS 11.0 |
| `kCGImageAuxiliaryDataTypeDisparity` | :816 | iOS 11.0 |
| `kCGImageAuxiliaryDataTypePortraitEffectsMatte` | :817 | iOS 12.0 |
| `kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte` | :819 | iOS 13.0 |
| `kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte` | :820 | iOS 13.0 |
| `kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte` | :821 | iOS 13.0 |
| `kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte` | :822 | iOS 14.1 |
| `kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte` | :823 | iOS 14.1 |
| `kCGImageAuxiliaryDataTypeHDRGainMap` | :824 | iOS 14.1 |

返回字典的 key：`kCGImageAuxiliaryDataInfoData`（CFData）、`kCGImageAuxiliaryDataInfoDataDescription`（CFDictionary）、`kCGImageAuxiliaryDataInfoMetadata`、`kCGImageAuxiliaryDataInfoColorSpace`（iOS 18+）。依据：`CGImageSource.h:229-233`、`CGImageProperties.h:835-838`。

**完整链路（头文件明确背书）**：
`CGImageSourceCopyAuxiliaryDataInfoAtIndex` → 结果字典 → `+[AVDepthData depthDataFromDictionaryRepresentation:error:]`（`$AV/AVDepthData.h:90`、`:97` 明写这条路径）。人像遮罩同理走 `+[AVPortraitEffectsMatte portraitEffectsMatteFromDictionaryRepresentation:error:]`（`$AV/AVPortraitEffectsMatte.h:51`）。

**⚠️ HEIC 是多图容器，取主图索引必须用 `CGImageSourceGetPrimaryImageIndex(isrc)`（`CGImageSource.h:226`，iOS 12+），不要硬写 0。**

### 2.5 PhotoKit：不直接提供深度

**穷举检索结论**：`Photos.framework` + `PhotosUI.framework` 全部头文件中，除下列三个「DepthEffect」标记外，**没有任何深度数据 API**。PhotoKit **不返回 `AVDepthData`**，只告诉你「这张是人像照」。

| 常量 | 依据 | 可用性 |
|---|---|---|
| `PHAssetMediaSubtypePhotoDepthEffect = (1UL << 4)` → Swift `PHAssetMediaSubtype.photoDepthEffect` | `PhotosTypes.h:148` | iOS 10.2+ |
| `PHAssetCollectionSubtypeSmartAlbumDepthEffect = 212`（系统「人像」智能相册） | `PhotosTypes.h:99` | — |
| `PHPickerFilter.depthEffectPhotosFilter` | `PhotosUI/PHPicker.h:92` | iOS 16+ |

**⚠️ `photoDepthEffect` 只是「有景深效果」的 flag，不等价于「一定能解出可用深度图」** —— 最终仍需用 ImageIO 打开原始数据实测。

**取原始字节的路径（按推荐度）**：

1. `-[PHImageManager requestImageDataAndOrientationForAsset:options:resultHandler:]`（`PHImageManager.h:175`，iOS 13+）→ `NSData` → `CGImageSourceCreateWithData` → §2.4 流程。
   注意 `PHImageRequestOptions.version`：`Current` 在有编辑时返回**渲染后**的图（:161），要原始深度考虑 `Original`（:31）。
   旧的 `requestImageDataForAsset:options:resultHandler:` 已 **deprecated（iOS 13）**。
2. `PHAssetResourceManager.requestDataForAssetResource:options:dataReceivedHandler:completionHandler:`（`PHAssetResourceManager.h:39`）+ `+[PHAssetResource assetResourcesForAsset:]`，挑 `PHAssetResourceTypePhoto`(=1) 或 `FullSizePhoto`(=5)。拿到**未经转码的原始文件字节**，对保留内嵌 aux 数据最保险。
3. `PHContentEditingInput.fullSizeImageURL`（`PHContentEditingInput.h:42`）→ `CGImageSourceCreateWithURL`。

**⚠️ iCloud**：`isNetworkAccessAllowed` **默认 NO**，不设它则 iCloud 优化存储的照片会走 `PHImageResultIsInCloudKey` 失败分支（`PHImageManager.h:123`）。存在于 `PHImageRequestOptions`(:58)、`PHVideoRequestOptions`(:74)、`PHContentEditingInputRequestOptions`(:103)、`PHAssetResourceRequestOptions`(`PHAssetResourceManager.h:26`)。

### 2.6 人像遮罩（边缘质量的关键）

`$AV/AVPortraitEffectsMatte.h`：

| 成员 | 签名 | 行号 |
|---|---|---|
| 类 | `@interface AVPortraitEffectsMatte : NSObject` | :28 |
| 从字典构造 | `+ (nullable instancetype)portraitEffectsMatteFromDictionaryRepresentation:(NSDictionary *)... error:(NSError **)outError;` | :51 |
| 方向校正 | `- (instancetype)portraitEffectsMatteByApplyingExifOrientation:(CGImagePropertyOrientation)exifOrientation;` | :66 |
| **像素数据** | `@property(readonly) CVPixelBufferRef mattingImage NS_RETURNS_INNER_POINTER;` — **叫 `mattingImage`，不是 `matteImage`** | :118 |

`AVSemanticSegmentationMatte`（`$AV/AVSemanticSegmentationMatte.h`）类型常量**只有四个**：`Skin`(:29)、`Hair`(:35)、`Teeth`(:41)、`Glasses`(:47，iOS 14.1)。

**⚠️ 不对称**：ImageIO 侧有 `kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte`，但 **AVFoundation 侧没有对应的 Sky 常量**。

**本项目用途**：人像照片内嵌的 `portraitEffectsMatte` 是系统生成的高质量前景 alpha，用作深度突变处的**权威边界**，优于纯深度梯度检测。`hairMatte` 可额外救发丝边缘。**注意：这是相册人像照独有的，ARKit 现拍路径没有。**

### 2.7 拍摄带深度的照片（AVCapture 路径，本项目不用，备查）

`$AV/AVCapturePhotoOutput.h`：`isDepthDataDeliverySupported`(:920)、`isDepthDataDeliveryEnabled`(:930)、`AVCapturePhotoSettings.isDepthDataDeliveryEnabled`(:1468)、`AVCapturePhoto.depthData`(:2045)。

三条会咬人的规则：
1. :928 —「Enabling depth data delivery requires a **lengthy reconfiguration** of the capture render pipeline, so you should set this property to YES **before** calling `-[AVCaptureSession startRunning]`」
2. :918 — 切换摄像头/format 时 `depthDataDeliverySupported` 会变；从 YES 变 NO 时 `depthDataDeliveryEnabled` **自动回退成 NO**，改配置后必须重新置 YES。
3. :1464 — settings 侧开启但 output 侧未开启，或未实现 `captureOutput:didFinishProcessingPhoto:error:` → **抛异常**。
4. :948 —「Portrait effects matte generation **requires depth to be present**」，开 matte 必须同时开 depth。

设备类型常量（`$AV/AVCaptureDevice.h`）：`AVCaptureDeviceTypeBuiltInTrueDepthCamera`(:568, iOS 11.1)、`BuiltInLiDARDepthCamera`(:574, iOS 15.4)、`BuiltInDualCamera`(:527, iOS 10.2)、`BuiltInDualWideCamera`(:545)、`BuiltInTripleCamera`(:562)。

**⚠️ TrueDepth / LiDAR / DualCamera 只能通过 `AVCaptureDeviceDiscoverySession` 或 `+[AVCaptureDevice defaultDeviceWithDeviceType:mediaType:position:]` 发现，`AVCaptureDevice.default(for: .video)` 拿不到。**

### 2.8 ★ 关键架构结论：ARKit 与 AVCaptureSession 不能共用摄像头

**核实过程**：`grep -rn "ARKit\|ARSession" $AV/` **零命中**；`grep -rn "AVCapture" $AR/` 仅 7 处，全是单向类型引用，**无一处讨论并发共享**。→ 头文件中**没有正面证据也没有反面证据**。

**但间接证据非常强，全部指向「不能」：**

1. `ARConfiguration.configurableCaptureDeviceForPrimaryCamera`（`$AR/ARConfiguration.h:184`，iOS 16+）注释：「**May return nil if it is not recommended to modify capture settings, for example if the primary camera is used for tracking.**」→ ARKit 独占管理该设备，只在安全时借出句柄供调参。
2. `ARSessionObserver.sessionWasInterrupted:` 注释直接引用 `AVCaptureSessionInterruptionReason`（`$AR/ARSession.h:266-269`）→ ARKit 内部就跑在 AVCaptureSession 之上。
3. `AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient = 3`（`$AV/AVCaptureSession.h:78`）注释：「when **stolen away by another AVCaptureSession**」→ iOS 摄像头独占语义的直接书面证据。
4. Apple 把「同时用两路相机」做成了 ARKit **内部配置项**（`ARFaceTrackingConfiguration.worldTrackingEnabled` / `ARWorldTrackingConfiguration.userFaceTrackingEnabled`），而不是让开发者并排开 AVCaptureSession —— 这是设计意图的强信号。
5. `AVCaptureMultiCamSession`（`$AV/AVCaptureSession.h:831`）解决的是「**多个不同摄像头**同时工作」，**不解决**「同一摄像头被两个 session 共享」。

**→ 本项目决策：单 ARSession 路径，绝不并存 AVCaptureSession。**

### 2.9 ★ 单 session 路径的依据

`$AR/ARFrame.h`：

```
:115   @property (nonatomic, strong, nullable, readonly) AVDepthData *capturedDepthData;
:120   @property (nonatomic, readonly) NSTimeInterval capturedDepthDataTimestamp;
```

`:112-113` 原文：「The frame's captured depth data. **Depth data is only provided with face tracking** on frames where depth data was captured.」

→ 一次 `ARFaceTrackingConfiguration` 会话，**同时给出 `capturedImage`（彩色）+ `capturedDepthData`**，类型与 §2.1 完全一致，可直接进同一套渲染管线。

高分辨率拍照通道：

| API | 依据 | 可用性 |
|---|---|---|
| `-[ARSession captureHighResolutionFrameWithCompletion:]` | `$AR/ARSession.h:221` | iOS 16+ |
| `-[ARSession captureHighResolutionFrameUsingPhotoSettings:completion:]` | `$AR/ARSession.h:233` | **iOS 26+** |
| `ARVideoFormat.defaultPhotoSettings` | `$AR/ARVideoFormat.h:65` | iOS 26+ |
| `ARConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing` | `$AR/ARConfiguration.h:200` | iOS 16+ |
| 失败码 `HighResolutionFrameCaptureInProgress=106` / `Failed=107` | `$AR/ARError.h:37,40` | — |

**⚠️ 未核实**：`ARFrame.capturedDepthData` 的 `depthDataType` 具体是 Disparity 还是 Depth、分辨率多少 —— 头文件未写 → 见 §6 真机探针 P10。
**⚠️ 深度帧与视频帧节奏不一致**（有独立的 `capturedDepthDataTimestamp`），需要按时间戳对齐。

---

## 三、设备兼容性（关键利好）

官方文档 [ARFaceTrackingConfiguration](https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration) 原文：

> **Face tracking supports devices with Apple Neural Engine in iOS 14 and iPadOS 14** and requires a device with a TrueDepth camera on iOS 13 and iPadOS 13 and earlier.

→ **iOS 14 起，人脸追踪不再要求 TrueDepth**，A12 及以上机型（含 iPhone SE 2/3）都能拿到 `ARFaceAnchor` 的全部数据，包括 `leftEyeTransform` / `rightEyeTransform` / `lookAtPoint`。

而 [ARFrame.capturedDepthData](https://developer.apple.com/documentation/arkit/arframe/captureddepthdata) 原文：

> This depth data is available only in face-based experiences … **using the device's front TrueDepth camera.** This property's value is `nil` when running other AR configurations.

→ **只有「前摄实时深度图」限 TrueDepth。**

**本项目的兼容性分层**：

| 能力 | 硬件要求 | 覆盖范围 |
|---|---|---|
| 眼位追踪（核心玩法） | A12+ 神经引擎，iOS 14+ | iPhone XS 及以后几乎全部机型，含 SE 2/3 |
| 前置现拍带深度照片 | TrueDepth 前置摄像头 | iPhone X 及以后带刘海/灵动岛机型 |
| 相册人像照片视差 | 无（深度来自文件） | 全部机型 |

**核心玩法所需的深度来自照片文件本身，前摄只用于眼位 → 不需要 TrueDepth，支持面比预想宽得多。**

---

## 四、Swift 命名的诚实说明

本文列出的 **ObjC selector 是核实过的硬事实**。Swift 侧拼写由 clang importer 规则推导，核实过程中尝试用 `swift-api-digester` / `swift-ide-test` 机器验证**均失败**（前者只导出 Swift overlay，后者本机不存在）。ARKit 无 `.swiftinterface`、无 `.apinotes`；`AVFoundation.apinotes` 对 `AVDepthData` 只有两条 enum 重命名（`AVDepthDataAccuracy` → `AVDepthData.Accuracy`:861、`AVDepthDataQuality` → `AVDepthData.Quality`:863），**无方法级 SwiftName 覆盖**。

**唯一机器验证过的 Swift 重命名**：`AVFoundation.apinotes:657` → `depthDataOutput(_:didOutput:timestamp:connection:)`。

**实现时的规矩**：写下每个 Swift API 名之前，在 Xcode 里 Cmd-点进 generated interface 确认一次。编译器是唯一裁判。

**已由编译实测确认的 Swift 拼写**（随实现推进持续补充）：

| ObjC selector | Swift 实际拼写 | 确认于 |
|---|---|---|
| `viewMatrixForOrientation:` | **`viewMatrix(for:)`** | Task 11 探针实现，编译器报错后修正 |

这条恰好印证了本节的规矩：按 ObjC selector 直译成 `viewMatrixForOrientation(_:)` 编译不过。

---

## 五、已纠正的记忆偏差（防止再犯）

| 曾经以为 | 实际 |
|---|---|
| `AVDepthData.init(fromDictionaryRepresentation:)` | 类工厂 `+depthDataFromDictionaryRepresentation:error:` |
| `converting(toDepthDataType:)` | selector 是 `depthDataByConvertingToDepthDataType:` |
| `applyingExifOrientation(_:)` | selector 是 `depthDataByApplyingExifOrientation:` |
| matte 像素属性叫 `matteImage` | 叫 **`mattingImage`** |
| PhotoKit 能直接请求带深度的原图 | **不能**，只能拿原始 `NSData`/URL 再走 ImageIO |
| 语义分割 matte 有 Sky 类型 | AVFoundation 只有 Skin/Hair/Teeth/Glasses；Sky 只在 ImageIO 常量侧 |
| ARKit 世界原点在设备初始位姿 | **SDK 无任何定义**，只是在线文档说法 |
| 人脸追踪需要 TrueDepth | iOS 14 起只需 A12+ 神经引擎 |
| 人脸追踪固定 60fps | **头文件无任何帧率数值**，需实测 |

以下记忆经核实**正确**，可放心使用：`PHAssetMediaSubtypePhotoDepthEffect`、三个 `kCGImageAuxiliaryDataType*` 常量、`isDepthDataDeliverySupported/Enabled`、`.builtInTrueDepthCamera` / `.builtInDualCamera` / `.builtInLiDARDepthCamera`、四个 CV 深度像素格式常量、`isNetworkAccessAllowed`。

---

## 六、真机探针清单（SDK 无依据，必须实测）

**这些是实施计划的第 0 步。在未知参数上写代码等于在猜。**

| 编号 | 待测事实 | 测法 | 影响 |
|---|---|---|---|
| P1 | `ARFaceTrackingConfiguration.supportedVideoFormats` 各档 `framesPerSecond` 实际值 | 遍历打印 | 决定滤波器参数与外推步长 |
| P2 | 纯人脸追踪（未开 world tracking）时 `camera.transform` 的实际基准 | 打印并观察设备移动时的变化 | 验证 §1.3 的绕开方案确实成立 |
| P3 | `didUpdateFrame` 实测频率是否等于 `videoFormat.framesPerSecond` | 对 `frame.timestamp` 做差分统计 | 同 P1 |
| P4 | `supportedNumberOfTrackedFaces` 实际返回值 | 打印 | 多人场景策略（本期只取首个） |
| P5 | `leftEyeTransform` / `rightEyeTransform` 的 Left/Right 是否为镜像语义 | 闭单眼 + 打印两眼世界坐标 x 分量 | **搞反会导致视差方向相反** |
| P6 | `lookAtPoint` 的实际尺度与距离含义 | 打印模长并与已知距离对照 | 决定是否使用（本期备选） |
| P7 | `ARFaceGeometry.vertices` 坐标系 | 打印极值 | 本期不用，备查 |
| P8 | `configurableCaptureDeviceForPrimaryCamera` 在人脸追踪下是否返回 nil | 打印 | 验证 §2.8 的独占结论 |
| P9 | 眼位单位是否为米 | 量双眼世界坐标距离，对照成人瞳距 0.050–0.075 m | **单位错会让视差差 1000 倍** |
| P10 | `ARFrame.capturedDepthData` 的 `depthDataType` 与分辨率 | 打印 `depthDataType` 四字符码 + `CVPixelBufferGetWidth/Height` | 决定现拍路径的深度处理分支 |
| P11 | 设备物理参数：屏幕显示区物理尺寸、前置摄像头相对屏幕中心的偏移 | 实测（尺量 + 已知机型规格核对） | 决定离轴投影的正确性基线 |

---

## 七、变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-10 | 初版。基于 Xcode 26.6 / iOS SDK 26.5 全面核实，含 11 项待实测探针。 |
