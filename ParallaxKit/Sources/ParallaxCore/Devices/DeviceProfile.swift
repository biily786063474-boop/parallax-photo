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

    /// iPhone 14 Pro Max
    ///
    /// **数据等级：显示区 A（图纸直读），摄像头偏移 C（图纸只给包络，X 无法确定）。**
    /// 来源：<https://developer.apple.com/accessories/dimensional-drawings/> 的
    /// `iphone-14-pro-max.pdf`。
    ///
    /// 图纸能确定的：
    /// - PRODUCT WIDTH 77.58 mm，**DISPLAY ACTIVE AREA 71.21 mm**
    /// - 「3.19 ALL AROUND: EXTERIOR OF HOUSING TO DISPLAY ACTIVE AREA」
    ///   → 77.58 − 2×3.19 = 71.20 ≈ 71.21，**显示区严格居中于产品外形**
    /// - 「2X 38.79」= 产品半宽 → **灵动岛在宽度方向严格居中**
    /// - 灵动岛上缘距产品顶边 6.07 mm，包络宽 20.76 mm
    ///
    /// 图纸**不能**确定的：**摄像头在那 20.76 mm 包络里的横向位置**。
    /// 灵动岛是「胶囊 + 圆点」两个开孔，圆点才是可见光摄像头，但图纸只画合并包络。
    ///
    /// 因此 x 取 **0**（居中）而非猜一个方向。理由是误差量级对比：
    /// 填 0 的最大误差约 ±8mm；猜错方向则是 16mm，还外加「看起来像标定不准、
    /// 实为系统性反向」这种最难排查的故障形态。
    /// 另据 TechInsights 拆解，可见光摄像头的左右在 iPhone 13 一代翻过面
    /// （X~12 在刘海右侧，13 起在左侧），按单一方向硬编码全系必然有一半是反的。
    ///
    /// y 由图纸 6.07（灵动岛上缘距产品顶边）− 3.19（显示区边距）+ 灵动岛半高估计
    /// 推得摄像头距显示区顶边约 6.4mm。**含估算成分**，故 isCalibrated 仍为 false。
    public static let iPhone14ProMax = DeviceProfile(
        identifier: "iPhone15,3",
        displayName: "iPhone 14 Pro Max",
        screen: ScreenGeometry(
            width: 0.07121,
            height: 0.15439,
            cameraOffset: SIMD3(0, 0.15439 / 2 - 0.0064, 0)
        ),
        isCalibrated: false
    )

    /// iPad Pro 11 英寸（M4）
    ///
    /// **数据等级 A：官方工程图纸直读，±0.2mm。**
    /// 来源：<https://developer.apple.com/accessories/dimensional-drawings/> 的
    /// `ipad-pro-11-inch-m4.pdf`（免登录可下），DETAIL F 与正视图纵坐标链。
    ///
    /// 图纸原始读数：
    /// - 产品外形 249.70 × 177.51 mm
    /// - DISPLAY ACTIVE AREA **232.32 × 160.13 mm**（注意：按 2420×1668 @264ppi 算是
    ///   232.83 × 160.48，差 0.5mm。ppi 是取整值，**以图纸为准**）
    /// - 前置器件距产品边 4.71 mm（图纸标 "8X 4.71"）
    /// - FCAM 纵坐标 124.85 = 249.70/2，**正落在产品中心线上**
    ///
    /// 摄像头偏移推导（显示区严格居中于产品外形，图纸四角边距相等已验证）：
    /// - x = 177.51/2 − 4.71 = **84.045 mm**，在**右侧**长边
    /// - y = 0（沿长边居中）
    ///
    /// 与 Apple 用户手册图注互证：「the front camera and microphone at the **center right**」。
    public static let iPadPro11M4 = DeviceProfile(
        identifier: "iPad16,4",
        displayName: "iPad Pro 11-inch (M4)",
        screen: ScreenGeometry(
            width: 0.16013,
            height: 0.23232,
            cameraOffset: SIMD3(0.084045, 0, 0)
        ),
        isCalibrated: true
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
