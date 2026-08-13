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

fragment float4 parallaxFragment(VertexOut in [[stage_in]],
                                 texture2d<float> colorTex [[texture(0)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return colorTex.sample(s, in.uv);
}
