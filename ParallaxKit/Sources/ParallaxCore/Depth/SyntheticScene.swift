import Foundation

/// 程序化生成的测试素材。
///
/// 为什么不直接用相册照片：视差是否正确，靠「不同深度的内容反向移动」来判断。
/// 程序化素材的深度是已知的分层，一眼能看出哪层该动多少；真实照片的深度图
/// 有噪声有空洞，会把「渲染错了」和「深度图本身就烂」混成一件事。
public enum SyntheticScene {

    /// 竖条纹，每条在深度上分层。
    ///
    /// 头左右移动时，近处条纹相对远处条纹的位移一眼可辨——这是最容易判读的视差检验图案。
    /// 颜色按深度做冷暖渐变，让层次在静止时也看得出来。
    public static func layeredBars(
        width: Int,
        height: Int,
        barCount: Int = 8
    ) -> (color: [UInt8], depth: DepthMap)? {
        guard width > 0, height > 0, barCount > 0 else { return nil }

        var color = [UInt8](repeating: 0, count: width * height * 4)
        var depth = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let bar = (x * barCount) / width
                // 深度在 [0.15, 0.95] 之间分层，避开两端极值——
                // 极值处网格位移最大，容易掩盖中间层的表现
                let t = Float(bar) / Float(max(barCount - 1, 1))
                let d = 0.15 + 0.80 * t
                depth[y * width + x] = d

                // 近处偏暖、远处偏冷，静止时也能看出层次
                let index = (y * width + x) * 4
                color[index + 0] = UInt8(40 + 200 * d)          // R
                color[index + 1] = UInt8(60 + 120 * (1 - d))    // G
                color[index + 2] = UInt8(90 + 160 * (1 - d))    // B
                color[index + 3] = 255                          // A
            }
        }

        guard let map = DepthMap(width: width, height: height, values: depth) else {
            return nil
        }
        return (color, map)
    }
}
