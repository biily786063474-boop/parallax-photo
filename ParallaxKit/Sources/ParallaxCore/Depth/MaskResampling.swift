import Foundation

/// 把遮罩从一个分辨率重采样到另一个分辨率。
///
/// 背景：Vision 的 `generateScaledMaskForImage` 输出等于**原图**分辨率，
/// 而深度图是另一个分辨率——真机实测 iPad 前摄给的深度图是 640×480，
/// 相册照片的深度图通常也远小于彩色图。颜色、深度、遮罩三者要在同一套
/// 网格上采样，就必须先把遮罩重采样到目标网格的尺寸，三者的尺寸关系
/// 因此必须在这一层理清，不能留给上层各自假设。
///
/// 用双线性而不是最近邻：最近邻重采样只是把同一个像素值原样复制到多个
/// 输出像素，遮罩边界会呈现和原分辨率成正比的阶梯；双线性给出连续渐变
/// 的过渡值，才配得上「遮罩」这种本该是软边界的数据。
public enum MaskResampling {

    public static func resample(
        mask: [Float],
        from: (width: Int, height: Int),
        to: (width: Int, height: Int)
    ) -> [Float]? {
        guard from.width > 0, from.height > 0, to.width > 0, to.height > 0 else { return nil }
        guard mask.count == from.width * from.height else { return nil }

        // 出口保证：不管输入多脏，输出永远有限且落在 [0,1]。
        // NaN 在这里就地清零，不留给下游的双线性插值去传播污染。
        let sanitized = mask.map { $0.isFinite ? min(max($0, 0), 1) : 0 }

        guard from.width != to.width || from.height != to.height else {
            return sanitized
        }

        let scaleX = Float(from.width) / Float(to.width)
        let scaleY = Float(from.height) / Float(to.height)

        var out = [Float](repeating: 0, count: to.width * to.height)
        for oy in 0..<to.height {
            // pixel-center 对齐：目标像素中心 (oy+0.5) 按比例缩放回源坐标系再减 0.5。
            // 这个约定保证放大时最外圈像素的采样坐标会越界，从而被下面的
            // clamp-to-edge 精确夹回边界像素，四角与原图分毫不差。
            let srcY = (Float(oy) + 0.5) * scaleY - 0.5
            for ox in 0..<to.width {
                let srcX = (Float(ox) + 0.5) * scaleX - 0.5
                out[oy * to.width + ox] = bilinearSample(
                    sanitized, width: from.width, height: from.height, x: srcX, y: srcY
                )
            }
        }
        return out
    }

    /// clamp-to-edge 双线性采样。`values` 已保证有限且在 [0,1] 内，
    /// 这里只需要防住加权求和本身的浮点误差把结果推出边界。
    private static func bilinearSample(
        _ values: [Float], width: Int, height: Int, x: Float, y: Float
    ) -> Float {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx.rounded(.down))
        let y0 = Int(cy.rounded(.down))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0)
        let fy = cy - Float(y0)

        let v00 = values[y0 * width + x0]
        let v10 = values[y0 * width + x1]
        let v01 = values[y1 * width + x0]
        let v11 = values[y1 * width + x1]

        let top = v00 * (1 - fx) + v10 * fx
        let bottom = v01 * (1 - fx) + v11 * fx
        let value = top * (1 - fy) + bottom * fy
        return min(max(value, 0), 1)
    }
}
