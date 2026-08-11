import Foundation
import simd

/// 设备相对其原生方向的旋转量。
///
/// 刻意不用 `UIInterfaceOrientation`：一来 Core 不许依赖平台框架（尤其是 UIKit），
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
