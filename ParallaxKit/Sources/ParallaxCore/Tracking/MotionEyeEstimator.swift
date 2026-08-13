import Foundation
import simd

/// 陀螺仪降级层：把设备姿态变化换算成观察者的等效位移增量。
///
/// 见 spec §9.1，四级降级链的第二级（`faceTracking` → **`motion`** → `idle` → `manual`）。
/// 陀螺仪不知道观察者在哪，但设备转动 θ 等价于观察者绕设备转了 −θ——转手机和动头
/// 在几何上等价。假定观察者停留在 `distance` 处的球面上，把姿态变化映射成球面位移，
/// 调用方把返回的增量叠加到"追踪丢失那一刻"的最后已知眼位上（不是绝对位置）。
///
/// ## 推导（方向约定，改这个文件前先看这里）
///
/// `simd_quatf` 的组合遵循 `(p * q).act(v) == p.act(q.act(v))`：先作用 `q` 再作用 `p`，
/// 与矩阵乘法顺序一致。屏幕坐标系见 `ScreenGeometry`：原点为显示区中心，X 向右、
/// Y 向上、Z 指向观察者，右手系。
///
/// `delta = current * reference.inverse` 是标准的"世界系下的相对旋转"公式：它是这样
/// 一个旋转——把设备在 reference 时刻的姿态搬到 current 时刻的姿态。用 Rodrigues
/// 公式可以验证：`simd_quatf(angle: θ, axis: [0,1,0])`（θ>0）把 +Z 轴（设备前向，
/// 指向观察者）转向设备自身的 +X——这正是"设备向右转"（绕竖直轴向右转，类似摇头
/// 看向右边）。
///
/// 观察者相对设备的运动与设备旋转方向相反（设备转的是自己，观察者在世界里没动，
/// 只是"看起来"绕设备转了反方向），所以作用在参考位置上的是**缩放后旋转的逆**，
/// 不是它本身。取 reference = 单位元、current = 上述"向右转" θ、sensitivity = 1：
/// delta = current，缩放后仍是 current，作用的是 `current.inverse`，即把参考位置
/// `(0,0,distance)` 绕 Y 轴转 `−θ`。代入 Rodrigues 公式：
/// `x' = distance·sin(−θ)`，θ>0 时 `x' < 0`——与"设备向右转 → 观察者等效在左侧 →
/// x 为负"一致。
///
/// 同样方法验证绕 X 轴：`simd_quatf(angle: θ, axis: [1,0,0])`（θ>0）把屏幕法线 +Z
/// 转向 −Y（顶部后仰、远离观察者，法线转为朝下）。同样代入 `−θ`，
/// `y' = distance·sin(θ) > 0`——顶部后仰时观察者等效位置在上方。
///
/// 两条方向都在 `MotionEyeEstimatorTests` 里锁定，回归时方向反了会立刻测试变红。
///
/// ## 已知近似：旋转中心
///
/// CoreMotion 的 `attitude` 只有姿态（朝向），没有位置——上面的推导因此隐含
/// 假设"设备绕屏幕坐标系原点转动"。物理上并非如此：人转动的是手腕/手肘，
/// 真正的旋转中心离屏幕坐标原点有几厘米偏移，且这个偏移量因人、因持机
/// 姿势而异。`sensitivity` 缩放的是旋转角度本身，**不是**这个中心偏移，
/// 两者是完全不同的误差来源。
///
/// 如果真机验收时把 `sensitivity` 定在几何真值 1.0（`ParallaxApp` 固定传
/// 这个值，不开放成参数——见 `PoseController.motionSensitivity`），`motion`
/// 换算出的速率仍然和 `faceTracking` 对不上，**先怀疑这里**：正确的修法是
/// 把旋转中心显式建模进来（比如给 `offset` 增加一个"设备原点相对旋转中心
/// 的偏移量"参数，或者假设一个手腕到屏幕中心的固定距离去补偿），而不是
/// 回头再给 `sensitivity` 调一个缩放系数糊过去——1.0 已经是这个参数能给出
/// 的唯一正确值，继续在它上面找补，只是把模型的偏差伪装成"调对了"。
public enum MotionEyeEstimator {

    /// 设备姿态变化换算成观察者的等效位移增量。
    ///
    /// - Parameters:
    ///   - reference: 参考姿态，通常是"追踪丢失那一刻"的设备姿态。
    ///   - current: 当前设备姿态。
    ///   - distance: 假定的观察距离，米。非正数或非有限数安全返回零向量。
    ///   - sensitivity: 旋转量缩放系数，见类型文档。`<= 0` 时恒为零向量；
    ///     不做上限裁剪——调用方想要"超线性"的夸张效果时可以传大于 1 的值。
    ///     默认值 1.0——不是猜出来的初始值，是算出来的唯一正确值：不缩放，
    ///     直接用几何真值，与 `faceTracking`（ARKit 实测眼位，严格 1:1）是
    ///     同一把尺子（推导见下方实现里的注释；已知局限见上方"已知近似：
    ///     旋转中心"）。调用方（`ParallaxApp`）固定传 1.0，不开放成真机可调
    ///     参数——速率不是口味问题，算不准是模型的问题，不是留给用户微调的
    ///     余量。
    /// - Returns: 相对参考姿态的位移增量。`reference == current` 时**精确**为零向量
    ///   （不依赖浮点运算恰好抵消，直接短路返回，见下方实现），因为这是接管瞬间
    ///   不产生跳变的核心契约。
    public static func offset(
        from reference: simd_quatf,
        to current: simd_quatf,
        distance: Float,
        sensitivity: Float = 1.0
    ) -> SIMD3<Float> {
        guard distance.isFinite, distance > 0 else { return .zero }
        guard sensitivity.isFinite else { return .zero }
        guard isFinite(reference.vector), isFinite(current.vector) else { return .zero }

        // 接管瞬间参考与当前完全一致：直接短路返回精确零向量。不能指望
        // `current * reference.inverse` 之后再乘回去恰好在浮点上抵消为零——
        // 四元数求逆要除以模长平方，即使输入已归一化也不保证 bit-exact 抵消。
        if reference.vector == current.vector { return .zero }

        // 退化（长度接近零）四元数无法安全归一化，直接返回零而不是让除法产生 NaN/Inf。
        let referenceLengthSquared = simd_length_squared(reference.vector)
        let currentLengthSquared = simd_length_squared(current.vector)
        guard referenceLengthSquared > 1e-12, currentLengthSquared > 1e-12 else { return .zero }

        let normalizedReference = simd_quatf(vector: reference.vector * (1 / referenceLengthSquared.squareRoot()))
        let normalizedCurrent = simd_quatf(vector: current.vector * (1 / currentLengthSquared.squareRoot()))

        // 相对旋转：设备从 reference 转到 current 的姿态变化，世界系下的标准公式。
        let delta = normalizedCurrent * normalizedReference.inverse

        // sensitivity 缩放旋转量。默认 1.0，即不缩放：设备转动换算出的观察者
        // 等效位移直接按几何真值给，与 faceTracking（ARKit 实测眼位，严格 1:1）
        // 是同一把尺子。曾经默认给 0.5，理由是"手机转动幅度远大于头部移动，
        // 1:1 会让视差夸张"——这是没有真机依据的主观猜测，真机反馈"陀螺仪速率
        // 和面部追踪没保持一致"证明它站不住：两个源用不同尺度换算位移，源切换
        // 时能感觉到速率断层。轴选 +Z 只是占位——angle 为 0 时轴不影响结果。
        let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        let scaledDelta = simd_slerp(identity, delta, sensitivity)

        // 观察者相对设备的运动与设备旋转方向相反，作用在参考位置上的是逆旋转。
        let anchor = SIMD3<Float>(0, 0, distance)
        let newPosition = scaledDelta.inverse.act(anchor)
        let result = newPosition - anchor

        guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return .zero }
        return result
    }

    private static func isFinite(_ v: SIMD4<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite
    }
}
