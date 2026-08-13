import Foundation
import simd

/// 内容（照片）相对屏幕物理尺寸的排布策略。
///
/// 问题背景：`Shaders.metal` 里的网格顶点用 `uv → 屏幕物理宽高` 的映射铺满
/// 一个矩形；如果直接把这个矩形定成屏幕本身的宽高，网格的宽高比就被锁死成
/// 屏幕的宽高比。照片的宽高比几乎从不等于屏幕宽高比（竖屏手机约 0.46，
/// 常见照片 4:3/3:2 横向构图接近 0.75），于是照片贴到网格上时被**拉伸**成
/// 屏幕的形状——这正是真机反馈的「图片加载进来的时候有变形」。
public enum ContentFitting {

    /// 按 aspect fill（等价于 CSS `background-size: cover`）计算内容在屏幕
    /// 坐标系中应占的物理尺寸。
    ///
    /// - Parameters:
    ///   - contentAspect: 内容宽高比（宽 / 高）
    ///   - screen: 屏幕几何
    /// - Returns: 内容的物理宽高（米）。至少有一维精确等于屏幕对应维度，
    ///   另一维 ≥ 屏幕对应维度；结果的宽高比恒等于 `contentAspect`。
    ///
    /// **为什么是 fill 而不是 fit：** 头动带来的视差本质是内容相对屏幕平面
    /// 的平移（`OffAxisProjection` 的离轴视锥）。fit（留黑边）会让画面四周
    /// 露出的黑边随头动不断变化大小，比裁切边缘难看得多，而且破坏「这是一扇
    /// 窗户」的错觉。fill 让内容天然比屏幕窗口大一圈，头动时窗口在内容内部
    /// 平移，边缘不会露出黑边——多出来的部分本来就该被裁掉，视锥的四个侧面
    /// （仍然按 `screen` 的物理尺寸算，见 `OffAxisProjection.matrix`）会自动
    /// 完成这次裁剪，这里不需要、也不应该另外做裁剪。
    public static func fillSize(contentAspect: Float, screen: ScreenGeometry) -> SIMD2<Float> {
        // 退化保护：不合法的宽高比（除以零、负数宽高比、NaN/Inf 输入）没有
        // 几何意义，与其让它污染后续的网格顶点位置，不如原样退回屏幕尺寸——
        // 等价于关闭 fill、退回旧的「直接铺满屏幕」行为，仍然有限、仍然能画。
        guard contentAspect.isFinite, contentAspect > 0 else {
            return SIMD2(screen.width, screen.height)
        }

        let screenAspect = screen.width / screen.height

        if contentAspect > screenAspect {
            // 内容比屏幕更「宽」（同样高度下内容更宽，或同样宽度下内容更矮）：
            // 贴合高度，宽度按 contentAspect 撑开，必然 ≥ 屏幕宽度。
            let height = screen.height
            let width = height * contentAspect
            return SIMD2(width, height)
        } else {
            // 内容比屏幕更「窄」（含相等情形）：贴合宽度，高度撑开。
            // 相等时 height 算出来就精确等于 screen.height（浮点误差量级）。
            let width = screen.width
            let height = width / contentAspect
            return SIMD2(width, height)
        }
    }
}
