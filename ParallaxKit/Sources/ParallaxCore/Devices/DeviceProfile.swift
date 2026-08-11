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
