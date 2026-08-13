#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 projection;   // 离轴投影矩阵，由 ParallaxCore 在 CPU 侧算好
    float parallaxScale;   // 归一化深度差 → 米，艺术参数
    float zeroParallax;    // 零视差面所在的归一化深度
    // 网格（=贴图内容）在屏幕坐标系里的物理宽高，米。
    // **不是** ScreenGeometry.width/height 本身，是 ContentFitting.fillSize(...)
    // 按内容真实宽高比算出来的「铺满」尺寸——两者只在内容宽高比恰好等于屏幕
    // 宽高比时相等；照片宽高比对不上屏幕时，这里会比屏幕物理尺寸大一圈，
    // 溢出部分由下面 projection 对应的离轴视锥（仍按屏幕真实物理尺寸算）
    // 自动裁掉，而不是把内容拉伸变形去凑屏幕形状。
    float2 screenSize;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// ⚠️ Plan 4 两层渲染的前提：颜色、深度、遮罩三张纹理必须共用同一套 UV
// 采样约定，否则三者网格对不齐，表现为"遮罩比人物偏了一点"——看得见却
// 说不清的错误（ParallaxCore 的 MaskResampling 类型注释原话）。
// 这里的 sampler 是 pixel-center（隐式，Metal `sampler` 的默认行为）+
// clamp_to_edge，跟 ParallaxCore 侧 MaskResampling 用的 pixel-center 对齐
// 公式 `(index+0.5)*scale-0.5` 是同一套约定。本文件的 parallaxVertex（采样
// depthTex）、parallaxFragment（采样 colorTex）、parallaxFragmentMasked
// （采样 colorTex 与 maskTex）三个函数各自新建 sampler 实例，但用的都是这
// 同一组 (filter::linear, address::clamp_to_edge) 参数——没有任何一处偏离。
//
// 网格顶点按深度图位移：深度大（近）的顶点朝观察者凸出。
// 位移量 z = (d − zeroParallax) * parallaxScale，与 spec 术语表一致。
vertex VertexOut parallaxVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]],
                                texture2d<float> depthTex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = grid[vid];

    float d = depthTex.sample(s, uv).r;
    float z = (d - u.zeroParallax) * u.parallaxScale;

    // 网格铺满 u.screenSize 描述的那个矩形（含义见上方字段注释，不一定等于
    // 屏幕本身）：uv[0,1] → 屏幕坐标系 [-w/2, w/2] × [-h/2, h/2]。
    // OffAxisProjection.matrix 在 CPU 侧用 screen.width/height（米，屏幕真实
    // 物理尺寸）与 eye.x/y（同样是米）算 frustum 边界，顶点位置必须落在同一套
    // 物理单位里，否则四角映射到 NDC(±1,±1) 这条投影矩阵的核心保证就对不上
    // 顶点几何——光乘 (1,-1) 只给出 [-0.5,0.5] 的无量纲范围，所以要再乘物理尺寸。
    float2 xy = (uv - 0.5) * float2(1.0, -1.0) * u.screenSize;

    VertexOut out;
    out.position = u.projection * float4(xy, z, 1.0);
    out.uv = uv;
    return out;
}

// 单层路径 / 两层模式的背景层：正常采样，不 discard、alpha 恒为 1
// （`.rgba8Unorm`/`.bgra8Unorm` 的 alpha 通道本就固定不透明，见
// ParallaxRenderer.rgba8Pixels 的字节序注释）——`ParallaxRenderer` 建这条
// 管线时没开混合，这里返回的 alpha 分量实际上不参与合成。
fragment float4 parallaxFragment(VertexOut in [[stage_in]],
                                 texture2d<float> colorTex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return colorTex.sample(s, in.uv);
}

// 两层模式的前景层专用：遮罩控制 discard + 边缘羽化。
//
// kMaskLow/kMaskHigh 定义一条窄的过渡带：原始遮罩值低于 kMaskLow 的片元
// 整个丢弃（discard_fragment()——不写颜色也不写深度，已经画好的背景层原样
// 透出）；落在 [kMaskLow, kMaskHigh] 之间的用 smoothstep 算一个渐变 alpha，
// 与 ParallaxRenderer 开的 source-over 混合一起，跟背景层做柔和过渡；
// 高于 kMaskHigh 的 alpha 钳到 1，等价于完全不透明。没有这条过渡带，遮罩
// 从 0 跳到 1 那一圈会是硬边剪影——跟本计划要根治的锯齿是同一种"边缘生硬"
// 的视觉症状，只是成因不同（那是几何，这是遮罩边缘本身没有过渡）。
//
// 阈值是没有断言能验证的肉眼参数，跟 ParallaxRenderer.parallaxScale /
// zeroParallax 同一类——±0.08 是起点，真机如果觉得边缘发糊或者还留着硬边，
// 调这两个常量，不用改结构。跟 BackgroundInpainting.fill 的默认
// threshold=0.5（ParallaxRenderer.maskHoleThreshold）保持中心对齐：CPU 侧
// "从这个值起视为洞"与 GPU 侧"从这个值起开始显现"是同一条边界。
constant float kMaskLow = 0.42;
constant float kMaskHigh = 0.58;

fragment float4 parallaxFragmentMasked(VertexOut in [[stage_in]],
                                       texture2d<float> colorTex [[texture(0)]],
                                       texture2d<float> maskTex [[texture(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float m = maskTex.sample(s, in.uv).r;
    if (m < kMaskLow) {
        discard_fragment();
    }
    float alpha = smoothstep(kMaskLow, kMaskHigh, m);
    float4 color = colorTex.sample(s, in.uv);
    return float4(color.rgb, alpha);
}
