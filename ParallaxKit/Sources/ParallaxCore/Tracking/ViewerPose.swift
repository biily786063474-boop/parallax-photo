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
