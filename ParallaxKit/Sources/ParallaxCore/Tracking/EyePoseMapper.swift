import Foundation
import simd

/// 把 ARKit 相机空间的眼位换算到屏幕坐标系。
///
/// 这是 spec §6 步骤 [3]，整条链路唯一一处把真机实测事实落地成代码的地方。
///
/// 推导（这里改错过一次，别凭直觉动）：
/// ```
/// cameraOffset ≡ 摄像头在屏幕坐标系中的位置 = camera − center
/// 要求的是                                    eye − center
/// eye − center = (eye − camera) + (camera − center)
///              = flipZ(cameraSpaceEye) + cameraOffset
/// ```
///
/// Z 翻转的依据是真机实测（`docs/api-facts-arkit-depth.md` §6.2 探针 P12）：
/// 相机空间眼位 Z 为负（用户在相机看向的 −Z 侧），而屏幕坐标系 Z 指向用户。
public enum EyePoseMapper {

    public static func screenSpaceEye(
        cameraSpaceEye: SIMD3<Float>,
        screen: ScreenGeometry
    ) -> SIMD3<Float> {
        // 非有限输入直接归零，绝不让 NaN 流进投影矩阵——
        // 一个 NaN 能让整帧画面消失，且在设备上极难定位来源。
        let safe = SIMD3<Float>(
            cameraSpaceEye.x.isFinite ? cameraSpaceEye.x : 0,
            cameraSpaceEye.y.isFinite ? cameraSpaceEye.y : 0,
            cameraSpaceEye.z.isFinite ? cameraSpaceEye.z : 0
        )
        let flipped = SIMD3<Float>(safe.x, safe.y, -safe.z)
        return flipped + screen.cameraOffset
    }
}
