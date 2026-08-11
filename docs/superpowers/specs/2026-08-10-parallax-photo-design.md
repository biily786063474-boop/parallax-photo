# 视差定位玩法 · 立体照片 设计文档

**工程代号**：Parallax
**日期**：2026-08-10
**状态**：待用户审阅
**平台**：iOS 原生（Swift 6 / Metal / ARKit）
**目标**：上架 App Store

> App Store 显示名称在提交前确定，不影响本文档描述的任何工程结构。

---

## 1. 一句话

用前置摄像头实时追踪观察者的眼睛位置，把 iPhone 屏幕变成一扇窗——照片里的世界随你的移动改变透视，产生裸眼 3D 的立体照片效果。

---

## 2. 目标与非目标

### 2.1 目标

1. **观察者一侧物理正确**：眼位驱动的离轴投影，而非简单的图像平移。屏幕是窗框，不是贴纸。
2. **观感稳定**：追踪抖动不传导到画面；追踪丢失不产生跳变。
3. **永不穿帮**：任何视角下都不出现黑洞、拉丝、NaN 污染。
4. **合规可上架**：满足 5.1.2(vi)、5.1.1(i)、2.5.13 与 ADPLA Face Data 的全部要求。
5. **可测试**：全部数学逻辑可在 Mac 上以秒级反馈跑单元测试，不依赖真机。

### 2.2 非目标（明确排除）

| 排除项 | 原因 |
|---|---|
| **双眼立体视觉（双目视差）** | 裸眼状态下普通 OLED 屏幕**物理上无法**把不同图像分送左右眼。见 §2.4 |
| **Apple 空间照片（Spatial Photo）** | 空间照片是双目立体格式，需 iPhone 15 Pro+ 拍摄、Vision Pro 观看。本项目做的是另一条路 |
| 光栅卡玩法 | 独立玩法，共用追踪底座，另立 spec |
| 物理精确的三维重建 | `AVDepthData` 是 non-rectilinear 的，官方明说「不能用来关联 3D 空间中的点」（见 `docs/api-facts-arkit-depth.md` §2.2）。本项目做的是**艺术化视差**。 |
| 任何云端功能 | 零出网是 ASC 隐私问卷答「不收集」的前提 |
| 眼神门禁交互（看着才显示） | 审核指南 2.5.13 禁止用 ARKit 做人脸认证 |
| 空间照片 / Vision Pro | 手上设备（iPhone 14 Pro Max）不支持拍摄空间照片 |
| AI 图像生成 | 项目红线。深度估计（不产生新画面）不在此列，但属二期。 |

### 2.3 明确不承诺的事

- **不承诺几何精确。** 验收标准中不出现任何无法验证的 3D 精度指标。
- **不承诺所有照片可用。** 深度来自文件内嵌数据，非人像照片一期不支持（二期兜底）。
- **不承诺"不动也立体"。** 见下节。

### 2.4 我们提供哪几条深度线索（防止期待错位）

人类的深度感知有五条主要线索。本项目能提供三条半：

| 线索 | 原理 | 本项目 |
|---|---|---|
| **运动视差** | 观察者移动时近处物体比远处移动快 | ✅ 完整提供，是核心 |
| **透视 / 遮挡 / 纹理梯度 / 阴影** | 图像本身携带 | ✅ 照片自带 |
| **离轴透视（窗口效应）** | 视锥随眼位改变，可"探头看到侧面" | ✅ 见 §7 |
| **双眼视差** | 左右眼看到不同图像 | ❌ 裸眼 + 普通屏幕物理不可能 |
| **调节与辐辏** | 眼球对焦距离的肌肉反馈 | ❌ 所有像素都在屏幕平面上 |

**真实体验因此是：「不动的时候是一张平面照片，一动起来空间感就出来了。」**

这与 Vision Pro 空间照片的「不动也立体」是**两种不同的东西**，不是它的打折版。

**自测方法**（判断这个玩法值不值得做）：闭上一只眼，左右晃头看面前的桌子。此时你感知到的空间感 —— 就是本项目能提供的全部。

**物理限制的诚实说明**：6.7 英寸屏幕在 30cm 观看距离处约占 13°×28° 视野。窗口效应的沉浸感受此视场角限制 —— 会很有空间感，但不会有包裹感。

**二期机会**：若拿到他人拍摄的空间照片（双目 HEIC），两个真实视角可用于填补遮挡区域，质量优于单视角外扩填补。属真实数据，不是猜测。

---

## 3. 范围划分

用户已确认：**分两期，开发顺序不变，架构从第一行代码就为二期留好位置（离屏渲染路径），不返工。**

### 3.1 一期（本 spec 的实施范围）

| # | 内容 |
|---|---|
| 1 | **真机探针**：把 11 个 SDK 无定义的未知量测成已知量（见 §11） |
| 2 | `ParallaxCore`：One Euro 滤波、离轴投影、视差预算、深度归一化、降级状态机 |
| 3 | Metal 渲染器：两层 LDI + 深度网格变形 + 背景外扩预计算 |
| 4 | 相册导入（`PHPickerViewController` + `depthEffectPhotosFilter`） |
| 5 | ARKit 现拍（单 session，`captureHighResolutionFrame`） |
| 6 | 查看器界面 + 视差强度调节 |
| 7 | 内置示例素材（首启动即有内容） |
| 8 | 四级降级链（`faceTracking` / `motion` / `idle` / `manual`） |
| 9 | 合规基础设施：`Info.plist`、`PrivacyInfo.xcprivacy`、CI 零网络断言 |

### 3.2 二期（上架前必须补齐，本 spec 不展开）

导出（视差视频 / 摇摆 GIF / Live Photo）、作品库、深度编辑面板、非人像照片兜底、预设与批量处理。

依据与理由见 `docs/appstore-compliance.md` §5。**一期完成后不可直接提交上架**——4.2.1 风险未消除。

---

## 4. 术语

| 术语 | 含义 |
|---|---|
| **观察者位置** | 双眼中点在**屏幕坐标系**中的位置，单位米。原点＝屏幕显示区中心，X 向右，Y 向上，Z 指向用户 |
| **离轴投影** | 非对称视锥投影。视锥由眼位与屏幕四角共同决定，屏幕平面即近裁剪面的映射目标 |
| **归一化深度** | `DepthMap` 内部统一的表示：`Float` 值域 `[0, 1]`，**0 = 最远，1 = 最近**。无论输入是 disparity（1/米，近大远小）还是 depth（米，近小远大），一律在 `DepthNormalization` 中转成这个约定。**全项目只此一种方向，转换只在这一处发生。** |
| **零视差面** | 归一化深度中视差为零的那一层，记作 `zeroParallaxDepth ∈ [0, 1]`。它落在屏幕平面上；深度大于它的部分向观察者凸出，小于它的部分向屏幕内凹陷。默认取深度直方图的中位数，用户可调 |
| **视差强度** | `parallaxScale`，把归一化深度差换算成几何位移的系数，单位米。顶点位移量 `z = (d − zeroParallaxDepth) × parallaxScale`。这是**艺术参数**，不是物理量——它的存在正是为了让设备物理参数的小偏差不影响观感 |
| **视差预算** | 允许的最大有效眼位偏移。超出后做软性衰减，防止遮挡空洞穿帮 |
| **LDI** | Layered Depth Image。本项目用简化的两层：前景层 + 外扩背景层 |
| **降级链** | 观察者位置的四级来源，按可用性依次回落 |

---

## 5. 架构

### 5.1 首要原则：把数学从设备上剥离

ARKit 人脸追踪**无法在模拟器运行**。若按常规写法把「ARKit 回调 → 算投影 → Metal 渲染」串成一体，任何数学错误都只能插着数据线肉眼调——严格 TDD 直接破产。

因此：**所有数学放进一个零框架依赖的 Swift Package，在 Mac 上跑测试。**

```
视差定位玩法/
├── ParallaxKit/                    Swift Package（纯逻辑）
│   ├── Package.swift
│   ├── Sources/ParallaxCore/
│   │   ├── Tracking/
│   │   │   ├── OneEuroFilter.swift
│   │   │   ├── ViewerPose.swift
│   │   │   └── ViewerPoseStateMachine.swift
│   │   ├── Projection/
│   │   │   ├── ScreenGeometry.swift
│   │   │   ├── OffAxisProjection.swift
│   │   │   └── ParallaxBudget.swift
│   │   ├── Depth/
│   │   │   ├── DepthMap.swift
│   │   │   ├── DepthNormalization.swift
│   │   │   └── EdgeDetection.swift
│   │   └── Devices/
│   │       └── DeviceProfile.swift
│   └── Tests/ParallaxCoreTests/
│
└── App/                            iOS App target
    ├── Features/
    │   ├── Viewer/                 查看器（核心界面）
    │   ├── Import/                 相册导入
    │   ├── Capture/                现拍
    │   └── Settings/               设置（含隐私政策入口）
    ├── Platform/
    │   ├── ARKitEyeSource.swift    ARFaceAnchor → 屏幕坐标眼位
    │   ├── MotionEyeSource.swift   CoreMotion → 相对姿态
    │   ├── DepthPhotoLoader.swift  ImageIO → AVDepthData
    │   └── Renderer/
    │       ├── ParallaxRenderer.swift
    │       ├── BackgroundInpainter.swift
    │       └── Shaders/*.metal
    ├── Resources/                  内置示例素材
    ├── Info.plist
    └── PrivacyInfo.xcprivacy
```

### 5.2 依赖规则（强制）

- `ParallaxCore` **只 import `Foundation` 与 `simd`**。禁止 import ARKit / Metal / UIKit / AVFoundation / Photos。
- `Platform/` 层是薄适配器。ARKit 适配器唯一职责是把 `ARFaceAnchor` 翻译成 `SIMD3<Float>`，翻译完立刻交给 Core。**薄到不值得单测，才是适配器的正确厚度。**
- **深度数据的分工边界**：`Platform/DepthPhotoLoader` 负责一切与 `AVDepthData` / `CVPixelBuffer` 打交道的事，产出一个裸的 `[Float]` 加尺寸；`Core/Depth` 只处理这个裸数组（归一化、NaN 替换、边缘检测）。因此 Core 能在 Mac 上用程序化生成的数组完整测试，而不需要任何真实照片。
- `Features/` 不得直接触碰 ARKit / Metal，只与 `Platform/` 的协议对话。

**CI 断言**：`ParallaxCore` 的源码中若出现被禁的 import，构建失败。

---

## 6. 数据流

```
ARFaceAnchor（频率见探针 P1/P3）
  │
  │ [1] worldEye = faceAnchor.transform * faceAnchor.leftEyeTransform
  │     （眼位 transform 是 anchor 局部空间，必须左乘 anchor.transform）
  ▼
双眼世界坐标 → 取中点（独眼观察点）
  │
  │ [2] cameraSpaceEye = camera.viewMatrixForOrientation(o) * worldEye
  │     ★ 永不假设世界原点位置——SDK 对此无任何定义
  ▼
相机空间眼位
  │
  │ [3] screenEye = flipZ(cameraSpaceEye) − deviceProfile.screen.cameraOffset
  │     ⚠️ 是减不是加：cameraOffset 是「摄像头相对屏幕中心」，
  │        要的是「眼睛相对屏幕中心」，所以减。
  │     ⚠️ Z 要翻转：ARKit 相机空间看向 −Z，屏幕空间 Z 指向用户。
  │        翻转方向由探针 P12 实测确认后写死。
  ▼
屏幕坐标系眼位（原点=屏幕中心，米）
  │
  │ [4] One Euro 滤波（三分量独立）+ 速度外推补显示延迟
  ▼
平滑眼位
  │
  │ [5] ParallaxBudget.clamp —— 软性夹进舒适锥
  ▼
有效眼位
  │
  │ [6] OffAxisProjection.matrix(eye:screen:near:far:)
  ▼
投影矩阵
  │
  │ [7] Metal：两层 LDI 渲染
  │     背景层（外扩填补，预计算）→ 前景层（深度网格变形，边缘按 matte 裁切）
  ▼
上屏
```

### 6.1 步骤 [2] 的依据

`ARCamera.viewMatrixForOrientation(_:)` 的头文件注释明写它「transform geometry **from world space into camera space**」。这是有契约的。

相对地，「ARKit 世界原点在设备初始位姿」这一说法**在整个 SDK 头文件中没有任何依据**（详见 `docs/api-facts-arkit-depth.md` §1.3）。任何依赖世界原点位置的推导都是把设计架在没有契约的假设上。

### 6.2 步骤 [3] 是本项目唯一的「脏数据」

ARKit 的坐标基准在**摄像头**，我们的窗口是**屏幕**。两者差几厘米，**每个机型都不同，Apple 没有任何 API 能查询**。

解法：内置设备参数表（`DeviceProfile`），按 machine identifier 匹配，未知机型退回保守默认值。

**诚实说明**：这是真实的工程债。缓解在于它只影响「绝对正确性基线」，上层还有艺术化的视差强度系数，几毫米偏差不会毁掉观感。初始值由机型规格推算，**必须经探针 P11 实测校准**。

### 6.3 步骤 [5] 是「永远好看」的安全阀

侧头角度越大，被遮挡区域露出的空洞越大。与其等空洞穿帮，不如在数学层面把眼位夹进不会穿帮的锥体内。

**关键要求：衰减必须软性且一阶连续**，用户感受是「到边了」，而不是「卡住了」。硬 clamp 会产生可见的速度突变。

---

## 7. 离轴投影

采用 Kooima 广义透视投影。给定屏幕三个角 `pa`（左下）、`pb`（右下）、`pc`（左上）与眼位 `pe`：

```
vr = normalize(pb - pa)          屏幕右向量
vu = normalize(pc - pa)          屏幕上向量
vn = normalize(cross(vr, vu))    屏幕法向（指向观察者）

va = pa - pe,  vb = pb - pe,  vc = pc - pe
d  = -dot(va, vn)                眼到屏幕平面的垂直距离

l = dot(vr, va) * near / d
r = dot(vr, vb) * near / d
b = dot(vu, va) * near / d
t = dot(vu, vc) * near / d

P = frustum(l, r, b, t, near, far)
M = 屏幕基向量构成的旋转矩阵
T = 平移 -pe

最终 = P · M · T
```

### 7.1 为什么这是灵魂

简单平移只会让画面滑动；离轴投影会让你**把手机往左移时多看到物体的右侧面**。这是「窗口」与「贴纸」的根本区别，也是这个玩法值不值得做的全部意义。

### 7.2 这个矩阵是可精确测试的

**核心断言：屏幕四角必须精确映射到 NDC 的 (±1, ±1)，对任意合法眼位都成立。**

这是一条不依赖硬件、不依赖观感、有唯一正确答案的数学性质——是整个项目 TDD 的锚点。

---

## 8. 渲染管线

### 8.1 两层 LDI + 深度网格变形

**背景层（预计算一次，运行时零开销）**
1. 用 `portraitEffectsMatte`（有则用）或深度梯度阈值（无 matte 时）分出前景遮罩
2. 把前景区域从彩色图中挖掉
3. 用 push-pull 金字塔算法把周围背景**外扩填补**进空洞
4. 结果作为背景纹理缓存

**前景层（每帧）**
1. 高密度网格（256×256 顶点），顶点位置由深度图位移：`z = (d - zeroParallaxDepth) * parallaxScale`
2. 乘离轴投影矩阵
3. 深度突变处的三角形按边缘遮罩剔除，露出下层背景而非拉伸成橡皮膜
4. 边缘用 matte alpha 做羽化，消除锯齿

**为什么背景填补要预计算**：视角变化时背景内容不变，只是被看到的区域不同。每帧重算是纯粹的浪费。预计算意味着运行时只有两次 draw call。

### 8.2 边缘质量的两条来源

| 来源 | 边缘依据 | 质量 |
|---|---|---|
| 相册人像照 | `portraitEffectsMatte`（系统生成的高质量前景 alpha）+ `hairMatte` | 高 |
| ARKit 现拍 | 仅深度梯度阈值（ARKit 路径**不提供** matte） | 中 |

**两条来源的边缘质量存在客观差异，spec 明确承认这一点。** 现拍路径的边缘调优是一期的已知难点。

### 8.3 性能目标

| 指标 | 目标 |
|---|---|
| 渲染帧率 | 跟随屏幕刷新率（iPhone 14 Pro Max 为 120Hz），掉帧率 < 1% |
| 每帧 draw call | ≤ 2（背景 + 前景） |
| 加载一张照片到可交互 | < 500ms（含深度解析与背景填补预计算） |
| 内存峰值 | < 200MB（单张照片） |

---

## 9. 降级状态机

### 9.1 四级链

```
   ┌─ faceTracking   ARKit 眼位（主通道）
   │      ↓ isTracked=false / 超时 / 中断 / 权限拒绝 / 机型不支持
   ├─ motion         CoreMotion 陀螺仪相对姿态
   │      ↓ 无运动数据
   ├─ idle           缓慢自动摆动（演示态）
   └─ manual         手指拖动，任何时候可临时接管，松手后回落
```

### 9.2 四条铁律

**① 层级之间必须交叉淡入，不能瞬切。**
过渡时长 300ms，时间加权混合两个来源的输出。追踪一丢就硬切会让画面「跳一下」，那一跳会让整个效果显得廉价。

**② `idle` 不是兜底，是首屏。**
app 一打开，在用户做任何事之前，示例照片就应该在缓慢摆动（李萨如曲线，两轴周期不成整数比，避免可察觉的重复）。

这一条同时解决三件事：
- 审核员一眼看到功能在工作（对冲风险 R1）
- 不支持的机型上 app 不是空壳（对冲风险 R2）
- 新用户不用被教育就懂这是什么

**③ 降级路径本身必须是完整可玩的体验。**
不给相机权限的用户，得到的应该是「陀螺仪驱动的视差 + 完整的照片浏览」，而不是一个「你的设备不支持」的死胡同。这是审核指南 5.1.1(iv) 的明文要求：「Where possible, provide alternative solutions for users who don't grant consent.」

**④ 不支持人脸追踪的机型，入口不暴露。**
运行时判断 `ARFaceTrackingConfiguration.isSupported`，为 false 时隐藏或明确置灰追踪相关入口。官方 Tip 原文：「Check the `isSupported` property before offering AR features in your app's UI, so that users on unsupported devices aren't disappointed.」

### 9.3 降级触发条件

| 触发 | 检测方式 | 目标状态 |
|---|---|---|
| 机型不支持 | `ARFaceTrackingConfiguration.isSupported == false` | motion（启动即定） |
| 相机权限被拒 | `AVCaptureDevice.authorizationStatus` | motion |
| 追踪丢失 | `ARFaceAnchor.isTracked == false` | motion（300ms 淡出） |
| 无 anchor 更新 | 超过阈值时长未收到 face anchor | motion |
| session 中断 | `sessionWasInterrupted(_:)` | motion |
| session 失败 | `session(_:didFailWithError:)` | motion |
| 无运动数据 | CoreMotion 不可用 | idle |
| 用户拖动 | 手势识别 | manual（临时接管） |

---

## 10. 错误处理

**核心原则：这个 app 里几乎没有「错误」，只有「降级」。**

| 情况 | 错误的做法 | 正确的做法 |
|---|---|---|
| 照片无深度图 | 弹「加载失败」 | 说明这张照片没有深度信息，并给出可行动的下一步（筛选人像照 / 现在拍一张）。选择器用 `depthEffectPhotosFilter` 从源头减少这种挫败 |
| 深度图含 `NaN` | 直接上 GPU | **上 GPU 前必须替换。** 未滤波深度图用 NaN 表示缺失像素（`AVDepthData.h:209` 明文），NaN 进顶点着色器会污染整条管线，渲出黑洞或整片撕裂 |
| ARKit session 失败 | 崩溃或黑屏 | 降级到 motion，界面无感 |
| iCloud 照片未下载 | 静默失败 | `isNetworkAccessAllowed` 默认为 NO，必须显式开启并给出下载进度 |
| 深度图全为常量 | 除零产生 NaN | 归一化时保护除零，退化为平面（视差为零但不崩） |
| 高分辨率拍照进行中再次触发 | 重复请求 | 捕获 `ARErrorCodeHighResolutionFrameCaptureInProgress`(106)，忽略并提示 |

---

## 11. 真机探针（实施计划的第 0 步）

**在未知参数上写代码等于在猜。** 以下 11 项在 SDK 中无定义，必须先测成已知量。

探针是一个只打印数字的最小 app target，不含任何渲染逻辑。

| 编号 | 待测 | 影响 |
|---|---|---|
| P1 | `supportedVideoFormats` 各档 `framesPerSecond` | 滤波器参数与外推步长 |
| P2 | 纯人脸追踪时 `camera.transform` 的实际基准 | 验证 §6.1 的绕开方案成立 |
| P3 | `didUpdateFrame` 实测频率 | 同 P1 |
| P4 | `supportedNumberOfTrackedFaces` | 多人策略（一期只取首个） |
| P5 | **左右眼是否镜像** | **搞反会导致视差方向相反** |
| P6 | `lookAtPoint` 的尺度与距离含义 | 决定是否使用（一期备选） |
| P7 | `ARFaceGeometry.vertices` 坐标系 | 一期不用，备查 |
| P8 | `configurableCaptureDeviceForPrimaryCamera` 是否为 nil | 验证摄像头独占结论 |
| P9 | **眼位单位是否为米**（量瞳距对照 0.050–0.075 m） | **单位错会让视差差 1000 倍** |
| P10 | `capturedDepthData` 的类型与分辨率 | 现拍路径的深度处理分支 |
| P11 | **设备物理参数**：屏幕显示区尺寸、摄像头相对屏幕中心偏移 | 离轴投影的正确性基线 |

**P5、P9、P11 是阻塞性的**——它们错了，后面全错。

### 11.1 目标设备的初始参数（待 P11 校准）

| 设备 | 显示区尺寸（推算） | 摄像头位置 | 备注 |
|---|---|---|---|
| iPhone 14 Pro Max | 约 71.2 × 154.4 mm（2796×1290 @460ppi） | 灵动岛内，屏幕上方 | 主力测试机 |
| iPad Pro 11" (M4) | 待实测 | **在长边（横向）**，与 iPhone 不同 | 坐标换算随设备方向变化，需单独处理 |

**⚠️ M4 iPad Pro 把前置摄像头移到了长边**，这不是一个可以套用 iPhone 逻辑的特例，`DeviceProfile` 必须把「摄像头在哪条边」建模进去。

---

## 12. 测试策略

### 12.1 TDD 主战场：Mac 上的单元测试

`ParallaxCore` 零框架依赖 → `swift test` 秒级反馈。**每个功能先写失败的测试，再写实现。**

**OffAxisProjection**
- 屏幕四角映射到 NDC 的 (±1, ±1)，容差 1e-5，对多组随机合法眼位都成立
- 眼位在屏幕中心正前方时，退化为对称视锥（l = -r, b = -t）
- 眼位左移时，NDC 边界的变化方向正确（符号断言）
- 眼位贴近屏幕平面时不产生 NaN/Inf

**OneEuroFilter**
- 常量输入 → 输出收敛到该常量
- 阶跃输入 → 单调趋近，无过冲
- 高频噪声输入 → 输出方差显著低于输入方差
- 快速移动 → 相位延迟低于阈值（One Euro 的设计目标就是这个权衡）
- 时间戳倒退或重复 → 不崩溃、不产生 NaN

**ParallaxBudget**
- 锥内眼位原样通过
- 锥外眼位被衰减，且**输出关于输入一阶连续**（数值微分检查，无跳变）
- 极端输入（远超锥体十倍）仍返回有限值

**DepthMap / DepthNormalization**
- NaN 被替换，输出中无 NaN 泄漏
- disparity ↔ depth 转换往返一致
- 全常量深度图 → 除零保护生效，不产生 NaN
- 空深度图 / 尺寸为零 → 明确失败而非崩溃

**ViewerPoseStateMachine**
- 追踪丢失 → 300ms 内平滑过渡到 motion
- 过渡期间输出连续（相邻采样差值有界）
- 恢复追踪 → 平滑回归
- manual 接管与释放的优先级正确
- 快速反复丢失/恢复 → 不产生振荡

### 12.2 黄金图像测试（模拟器，Metal 可用）

用合成素材（一个球 + 一个平面的程序化深度图）与固定眼位渲染，与黄金图比对：
- 整体差异低于 PSNR 阈值
- 深度突变区域不出现拉伸伪影（检查指定像素带的梯度）
- 背景填补区域无黑洞（alpha 全覆盖断言）

### 12.3 真机手动验证（只验证本来就只能靠眼睛判断的事）

**这部分由用户在真机上执行，我提供清单，不代替判断。**

- 跟手感：头动到画面响应的主观延迟
- 抖动：静止不动时画面是否稳定
- 过渡：用手遮住摄像头再放开，是否有可见跳变
- 边缘：人像边缘在大角度下是否有毛刺或拉丝
- 极限：快速大幅度移动时是否穿帮
- 降级：关闭相机权限后是否仍完整可玩
- 发热与耗电：连续使用 10 分钟

### 12.4 CI 断言（合规相关）

- `ParallaxCore` 无被禁 import
- 全工程无 `URLSession` / 网络相关符号引用
- 无第三方依赖
- `PrivacyInfo.xcprivacy` 存在且键值合法

---

## 13. 合规要求（工程约束）

完整清单见 `docs/appstore-compliance.md`。以下是**必须写进代码**的部分：

| 约束 | 依据 |
|---|---|
| 眼位不落盘、不进日志、不进 UserDefaults、不进崩溃报告；`ARFrame` 用完即弃 | ADPLA「Face Data」条款：默认不得离开设备 |
| 禁止任何门禁式人脸交互（看着才显示/人脸解锁） | 审核指南 2.5.13 |
| 零网络调用、零第三方 SDK | ASC 隐私问卷答「不收集」的前提；官方口径：「Data that is processed only on device is not 'collected'」 |
| 只申请 `NSCameraUsageDescription`；相册走 PHPicker 不申请权限 | 5.1.1(iii) 明确偏好进程外选择器 |
| **不添加** `NSFaceIDUsageDescription` | 那是 LocalAuthentication 的键，加了暗示在做人脸认证，撞 2.5.13 |
| `UIRequiredDeviceCapabilities` 中不加任何硬件键 | 官方警告：capability 要求「只能维持或放宽」，是单向门 |
| 相机权限在用户点「开始追踪」时才请求，不在启动时弹 | HIG：「wait to request permission until people actually use an app feature that requires access」 |
| 设置页必须有隐私政策入口 | 5.1.1(i)：ASC 元数据**和 app 内**两处都要 |
| 帧计时若用 `mach_absolute_time` / `systemUptime`，必须在 privacy manifest 声明 `SystemBootTime` + `35F9.1` | 2024-05-01 起 ASC 直接不收包 |

---

## 14. 设备兼容性

**最低部署目标：iOS 17。** 以下「硬件要求」一栏描述的是在部署目标之上还需要哪些硬件条件。

| 能力 | 在 iOS 17+ 上还需要 | 覆盖范围 |
|---|---|---|
| 眼位追踪（核心玩法） | A12+ 神经引擎 | iPhone XS 及以后几乎全部机型，含 SE 2/3 |
| 前置现拍带深度照片 | TrueDepth 前置摄像头 | iPhone X 及以后带刘海/灵动岛机型 |
| 相册人像照片视差 | 无（深度来自文件） | 部署目标内全部机型 |
| 陀螺仪降级 | 陀螺仪 | 部署目标内全部机型 |

**关键事实**：官方文档明写「Face tracking supports devices with **Apple Neural Engine** in iOS 14 and iPadOS 14」——**自 iOS 14 起人脸追踪不再要求 TrueDepth**。我们的部署目标 iOS 17 已远高于这道门槛，所以这条对本项目的实际含义是：**A12+ 即可追踪眼位，与有没有 TrueDepth 无关。** 只有 `ARFrame.capturedDepthData`（前摄实时深度）仍限 TrueDepth。

**本项目核心玩法的深度来自照片文件本身，前摄只用于眼位 → 支持面比预想宽得多。**

API 可用性分支：`captureHighResolutionFrameUsingPhotoSettings:` 需 iOS 26，作为增强路径按 `#available` 分支；基础的 `captureHighResolutionFrameWithCompletion:`（iOS 16+）在部署目标内始终可用，作为兜底。

---

## 15. 一期验收标准

全部可客观验证，无主观措辞：

1. `swift test` 全绿，`ParallaxCore` 行覆盖率 ≥ 85%
2. 黄金图像测试通过，无拉伸伪影、无黑洞
3. 真机（iPhone 14 Pro Max）上渲染帧率跟随 120Hz，掉帧率 < 1%
4. 加载一张人像照片到可交互 < 500ms
5. 11 项探针全部测完并写入 `DeviceProfile` 与 `docs/api-facts-arkit-depth.md`
6. 关闭相机权限后，app 仍能完整浏览与操作（陀螺仪 + idle 驱动）
7. `ARFaceTrackingConfiguration.isSupported == false` 的模拟条件下无崩溃、无空屏
8. 深度图注入人工 NaN 后渲染无异常（自动化测试覆盖）
9. CI 断言全绿：无被禁 import、无网络符号、无第三方依赖
10. **用户在真机上亲眼确认观感达标**——这条不可由测试替代

---

## 16. 风险登记

| # | 风险 | 缓解 |
|---|---|---|
| T1 | 设备物理参数不准导致视差基线偏差 | 探针 P11 实测；上层艺术系数可补偿；`DeviceProfile` 可扩展 |
| T2 | 左右眼镜像搞反 → 视差方向相反 | 探针 P5 优先测；单元测试锁定符号约定 |
| T3 | 眼位单位不是米 → 视差差 1000 倍 | 探针 P9 用瞳距实测 |
| T4 | 现拍路径无 matte，边缘质量不如相册路径 | spec 已明确承认差异；边缘调优列为一期已知难点 |
| T5 | 追踪延迟导致「拖影感」 | One Euro + 速度外推；探针 P1/P3 定参数 |
| T6 | 大角度下遮挡空洞穿帮 | 视差预算软性夹紧 + 背景外扩填补 |
| T7 | 长时间使用发热降频 | 真机验证清单含 10 分钟连续使用；必要时降低追踪帧率 |
| A1–A15 | 上架合规风险 | 见 `docs/appstore-compliance.md` §8 |

---

## 17. 相关文档

| 文档 | 内容 |
|---|---|
| `docs/api-facts-arkit-depth.md` | ARKit 与深度 API 的核实事实，含 11 项探针清单与已纠正的记忆偏差 |
| `docs/appstore-compliance.md` | 上架合规清单，含 15 项风险登记与提交前检查清单 |

**实现时以这两份文档为准。它们记录的是核实过的事实，不是记忆。**

---

## 18. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-10 | 初版。经四轮 SDK 与官方文档核实，用户逐段确认架构、数据流、降级设计与范围划分。 |
