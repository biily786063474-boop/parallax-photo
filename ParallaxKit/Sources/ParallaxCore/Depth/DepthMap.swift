import Foundation

/// 归一化深度图。
///
/// **全项目唯一的深度方向约定：值域 [0, 1]，0 = 最远，1 = 最近。**
///
/// 类型不变量：`values` 保证不含 NaN/Inf，且 `values.count == width * height`。
/// 这个不变量由构造器强制——NaN 进了顶点着色器会污染整条渲染管线，
/// 与其在 GPU 上排查黑洞，不如在这里就拒绝。
public struct DepthMap: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let values: [Float]

    public init?(width: Int, height: Int, values: [Float]) {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    /// 按像素坐标读取。原点在左上角，与图像惯例一致。
    public subscript(x: Int, y: Int) -> Float {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "深度图下标越界")
        return values[y * width + x]
    }
}
