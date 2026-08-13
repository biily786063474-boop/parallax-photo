import Foundation
import Metal
import MetalKit
import CoreGraphics
import simd
import ParallaxCore

/// Metal 渲染器：把 `ParallaxCore` 算好的离轴投影矩阵应用到一张深度位移网格上。
///
/// **本任务的范围**（spec §8 的单层验证版）：一张高密度网格，顶点只在 Z 方向
/// 按深度图位移，不做两层 LDI、不做背景外扩填补——那是效果打磨，本任务只验证
/// 「ARKit 眼位 → 离轴投影 → Metal 上屏」这条链路能不能走通。
///
/// 渲染器本身不碰 ARKit、不做滤波、不认识"降级"这个概念——它只读 `eye`，
/// 谁写这个属性、什么时候写，是 `PoseController` 的职责（见 ParallaxApp.swift）。
/// 这条边界就是 spec §5.2 依赖规则在 App target 内部的延伸：数学与输入解耦。
final class ParallaxRenderer: NSObject, MTKViewDelegate {

    /// 必须与 `MTKView.colorPixelFormat` 一致，由 App 侧的 view 配置读取这个常量。
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// 必须与 `MTKView.depthStencilPixelFormat` 一致。
    static let depthPixelFormat: MTLPixelFormat = .depth32Float

    /// 网格分辨率：256×256 顶点——spec §8.1 两层 LDI 版本用的就是这个密度，
    /// 这里直接对齐。
    ///
    /// **真机反馈"锯齿严重"，从 128 提到 256 只是缓解，不是根治。** MSAA（见
    /// `sampleCount`）平滑的是多边形边缘的光栅化锯齿；真机上明显的锯齿来自
    /// 几何本身——128×128 网格铺满全屏后每个三角形横跨十几个像素，人像照片在
    /// 轮廓处深度剧烈跳变，相邻顶点被推到差异很大的 z，三角形被拉成陡峭斜面，
    /// 边缘就成了肉眼可见的阶梯，MSAA 对"网格本身就是阶梯状"无能为力。加密到
    /// 256×256（顶点数 1.6 万→6.5 万，A16 毫无压力）让阶梯更密、更不易察觉，
    /// 但阶梯的本质没有消失。真正的根治是 spec §8.1 描述的深度突变处按边缘遮罩
    /// 剔除三角形 + matte alpha 羽化——那是独立的一大块工作，不在这次范围内。
    private static let gridResolution = 256
    /// 程序化素材的像素尺寸。不必与网格分辨率一致——采样是双线性插值的连续函数。
    private static let sceneSize = 256

    private static let near: Float = 0.01
    private static let far: Float = 10.0

    /// 外部（`PoseController`：ARKit 回调或 idle 生成器）每帧写入的屏幕空间眼位。
    /// 单位米，坐标系见 `ScreenGeometry` 文档（原点=屏幕中心，Z 指向用户）。
    /// 渲染器只读它，不做平滑、不做夹紧——那些都已经在写入前做完了。
    var eye: SIMD3<Float>

    /// 视差强度：归一化深度差 → 米。真机反馈初值 2cm 幅度太小、看不出空间感——
    /// 真实照片归一化后的深度差常只有 0.2~0.4，乘 2cm 实际位移只剩几毫米。
    /// 起点提到 6cm（3 倍），但这终究是要现场调的艺术参数，不猜一个"更大的
    /// 固定值"了事，真正的调节入口是 `PoseController.parallaxScale` 驱动的
    /// 底部滑块（见 ParallaxApp.swift）；这里的初值只是滑块归零前的默认状态。
    var parallaxScale: Float = 0.125
    /// 零视差面所在的归一化深度。初值 0.5（深度中点），来自简报。同样接了
    /// 滑块（`PoseController.zeroParallax`），初值同理只是默认状态。
    var zeroParallax: Float = 0.68

    /// 实际生效的 MSAA 样本数（1 或 4，取决于设备能力）。`pipelineState` 建立时
    /// 用的就是这个值；`MetalViewRepresentable.makeUIView` 必须把它同步到
    /// `MTKView.sampleCount`——两边不一致会在 `draw(in:)` 创建 render command
    /// encoder 时直接崩溃，所以这里公开出去而不是锁在 private 里自己用。
    let sampleCount: Int

    /// MSAA 运行时校验只打一次日志，见 `logMSAAVerificationIfNeeded`。
    /// `draw(in:)` 每帧都跑（60Hz+），这个校验结果在运行期不会变，
    /// 逐帧打印只会刷屏、不会带来新信息。
    private var hasLoggedMSAAVerification = false

    private let screen: ScreenGeometry
    /// Task 3 起需要保留：`updateScene(color:depth:)` 换素材时要用同一个
    /// device 重新建纹理，不能只在 `init` 里用完就丢。
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState

    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int

    /// Task 3 起可替换：启动时是 `SyntheticScene` 建的程序化素材，
    /// `updateScene(color:depth:)` 换成相册照片后指向新纹理。
    /// `draw(in:)` 只管读当前值，不关心它是哪一次换的。
    private var colorTexture: MTLTexture
    private var depthTexture: MTLTexture

    /// 与 `Shaders.metal` 里的 `Uniforms` 逐字段对应，包括顺序。
    ///
    /// 内存布局靠字段顺序 + Swift 的默认对齐规则自然对齐 Metal 端：
    /// `simd_float4x4` 16 字节对齐、64 字节大小，随后两个 `Float`（各 4 字节）、
    /// 再是 `SIMD2<Float>`（8 字节对齐、8 字节大小）——72 已是 8 的倍数，
    /// `screenSize` 紧接着放，不需要额外填充；整个结构体按 16 字节对齐规则
    /// 补齐到 80 字节，与 MSL 里的同名结构体完全一致。这不是巧合，是 Swift 和
    /// C/MSL 对"字段按声明顺序摆放、按最大成员对齐补齐"这条规则的共同遵守；
    /// 只要不重排字段顺序，两侧永远匹配。
    private struct Uniforms {
        var projection: simd_float4x4
        var parallaxScale: Float
        var zeroParallax: Float
        var screenSize: SIMD2<Float>
    }

    /// - Parameters:
    ///   - device: 系统默认 Metal 设备
    ///   - screen: 当前机型的屏幕物理几何，来自 `DeviceProfileRegistry`
    ///
    /// 失败即返回 nil（而不是 `fatalError`）：Metal 资源创建在真实设备上
    /// 几乎不会失败，但没有理由让一次意外的资源分配失败直接崩溃整个 App——
    /// 调用方可以退化成一个不渲染但不崩溃的视图。
    init?(device: MTLDevice, screen: ScreenGeometry) {
        self.screen = screen
        self.device = device
        self.eye = SIMD3(0, 0, 0.35)

        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let grid = Self.makeGrid(resolution: Self.gridResolution, device: device) else {
            return nil
        }
        self.vertexBuffer = grid.vertexBuffer
        self.indexBuffer = grid.indexBuffer
        self.indexCount = grid.indexCount

        // 程序化测试素材：竖条纹按深度分层，头动时近条相对远条的位移一眼可辨。
        // 这是 Task 2 已经写好并测过的生成器，渲染器只管上传，不重新实现它。
        guard let scene = SyntheticScene.layeredBars(width: Self.sceneSize, height: Self.sceneSize) else {
            return nil
        }
        guard let colorTex = Self.makeColorTexture(
            device: device, pixels: scene.color, width: Self.sceneSize, height: Self.sceneSize
        ) else { return nil }
        guard let depthTex = Self.makeDepthTexture(device: device, depth: scene.depth) else {
            return nil
        }
        self.colorTexture = colorTex
        self.depthTexture = depthTex

        // 4x MSAA 抗锯齿：网格边缘（尤其深度突变处的三角形边）在没有多重采样
        // 时锯齿明显（真机反馈②）。`supportsTextureSampleCount` 是设备能力查询，
        // 不是"是否会崩"的赌注——查完就知道，不支持就老老实实退化回 1，
        // 好过赌一个所有 Metal 设备事实上都支持的值然后指望它不崩。
        self.sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1

        guard let pipeline = Self.makePipelineState(device: device, sampleCount: sampleCount) else {
            return nil
        }
        self.pipelineState = pipeline

        // 深度测试开着：off-axis 投影在视差预算的边界附近，近处顶点在屏幕空间
        // 可能与相邻远处顶点的投影发生重叠，深度测试保证近的正确遮住远的，
        // 而不是靠三角形提交顺序侥幸对。
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            return nil
        }
        self.depthStencilState = depthState

        super.init()
    }

    // MARK: - 换素材（Task 3）

    /// 换素材：彩色图 + 深度图各自建新纹理，替换当前正在渲染的一对。
    ///
    /// 任何一步失败都保留原素材不动——延续 `init?` 的"失败即返回而不是崩溃"
    /// 原则，只是运行期已经过了能返回 nil 的阶段，所以改成"不换"：不能让
    /// 一次失败的照片加载把已经在动的画面砸成黑屏。
    ///
    /// `parallaxScale`/`zeroParallax` 本次有意不跟着换图重算：程序化条纹的
    /// 深度是满量程分层，真实照片的深度分布集中得多，两者需要的强度大概率
    /// 不一样，但具体数值是肉眼参数，等真机拿真实照片试出手感后再调，
    /// 不在这里猜。
    ///
    /// - Returns: 是否真的换成了新素材；调用方目前只用它来决定要不要打日志，
    ///   不是必须处理的错误。
    @discardableResult
    func updateScene(color: CGImage, depth: DepthMap) -> Bool {
        guard let newColorTexture = Self.makeColorTexture(device: device, cgImage: color) else {
            print("ParallaxRenderer: 彩色纹理创建失败，保留原素材")
            return false
        }
        guard let newDepthTexture = Self.makeDepthTexture(device: device, depth: depth) else {
            print("ParallaxRenderer: 深度纹理创建失败，保留原素材")
            return false
        }
        colorTexture = newColorTexture
        depthTexture = newDepthTexture
        return true
    }

    // MARK: - 网格与纹理构建

    /// 生成 `resolution × resolution` 的 UV 网格顶点与三角形索引缓冲。
    ///
    /// 顶点只携带 uv（`SIMD2<Float>`）——xy 位置与 z 位移全部在顶点着色器里
    /// 由 uniforms 里的投影矩阵与深度纹理算出，CPU 侧不需要重新计算一遍。
    private static func makeGrid(
        resolution: Int, device: MTLDevice
    ) -> (vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int)? {
        guard resolution >= 2, resolution * resolution <= Int(UInt16.max) + 1 else { return nil }

        var vertices = [SIMD2<Float>]()
        vertices.reserveCapacity(resolution * resolution)
        for row in 0..<resolution {
            for col in 0..<resolution {
                let u = Float(col) / Float(resolution - 1)
                let v = Float(row) / Float(resolution - 1)
                vertices.append(SIMD2(u, v))
            }
        }

        var indices = [UInt16]()
        indices.reserveCapacity((resolution - 1) * (resolution - 1) * 6)
        for row in 0..<(resolution - 1) {
            for col in 0..<(resolution - 1) {
                let topLeft = UInt16(row * resolution + col)
                let topRight = UInt16(row * resolution + col + 1)
                let bottomLeft = UInt16((row + 1) * resolution + col)
                let bottomRight = UInt16((row + 1) * resolution + col + 1)
                // 两个三角形组成一个格子。缠绕方向未刻意指定——
                // 见 draw(in:) 里 cullMode = .none 的说明。
                indices.append(contentsOf: [
                    topLeft, bottomLeft, topRight,
                    topRight, bottomLeft, bottomRight
                ])
            }
        }

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        ) else { return nil }

        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ) else { return nil }

        return (vertexBuffer, indexBuffer, indices.count)
    }

    private static func makeColorTexture(
        device: MTLDevice, pixels: [UInt8], width: Int, height: Int
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = width * 4
        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    /// 从相册照片解出的 `CGImage` 建纹理（Task 3）。
    ///
    /// `CGImage` 自己的 `bytesPerRow` 同样可能有 padding——跟 Task 1 里
    /// `CVPixelBuffer` 是同一类坑，只是这次不用手写反 padding，直接用
    /// `CGContext` 把它重绘到一份自己指定 `bytesPerRow`（= width×4，
    /// 定义上就不会有 padding）的缓冲最省事，再复用上面基于 `[UInt8]`
    /// 的重载上传。
    ///
    /// 字节序：`CGImageAlphaInfo.premultipliedLast` 配 8-bit-per-component
    /// + deviceRGB，在内存里就是 R,G,B,A 顺序——已经用一张纯红 1×1 图在
    /// Mac 上实际跑过验证（不只是编译通过），跟 `.rgba8Unorm` 纹理格式、
    /// `SyntheticScene` 的通道约定完全一致，不需要额外交换红蓝通道。
    private static func makeColorTexture(device: MTLDevice, cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // CGContext 必须在这个闭包内创建并完成绘制：`raw.baseAddress` 只在
        // withUnsafeMutableBytes 的闭包期间保证有效，绘制动作不能挪到外面。
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        return makeColorTexture(device: device, pixels: pixels, width: width, height: height)
    }

    /// depth 用 `.r32Float`——深度值是 `SyntheticScene`/`DepthMap` 已经归一化到
    /// [0,1] 的 `Float`，不需要也不应该量化成 8 位（会在网格位移上产生台阶）。
    private static func makeDepthTexture(device: MTLDevice, depth: DepthMap) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: depth.width, height: depth.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = depth.width * MemoryLayout<Float>.stride
        depth.values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, depth.width, depth.height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    /// 顶点函数用 `[[vertex_id]]` + 手动读取的 `constant` 缓冲，不用
    /// `[[stage_in]]` 顶点属性描述——所以这里不需要 `MTLVertexDescriptor`。
    ///
    /// `rasterSampleCount` 必须与渲染时实际使用的颜色/深度附件的样本数一致
    /// （即 `MTKView.sampleCount`），否则 `makeRenderCommandEncoder` 在运行时
    /// 直接崩溃——两边的样本数统一来自 `init?` 里算好的 `self.sampleCount`，
    /// 这个函数只管照单全收，不重新决定"用不用 MSAA"。
    private static func makePipelineState(device: MTLDevice, sampleCount: Int) -> MTLRenderPipelineState? {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "parallaxVertex"),
              let fragmentFunction = library.makeFunction(name: "parallaxFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.depthAttachmentPixelFormat = depthPixelFormat
        descriptor.rasterSampleCount = sampleCount

        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - MTKViewDelegate

    /// 投影矩阵只依赖屏幕物理尺寸（`ScreenGeometry`，固定）与眼位，
    /// 不依赖 drawable 的像素尺寸——视口缩放由 Metal 按 drawable 尺寸自动处理。
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// 真机上验证 4x MSAA 是否真的生效——"没崩"只能证明 `MTKView.sampleCount`
    /// 与 pipeline 建立时用的 `rasterSampleCount` 彼此一致（不一致会在
    /// `makeRenderCommandEncoder` 直接崩溃，见上面 `makePipelineState` 的注释），
    /// 不能证明这个一致的值确实是 4 而不是设备不支持时退化后的 1。
    ///
    /// `MTLRenderPipelineState` 协议本身不暴露 `rasterSampleCount` 的回读接口
    /// （查过 SDK 里的 MTLRenderPipeline.h：创建后只能设置、不能读回），没法
    /// 直接断言 pipeline 那一侧；这里退而求其次，读运行期真正起作用的信号——
    /// `MTKView.multisampleColorTexture`。按 MTKView.h 原文："If sampleCount is
    /// greater than 1 a multisampled color texture will be created"、
    /// "This will be nil if sampleCount is less than or equal to 1"——它是
    /// MTKView 按当前 sampleCount 懒创建的真实 GPU 纹理，不是我们自己写入又读
    /// 回的配置值，比回读 `view.sampleCount`（那只是配置项本身）更能证明 MSAA
    /// 这一帧确实在起作用。放在 `currentRenderPassDescriptor` 访问之后调用：
    /// 按同一份文档，访问它会顺带把 `multisampleColorTexture` 建出来。
    private func logMSAAVerificationIfNeeded(view: MTKView) {
        guard !hasLoggedMSAAVerification else { return }
        hasLoggedMSAAVerification = true

        let multisampleTexture = view.multisampleColorTexture
        let actualSampleCount = multisampleTexture?.sampleCount ?? 1
        let verdict = actualSampleCount == 4 ? "4x MSAA 确实生效" : "未达到 4x（本机型不支持，或被悄悄改回了 1）"
        print("ParallaxRenderer: MSAA 校验 — renderer.sampleCount(建 pipeline 时用的值)=\(sampleCount)，"
            + "MTKView.sampleCount=\(view.sampleCount)，"
            + "multisampleColorTexture 实际 sampleCount=\(actualSampleCount)（\(verdict)）")
        fflush(stdout)
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else { return }

        logMSAAVerificationIfNeeded(view: view)

        let projection = OffAxisProjection.matrix(eye: eye, screen: screen, near: Self.near, far: Self.far)

        // 内容宽高比从当前纹理的实际像素宽高算——程序化素材（256×256，方形）
        // 与真实照片（HEIC 常见 3:4 或 4:3）都用这同一行，换素材（updateScene）
        // 后下一帧 draw(in:) 自然读到新纹理的宽高，不需要额外的「换图重算」钩子。
        let contentAspect = Float(colorTexture.width) / Float(colorTexture.height)
        // fill：内容尺寸可能大于屏幕物理尺寸，溢出部分由 OffAxisProjection 的
        // 视锥（仍然按 screen 本身的物理尺寸算，见上面这行）自动裁掉——
        // 详见 ContentFitting 类型注释「为什么是 fill 而不是 fit」。
        let fillSize = ContentFitting.fillSize(contentAspect: contentAspect, screen: screen)
        var uniforms = Uniforms(
            projection: projection,
            parallaxScale: parallaxScale,
            zeroParallax: zeroParallax,
            screenSize: fillSize
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthStencilState)
        // 网格生成时未刻意规划缠绕方向（见 makeGrid），开着背面剔除有五成概率
        // 把整张网格全部剔掉、渲出黑屏。本任务的目标是验证链路，不是抠性能，
        // 关掉剔除换取「不会因为缠绕方向猜错而看起来像别的 bug」。
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setVertexTexture(depthTexture, index: 0)
        encoder.setFragmentTexture(colorTexture, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
