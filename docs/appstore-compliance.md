# App Store 上架合规清单

> **本文性质**：全部条款号、key 名、原文引用均来自 Apple 官方页面核实。标注「经验判断」的部分**没有官方依据**，不要当成规则引用。
>
> 核实日期：2026-08-10
> 适用对象：本项目（ARKit 人脸追踪眼位 + 深度照片视差渲染，零出网、零第三方 SDK）

---

## 零、一句话结论

本项目的用途**是合规的**，但有两个真实的拒审风险：**4.2.1（ARKit 体验太单薄）** 和 **审核员实测不出效果**。两者的解药都在产品设计里，不在文案里。

---

## 一、人脸数据合规

### 1.1 适用条款是 5.1.2(vi)

> **5.1.2(vi)** "Data gathered from the HomeKit API, HealthKit, Clinical Health Records API, MovementDisorder APIs, ClassKit or from **depth and/or facial mapping tools (e.g. ARKit, Camera APIs, or Photo APIs) may not be used for marketing, advertising or use-based data mining, including by third parties.**"

来源：<https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing>

**解读**：条款禁止的是**下游用途**，不禁止用 ARKit 人脸数据做渲染。本项目用途合规。

### 1.2 Face Data 的定义与义务（开发者协议 ADPLA）

ADPLA 定义：

> "**Face Data** means information related to human faces (e.g., face mesh data, facial map data, face modeling data, **facial coordinates or facial landmark data**, including data from an uploaded photo) that is obtained from a user's device and/or through the use of the Apple Software (e.g., **through ARKit**, the Camera APIs, or the Photo APIs)…"

→ **`leftEyeTransform` / `rightEyeTransform` 明确属于 Face Data。**

义务条款要点（原文摘录）：

> - "You must do so **only to provide a service or function that is directly relevant to the use of the Application**"
> - "obtain **clear and conspicuous consent** from such users before any collection or use of Face Data"
> - "You may not use Face Data **for authentication, advertising, or marketing purposes**"
> - "You may not use Face Data **to build a user profile**"
> - "You agree not to **transfer, share, sell, or otherwise provide Face Data to advertising platforms, analytics providers, data brokers, information resellers**"
> - "**Face Data may not be shared or transferred off the user's device unless** You have obtained clear and conspicuous consent for the transfer and the Face Data is used only in fulfilling a specific service or function"

来源：<https://developer.apple.com/support/downloads/terms/apple-developer-program/Apple-Developer-Program-License-Agreement-English.pdf>

> ⚠️ 该 PDF 使用子集字体编码，**条款章节编号无法机器验证**，故本文只按标题「Face Data」引用，不给编号。

**准确表述**：不是「绝对禁止离开设备」，而是「**默认不得离开设备，除非取得明示同意且用途受限**」。本项目全程不落盘不上传 → 直接满足最严格分支。

### 1.3 禁止做人脸认证

> **2.5.13** "Apps using facial recognition for account authentication must use **LocalAuthentication** (and not ARKit or other facial recognition technology) where possible, and must use an alternate authentication method for users under 13 years old."

来源：<https://developer.apple.com/app-store/review/guidelines/#software-requirements>

**工程约束（写进代码评审检查项）**：ARKit 人脸数据**仅用于计算视点**。禁止任何形式的「看着屏幕才显示 / 人脸在场才解锁」门禁式交互——即使它看起来是个很酷的玩法。

### 1.4 隐私政策：两条独立的强制要求

**要求 A —— 所有 app 通用**

> **5.1.1(i)** "**All apps must include a link to their privacy policy in the App Store Connect metadata field and within the app in an easily accessible manner.**"

来源：<https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage>
ASC 侧再次确认：「Privacy Policy URL — **This is required for all apps.**」<https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy>

→ **两处都要有**：ASC 元数据字段 + app 内可点击入口（设置页即可）。无豁免，与是否采集数据无关。

**要求 B —— 人脸追踪专属**

> "Because face tracking provides your app with personal facial information, **your app must include a privacy policy describing to users how you intend to use face tracking and face data.**"

来源：<https://developer.apple.com/documentation/arkit/arfacetrackingconfiguration>、<https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission>

→ 隐私政策正文必须有**专门讲人脸追踪的小节**，不能只有通用模板。

**建议写死的三句话**（对齐 5.1.2(vi) 与 ADPLA 措辞）：
1. 人脸数据仅在设备内存中处理，用于计算视点位置；
2. 不写入存储、不上传、不与任何第三方共享；
3. 不用于广告、营销、身份识别或用户画像。

---

## 二、Info.plist 权限键

| 场景 | 准确 key 名 | 本项目是否需要 |
|---|---|---|
| ARKit 前置相机（人脸追踪） | `NSCameraUsageDescription` | **必需** |
| 直接用 PhotoKit 读相册 | `NSPhotoLibraryUsageDescription` | **不需要**（改用 PHPicker） |
| 把结果存回相册 | `NSPhotoLibraryAddUsageDescription` | 二期导出时需要 |

- **ARKit 人脸追踪不需要任何额外键，也不需要 entitlement。** 官方原文只要求：「Your app's `Info.plist` file must include the NSCameraUsageDescription key.」来源：<https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission>
- **⚠️ 不要加 `NSFaceIDUsageDescription`** —— 该键定义是「the ability to authenticate with Face ID」，属 LocalAuthentication，与 ARKit 无关；加了反而暗示在做人脸认证，正撞 2.5.13。来源：<https://developer.apple.com/documentation/bundleresources/information-property-list/nsfaceidusagedescription>
- **相册权限可以完全不申请**：官方示例代码明写「**Apps don't need to request photo library permission when using either class**」（`PHPickerViewController` / `UIImagePickerController`）。来源：<https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios>
- 键的硬性校验（否则崩溃或被拒）：非空且非纯空格、< 4000 bytes、类型正确。来源：<https://developer.apple.com/documentation/uikit/requesting-access-to-protected-resources>

### 文案要求（官方有正反例，照句式抄）

> **5.1.1(ii)** "**Ensure your purpose strings clearly and completely describe your use of the data.**"

HIG 原文：「Aim for a **brief, complete sentence** that's straightforward, specific, and easy to understand. **Use sentence case, avoid passive voice, and include a period at the end.**」

官方对照表：

| 评价 | 例子 | 官方点评 |
|---|---|---|
| 好 | `The app records during the night to detect snoring sounds.` | "An active sentence that clearly describes how and why the app collects the data." |
| 差 | `Microphone access is needed for a better experience.` | "A passive sentence that provides a vague, undefined justification." |
| 差 | `Turn on microphone access.` | "An imperative sentence that doesn't provide any justification." |

来源：<https://developer.apple.com/design/human-interface-guidelines/privacy>

**本项目 `NSCameraUsageDescription` 采用**：

> The front camera tracks your eye position on device so photos can shift perspective as you move. Camera images are never saved or sent anywhere.

（中文本地化用 `InfoPlist.xcstrings` 字符串目录提供，不要只留英文。）

> 「因文案笼统被拒的常见情形」—— Apple **没有公开统计或专门列表**，「Common App Rejections」页面已不再列该项。可依据的官方口径只有 5.1.1(ii) 与上面 HIG 三条正反例。**此项属经验判断。**

---

## 三、PrivacyInfo.xcprivacy 隐私清单

### 3.1 是否必须提供

官方措辞是**条件性的**：

> "**Starting May 1, 2024, apps that don't describe their use of required reason API in their privacy manifest file aren't accepted by App Store Connect.**"

来源：<https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>、<https://developer.apple.com/news/?id=3d8a9yyh>

触发条件是「**你自己的代码用了 required reason API**」，不是「是否采集数据」。实务上任何 app 只要碰 `UserDefaults` 或文件时间戳就触发 → **结论：本项目要建这个文件。**

限定（省事的一条）：只需申报**你自己代码/你的 SDK 代码**调用的 API；Apple 系统框架内部的调用不用申报。

文件名与位置（强制）：`PrivacyInfo.xcprivacy`，iOS app 放在 bundle 根 —— `Sample.app/PrivacyInfo.xcprivacy`。来源：<https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk>

### 3.2 required reason API 全量表

| `NSPrivacyAccessedAPIType` | reason codes |
|---|---|
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `DDA9.1`（展示给用户，不得离开设备）、`C617.1`（读自身容器/App Group/CloudKit 容器内文件元数据）、`3B52.1`（用户经 document picker 授权的文件）、`0A2A.1`（仅三方 SDK 包装函数） |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1`（测量 app 内事件间隔/计时器，不得离开设备）、`8FFB.1`（计算 app 内事件绝对时间戳）、`3D61.1`（用户主动提交的 bug 报告） |
| `NSPrivacyAccessedAPICategoryDiskSpace` | `85F4.1`（展示磁盘空间）、`E174.1`（写文件前检查空间，行为对用户可见）、`7D9E.1`（用户主动提交的 bug 报告）、`B728.1`（健康研究类专用） |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | `3EC4.1`（自定义键盘 app）、`54BD.1`（按活动键盘定制 UI） |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1`（仅 app 自身可访问）、`1C8F.1`（同 App Group 共享）、`C56D.1`（仅三方 SDK 包装函数）、`AC6B.1`（MDM 托管配置） |

来源：<https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype>、<https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest>

### 3.3 本项目预计的最小声明集

| 用途 | 类别 | reason |
|---|---|---|
| 存用户偏好（视差强度、追踪开关等） | `NSPrivacyAccessedAPICategoryUserDefaults` | `CA92.1` |
| 读写沙盒缓存文件元数据 | `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1` |
| 导出前检查可用空间（二期） | `NSPrivacyAccessedAPICategoryDiskSpace` | `E174.1` |
| **帧计时**（若用 `mach_absolute_time()` / `ProcessInfo.systemUptime`） | `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1` |

> **⚠️ 最后一条是视差/追踪类 app 最容易漏的。** 渲染循环几乎一定要做帧计时。
> `CACurrentMediaTime()` 是否计入该类别 —— **Apple 列表未列出它，未找到官方依据**。保守做法：若使用则一并声明 `35F9.1`（该 reason 本身就是「测量 app 内事件间隔」，与实际用途相符）。

### 3.4 零采集时其余三个顶层键

```xml
<key>NSPrivacyTracking</key>           <false/>
<key>NSPrivacyTrackingDomains</key>    <array/>
<key>NSPrivacyCollectedDataTypes</key> <array/>
```

来源：<https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>

> 官方**没有**明文说零采集时可省略或必须写空数组。**此填法属经验判断**，但安全：这四个是官方列举的 expected top-level keys，而 ASC 只拒绝「unexpected keys or values」。

---

## 四、App Store Connect「App 隐私」问卷

### 4.1 官方豁免口径（本项目最关键的一句）

> "**You use location, device identifiers, and other sensitive data, but only on device, and the data is never sent to a server.** — **Data that is processed only on device is not 'collected' and does not need to be disclosed in your answers.** If you derive anything from that data and send it off device, the resulting data should be considered separately."

配套的 "collect" 定义：

> "'Collect' refers to **transmitting data off the device** in a way that allows you and/or your third-party partners to access it for a period longer than what is necessary to service the transmitted request in real time."

来源：<https://developer.apple.com/app-store/app-privacy-details/>

### 4.2 本项目的正确答法

首问选 **"No, we do not collect data from this app"** → ASC 明确「You don't need to answer any further questions.」
来源：<https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy>

**前提条件必须逐条为真**（任何一条不成立，答案立刻变）：
- 无任何网络请求
- 无崩溃/分析上报
- 无第三方 SDK
- 人脸数据与照片全部只在内存中处理

提交时会弹确认：「you agree that your responses are accurate… and that **you will promptly update your responses if your data practices change**」。

> 数据类型清单中**没有 "Face Data" 这一类**；biometric data 归在 **Sensitive Info**。另有 `Surroundings > Environment Scanning` 与 `Body > Hands / Head`（"The user's head movement"）。本项目零上传 → 一个都不勾。将来若有派生数据离开设备，需在 Sensitive Info 与 Body/Head 之间做归类判断 —— **此归类无官方专门说明，属经验判断。**

---

## 五、4.2 最低功能（本项目最大的拒审风险）

### 5.1 官方原文

> **4.2 Minimum Functionality** — "Your app should include features, content, and UI that elevate it beyond a repackaged website. If your app is not particularly useful, unique, or 'app-like,' it doesn't belong on the App Store. **If your App doesn't provide some sort of lasting entertainment value or adequate utility, it may not be accepted.**"

> **4.2.1** "Apps using ARKit should provide rich and integrated augmented reality experiences; **merely dropping a model into an AR view or replaying animation is not enough.**"

来源：<https://developer.apple.com/app-store/review/guidelines/#minimum-functionality>

> 子条实际存在的只有 4.2.1 / 4.2.2 / 4.2.3(i)(ii) / 4.2.6 / 4.2.7。**4.2.4 与 4.2.5 官方标为 "Intentionally omitted"，不要引用这两个编号。**

相关的三条：

> **2.2 Beta Testing** — "**Demos, betas, and trial versions of your app don't belong on the App Store – use TestFlight instead.**"

> **4.3(b) Spam** — "Don't submit apps that are indistinguishable from what's already widely available."

> "**If your app doesn't offer much functionality or content, or only applies to a small niche market, it may not be approved.**" —— <https://developer.apple.com/distribute/app-review/>

### 5.2 对本项目的直接威胁

我们使用 `ARFaceTrackingConfiguration`，即「using ARKit」，审核员会直接套 4.2.1。「打开一张照片 + 晃头看视差」在措辞上高度接近 "merely dropping a model into an AR view"。

### 5.3 功能下限（把「效果」变成「工具」）

| # | 要求 | 期次 |
|---|---|---|
| 1 | 完整素材闭环：相册导入 + app 内拍摄 + 本地作品库（保存/命名/删除/排序） | 二期 |
| 2 | **可导出的产物**（视差视频 / 摇摆 GIF / Live Photo）—— 屏上效果无法分享，这是「lasting value」的核心杠杆 | 二期 |
| 3 | 深度编辑：深度图可视化、视差强度、零视差面、边缘修补 | 一期部分 + 二期完善 |
| 4 | 兼容非人像模式照片（手动深度绘制或估计兜底），否则撞「only applies to a small niche market」 | 二期 |
| 5 | 内置示例素材包（首启动即有内容） | **一期** |
| 6 | 多预设/风格 + 批量处理 | 二期 |

**反面清单**（占两项以上 = 高危）：单屏 app、无导出、无素材库、无编辑参数。

---

## 六、设备兼容性声明

### 6.1 不加任何硬件相关键

`UIRequiredDeviceCapabilities` 官方全表：`accelerometer, arkit, armv6, armv7, arm64, arm64e, auto-focus-camera, bluetooth-le, camera-flash, driverkit, embedded-web-browser-engine, front-facing-camera, gamekit, gps, gyroscope, healthkit, ipad-minimum-performance-m1, iphone-ipad-minimum-performance-a12, iphone-performance-gaming-tier, location-services, magnetometer, metal, microphone, nfc, opengles-1, opengles-2, opengles-3, peer-peer, sms, still-camera, telephony, video-camera, web-browser-engine, wifi`

来源：<https://developer.apple.com/support/required-device-capabilities/>

**关键事实：全表中不存在任何 TrueDepth / 深度相机 / 人脸追踪相关的键。** `arkit` 指后置世界追踪兼容性；`front-facing-camera` 只表示「有前摄」。**两者都不能当 TrueDepth 的代理。**

官方推荐做法（对人脸追踪 app **点名**）：

> "**If your app uses face-tracking AR:** Face tracking requires the front-facing TrueDepth camera on iPhone X. **Your app remains available on other devices, so you must test the `ARFaceTrackingConfiguration.isSupported` property** to determine face-tracking support on the current device."

来源：<https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission>

`UIRequiredDeviceCapabilities` 官方 Discussion：

> "**Specify only the features that your app absolutely requires.** If your app can accommodate missing features by avoiding the code paths that use those features, don't include the corresponding key."
> **Important**: "For app updates, **you can only maintain or relax capability requirements.**"

来源：<https://developer.apple.com/documentation/bundleresources/information-property-list/uirequireddevicecapabilities>

**→ 决策：一个硬件键都不加。** 这是单向门，加了不可逆。
**特别不要加 `iphone-ipad-minimum-performance-a12`** —— iPhone X 是 A11 + TrueDepth，在 iOS 13 及更早版本上**支持**人脸追踪，该键会误杀它。

### 6.2 不支持时的表现（硬性要求）

> "**Check the `isSupported` property before offering AR features in your app's UI, so that users on unsupported devices aren't disappointed by trying to access those features.**"

来源同上。

**→ 不支持时入口不暴露**（隐藏或明确置灰并说明），绝不能点进去黑屏、空转或崩溃（崩溃走 2.1 App Completeness，占未解决问题的 40%+）。

---

## 七、审核实测风险与官方通道

### 7.1 官方对审核环境的唯一表述

> "**App Review evaluates apps the way your users will use them: installed on real devices and connected to networks with real-world conditions.** Make sure your pre-submission testing includes running the app on each device platform where it could be used."

> "**Connecting to hardware?** Attach a video, **not a screen recording**, that shows both the hardware and the app running on a physical Apple device as they pair and interact."

来源：Apple Staff「App Review」官方账号 <https://developer.apple.com/forums/thread/810791>

### 7.2 官方支持的补充材料通道

App Store Connect 区块名为 **App Review Information**，字段：

- **Contact**（必填）
- **Sign-In Required**（仅当需要登录 —— 本项目无）
- **Notes**（可选）：「Additional information about your app that can help during the review process. **Include information that may be needed to test your app, such as app-specific settings**」，上限 **4000 bytes**，**可用任意语言（可写中文）**
- **Attachment**：「attach the files in the **Attachment** section in App Store Connect and provide any descriptions or links in the **Review Notes** field.」

来源：<https://developer.apple.com/help/app-store-connect/reference/app-review-information/>、<https://developer.apple.com/distribute/app-review/>

ASC API 对应资源逐字：

> "Use an `appReviewAttachments` resource to upload specific app documentation, **demo videos**, and other items to App Store Connect, **to help prevent delays during the app review process.**"

来源：<https://developer.apple.com/documentation/appstoreconnectapi/app-store-review-attachments>

### 7.3 官方对「难以复现的环境」的指引

> "If some features require signing in, provide a valid demo account… **If features require an environment that is hard to replicate or require specific hardware, be prepared to provide a demo video or the hardware.**"

来源：<https://developer.apple.com/distribute/app-review/>

> ⚠️ **2.1(a) 的 built-in demo mode 条款不适用于本项目**：它的前提是「unable to provide a demo account **due to legal or security obligations**」且需「**prior approval by Apple**」。那是「没法给账号」的例外通道，不是「效果不好演示」的挡箭牌。本项目无登录。

---

## 八、风险登记

| # | 风险 | 依据性质 | 缓解措施 |
|---|---|---|---|
| R1 | 审核员未做头部移动 → 判定「无功能」 | 经验判断 | `idle` 自动摆动首屏 + 陀螺仪 fallback + 人脸检测状态指示 + Notes 写操作步骤 + Attachment 实拍视频 |
| R2 | 审核机型不支持人脸追踪 → 只看到降级界面 | 经验判断（官方未公开机型池） | **降级路径本身必须是完整可玩的体验**（示例照片 + 陀螺仪视差），不是「你的设备不支持」死胡同 |
| R3 | 被套 4.2.1「merely dropping a model into an AR view」 | **官方明文** | 靠编辑/导出/素材库/批量的功能广度撑住（见 §5.3） |
| R4 | 4.3(b) 与已有 3D 照片 app 无差异 | **官方明文** | 差异点写进 Notes 与商店文案 |
| R5 | 用户相册照片无深度图 → 大量「打不开」 | 经验判断 | 深度缺失不报错，给出可行动的下一步；PHPicker 用 `depthEffectPhotosFilter` 从源头筛选 |
| R6 | 用 `UIRequiredDeviceCapabilities` 限装后无法回退 | **官方明文**（"can only maintain or relax"） | 一开始就不加硬件键 |
| R7 | 崩溃/空屏 → 2.1 App Completeness | **官方明文** | `isSupported` 提前判断并隐藏入口；全链路降级 |
| R8 | 隐私政策只填 ASC 字段、app 内无入口 | **官方明文** 5.1.1(i) | 设置页固定入口；上架前自查两处 |
| R9 | 隐私政策没写人脸追踪段落 | **官方明文**（ARKit 文档） | 政策中单列「Face tracking」小节 |
| R10 | 问卷答「不收集」但工程残留网络库 | ASC 提交准确性声明 | **CI 断言：无 `URLSession` 引用、无第三方依赖**；上架前抓包空跑验证 |
| R11 | 漏声明 `SystemBootTime`（帧计时） | **官方明文**（2024-05-01 起 ASC 直接不收包） | 提交前 grep `mach_absolute_time\|systemUptime\|UserDefaults\|volumeAvailableCapacity\|creationDate` 对照 §3.2 五张表 |
| R12 | privacy manifest 含非法键值 → ASC 直接拒收 | **官方明文** | 用 Xcode App Privacy File 模板 + Product > Archive > Generate Privacy Report 自检 |
| R13 | 误加 `NSFaceIDUsageDescription` 或做门禁式交互 | **官方明文** 2.5.13 | 代码评审检查项 |
| R14 | purpose string 写成「for a better experience」 | HIG 反例逐字命中 | 用 §2 给定文案 |
| R15 | 后续加云功能沿用旧问卷答案 | 5.1.2(ii) + ASC "promptly update" 承诺 | **写死规则**：任何新增出网能力 → 同步改 ASC 问卷 + 隐私政策 + privacy manifest |

---

## 九、提交前检查清单

- [ ] `NSCameraUsageDescription` 已填，用 §2 的句式，已本地化
- [ ] 未添加 `NSFaceIDUsageDescription`
- [ ] `UIRequiredDeviceCapabilities` 中无任何硬件键
- [ ] `PrivacyInfo.xcprivacy` 存在于 bundle 根，四个顶层键齐全
- [ ] Generate Privacy Report 通过
- [ ] grep 核对 required reason API（R11 的命令）
- [ ] 隐私政策 URL 已填 ASC 元数据
- [ ] 隐私政策在 app 内设置页有可点击入口
- [ ] 隐私政策含「Face tracking」专门小节，写明三句话（§1.4）
- [ ] ASC 隐私问卷答「不收集」，且四项前提逐条核实为真
- [ ] CI 断言通过：零网络调用、零第三方 SDK
- [ ] `ARFaceTrackingConfiguration.isSupported == false` 的机型上入口正确隐藏，无崩溃无空屏
- [ ] 不给相机权限时仍能完整体验（陀螺仪 + idle）
- [ ] App Review Notes 写明：概念与差异点、操作方法（「打开示例照片后左右移动头部约 10–20cm」）、设备要求与降级说明
- [ ] Attachment 上传**第三方视角实拍**演示视频（同框拍到人头在动 + 屏幕画面在变；纯屏幕录制看不出头在动，等于没证明核心玩法 —— **此建议属经验判断**，类比自官方「连接硬件要拍实拍视频」的要求）
- [ ] 在每一类目标机型上真机跑通

---

## 十、变更记录

| 日期 | 变更 |
|---|---|
| 2026-08-10 | 初版。基于官方页面核实，含 15 项风险登记与提交前检查清单。 |
