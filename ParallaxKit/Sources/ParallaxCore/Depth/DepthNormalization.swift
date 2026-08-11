import Foundation

/// 原始深度数据的物理含义。
///
/// 依据 `CVPixelBuffer.h:107-110`：
/// - disparity 单位是 1/米，近大远小
/// - depth 单位是米，近小远大
public enum DepthSourceKind: Sendable {
    case disparity
    case depth
}

/// 把原始深度/视差数据转成归一化 `DepthMap`。
///
/// 这是全项目**唯一**发生深度方向转换的地方。任何其他位置再翻转一次，
/// 结果就是凹凸相反——而那种 bug 在真机上肉眼很难第一时间判断方向。
public enum DepthNormalization {

    /// 全部数据缺失或退化时使用的平面深度值。
    private static let degenerateValue: Float = 0.5

    public static func normalize(
        raw: [Float],
        width: Int,
        height: Int,
        kind: DepthSourceKind,
        percentileClip: Float = 0.02
    ) -> DepthMap? {
        guard width > 0, height > 0, raw.count == width * height else { return nil }

        let finiteValues = raw.filter { $0.isFinite }

        // 一个有效像素都没有：退化成平面，而不是失败。
        // 这种图渲染出来是张平照片，但 app 不该因此崩掉或黑屏。
        guard !finiteValues.isEmpty else {
            return DepthMap(
                width: width, height: height,
                values: [Float](repeating: degenerateValue, count: raw.count)
            )
        }

        let (low, high) = percentileBounds(finiteValues, clip: percentileClip)

        // 动态范围退化（全常量或裁剪后区间塌陷）：同样退化成平面。
        guard high - low > 1e-9 else {
            return DepthMap(
                width: width, height: height,
                values: [Float](repeating: degenerateValue, count: raw.count)
            )
        }

        let span = high - low
        let normalized = raw.map { value -> Float in
            // 缺失像素填成「最远」。填成最近会在画面里凸出一块并不存在的前景，
            // 那比缺一块背景难看得多。
            guard value.isFinite else { return 0 }
            let t = min(max((value - low) / span, 0), 1)
            // disparity 越大越近，直接用；depth 越大越远，翻转。
            return kind == .disparity ? t : 1 - t
        }

        return DepthMap(width: width, height: height, values: normalized)
    }

    /// 取百分位边界，抑制离群点把整体动态范围压扁。
    private static func percentileBounds(
        _ values: [Float], clip: Float
    ) -> (low: Float, high: Float) {
        guard clip > 0, values.count > 2 else {
            return (values.min() ?? 0, values.max() ?? 1)
        }
        let sorted = values.sorted()
        let clampedClip = min(max(clip, 0), 0.49)
        let lowIndex = Int(Float(sorted.count - 1) * clampedClip)
        let highIndex = Int(Float(sorted.count - 1) * (1 - clampedClip))
        return (sorted[lowIndex], sorted[highIndex])
    }
}
