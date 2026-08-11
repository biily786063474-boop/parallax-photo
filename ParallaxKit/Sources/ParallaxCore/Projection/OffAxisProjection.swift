import Foundation
import simd

/// 离轴（非对称视锥）透视投影。
///
/// 这是「窗口」与「贴纸」的分水岭：简单平移只让画面滑动，
/// 离轴投影会让你把手机往左移时**多看到物体的右侧面**。
///
/// 算法是 Kooima 广义透视投影在「屏幕位于 z = 0 平面、基向量为标准正交基」
/// 这一情形下的特化，因此屏幕基旋转矩阵恒为单位阵，只剩视锥 + 平移。
///
/// 输出面向 Metal：NDC 的 z 范围是 [0, 1]，近平面 → 0，远平面 → 1。
public enum OffAxisProjection {

    public static func matrix(
        eye: SIMD3<Float>,
        screen: ScreenGeometry,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        // 眼到屏幕平面的垂直距离。屏幕在 z = 0，Z 轴指向用户，所以就是 eye.z。
        // 退化保护：眼位贴到甚至穿过屏幕平面时，钳到一个极小正值，
        // 宁可给出一个无意义但有限的矩阵，也不要让 NaN 流进渲染管线。
        let distance = max(eye.z, 1e-4)

        let scale = near / distance
        let left   = (-screen.width  / 2 - eye.x) * scale
        let right  = ( screen.width  / 2 - eye.x) * scale
        let bottom = (-screen.height / 2 - eye.y) * scale
        let top    = ( screen.height / 2 - eye.y) * scale

        let frustum = makeFrustum(
            left: left, right: right, bottom: bottom, top: top, near: near, far: far
        )
        let translation = makeTranslation(-eye)
        return frustum * translation
    }

    /// 右手系视锥矩阵，深度输出到 [0, 1]（Metal 约定）。
    private static func makeFrustum(
        left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float
    ) -> simd_float4x4 {
        let width = right - left
        let height = top - bottom
        let depth = near - far

        // 全部除数都做退化保护，理由同上：有限的错值远好过 NaN。
        let safeWidth = abs(width) > 1e-9 ? width : 1e-9
        let safeHeight = abs(height) > 1e-9 ? height : 1e-9
        let safeDepth = abs(depth) > 1e-9 ? depth : -1e-9

        return simd_float4x4(
            SIMD4(2 * near / safeWidth, 0, 0, 0),
            SIMD4(0, 2 * near / safeHeight, 0, 0),
            SIMD4(
                (right + left) / safeWidth,
                (top + bottom) / safeHeight,
                far / safeDepth,
                -1
            ),
            SIMD4(0, 0, near * far / safeDepth, 0)
        )
    }

    private static func makeTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }
}
