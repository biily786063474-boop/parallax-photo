import Foundation

/// 用 push-pull 金字塔为前景剔除后露出的洞填补合理的背景色。
///
/// 背景：两层渲染里，前景层会在遮罩外 `discard_fragment()`，
/// 被丢弃的跨界片元会露出下层——下层必须已经把「本该被前景挡住」的
/// 那部分背景合理地填出来，否则露出来的就是黑洞或者未定义的垃圾像素。
///
/// 为什么用 push-pull 而不是逐像素扩散：扩散型填补（反复从邻居取平均）
/// 对大洞收敛很慢，需要迭代到洞的直径那么多次。push-pull 通过降采样金字塔
/// 把洞外的背景信息一次性带到洞中心，层数只有 O(log(max(width,height)))，
/// 填出来的颜色也因为逐层双线性插值而更平滑，不会有扩散算法常见的条纹感。
///
/// 算法分两阶段：
/// - **push**（降采样）：每一层只用非洞像素（及上一层里已经带权的像素）做加权平均
///   生成下一层，洞对下一层的贡献是 0。层层往上，洞的「权重不足」会被非洞像素稀释。
/// - **pull**（升采样回填）：从最粗的一层开始往回走，用更粗一层的双线性插值结果
///   填补当前层里权重不足的像素，权重本身也用同样的方式向上层混合。
///
/// 最后一步很关键：无论金字塔算出什么，**原始非洞像素被原样写回**，
/// 金字塔的结果只用来决定洞里填什么颜色，绝不允许污染已知的背景。
public enum BackgroundInpainting {

    /// - Parameters:
    ///   - pixels: RGBA8，长度必须是 `width * height * 4`。
    ///   - holeMask: 与图同尺寸，`值 >= threshold` 视为「洞」（即前景，需要被背景填掉）。
    public static func fill(
        pixels: [UInt8],
        width: Int,
        height: Int,
        holeMask: [Float],
        threshold: Float = 0.5
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        guard pixels.count == width * height * 4 else { return nil }
        guard holeMask.count == width * height else { return nil }

        // level 0：非洞像素权重为 1、颜色取自输入；洞像素权重为 0，
        // 颜色留空——不读取输入里洞像素本来的值，那些值是即将被丢弃的前景，
        // 混进金字塔会污染填补结果。
        var levels: [Level] = [Level(
            width: width, height: height,
            pixels: pixels, holeMask: holeMask, threshold: threshold
        )]

        // push：一直降采样到 1×1，作为金字塔的顶点。
        while true {
            let last = levels[levels.count - 1]
            if last.width == 1 && last.height == 1 { break }
            levels.append(last.downsampled())
        }

        // pull：从最粗层开始，逐层用粗层的双线性插值结果回填细层的洞。
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            var finer = levels[l]
            finer.fillHoles(from: levels[l + 1])
            levels[l] = finer
        }

        // 写回：非洞像素保持原样，只有洞用金字塔结果替换。
        var out = pixels
        let filled = levels[0]
        for i in 0..<(width * height) where holeMask[i] >= threshold {
            let px = i * 4
            out[px + 0] = byte(filled.color[i].r)
            out[px + 1] = byte(filled.color[i].g)
            out[px + 2] = byte(filled.color[i].b)
            out[px + 3] = 255
        }
        return out
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value, 0), 255).rounded())
    }

    // MARK: - 单通道版本（深度图用）

    /// `fill` 的单通道浮点版本，专给背景层的深度图用。
    ///
    /// 背景：两层渲染里，背景层自身**不** discard——它是前景层遮罩外片元
    /// discard 之后露出的那一层。如果背景层在遮罩边界自己的深度有断崖式的
    /// 台阶（例如简单地把前景处的深度写成 0/远平面），跨越这个台阶的三角形
    /// 会被拉成陡坡，产生的锯齿跟"两层 LDI 之前、没有前景/背景之分时"完全
    /// 同源——只是从前景层转移到了背景层，锯齿并没有被消除。正确做法与背景
    /// 颜色完全对称：外扩填补，让前景区域的深度平滑延续周围背景的深度。
    ///
    /// 算法与 `fill` 共用同一套 push-pull 金字塔思路（push 降采样只用非洞
    /// 像素、pull 从粗层双线性回填），单通道浮点比 RGBA8 更简单：不需要
    /// `byte(_:)` 那样的量化/钳位，也不需要固定 alpha=255 这种格式细节。
    ///
    /// - Parameters:
    ///   - values: 任意单通道浮点数据，长度必须是 `width * height`。
    ///     洞位置的原始值会被完全无视（不会以任何方式泄漏进填补结果），
    ///     调用方不需要在传入前预先清零。
    ///   - holeMask: 与 `fill` 的 `holeMask` 同一套语义，`值 >= threshold`
    ///     视为洞。
    /// - Returns: 非洞位置与输入逐值相同，洞位置被金字塔估计值替换；
    ///   尺寸不匹配时返回 `nil`。
    public static func fillScalar(
        values: [Float],
        width: Int,
        height: Int,
        holeMask: [Float],
        threshold: Float = 0.5
    ) -> [Float]? {
        guard width > 0, height > 0 else { return nil }
        guard values.count == width * height else { return nil }
        guard holeMask.count == width * height else { return nil }

        var levels: [ScalarLevel] = [ScalarLevel(
            width: width, height: height,
            values: values, holeMask: holeMask, threshold: threshold
        )]

        // push：一直降采样到 1×1，作为金字塔的顶点。
        while true {
            let last = levels[levels.count - 1]
            if last.width == 1 && last.height == 1 { break }
            levels.append(last.downsampled())
        }

        // pull：从最粗层开始，逐层用粗层的双线性插值结果回填细层的洞。
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            var finer = levels[l]
            finer.fillHoles(from: levels[l + 1])
            levels[l] = finer
        }

        // 写回：非洞值保持原样，只有洞用金字塔结果替换。
        var out = values
        let filled = levels[0]
        for i in 0..<(width * height) where holeMask[i] >= threshold {
            out[i] = filled.value[i]
        }
        return out
    }
}

/// 金字塔的一层：每个像素带一个 RGB 颜色估计和一个 [0,1] 的置信权重
/// （1 = 完全来自非洞像素，0 = 完全没有可信信息）。
private struct RGB {
    var r: Float = 0
    var g: Float = 0
    var b: Float = 0
}

private struct Level {
    let width: Int
    let height: Int
    var color: [RGB]
    var weight: [Float]

    /// 顶层（原始分辨率）初始化：非洞像素权重 1，洞像素权重 0。
    init(width: Int, height: Int, pixels: [UInt8], holeMask: [Float], threshold: Float) {
        self.width = width
        self.height = height
        var color = [RGB](repeating: RGB(), count: width * height)
        var weight = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            guard holeMask[i] < threshold else { continue }
            let px = i * 4
            color[i] = RGB(r: Float(pixels[px]), g: Float(pixels[px + 1]), b: Float(pixels[px + 2]))
            weight[i] = 1
        }
        self.color = color
        self.weight = weight
    }

    init(width: Int, height: Int, color: [RGB], weight: [Float]) {
        self.width = width
        self.height = height
        self.color = color
        self.weight = weight
    }

    /// push 的降采样：2×2 盒式加权平均，只有非洞（权重 > 0）像素参与颜色平均，
    /// 权重取该 2×2 块里权重的平均值。奇数边长时最后一块只覆盖 1 个像素，
    /// 按实际覆盖到的像素数取平均，不越界读取。
    func downsampled() -> Level {
        let outWidth = max(1, (width + 1) / 2)
        let outHeight = max(1, (height + 1) / 2)
        var outColor = [RGB](repeating: RGB(), count: outWidth * outHeight)
        var outWeight = [Float](repeating: 0, count: outWidth * outHeight)

        for oy in 0..<outHeight {
            for ox in 0..<outWidth {
                var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
                var sumWeight: Float = 0
                var sampleCount: Float = 0
                for dy in 0..<2 {
                    let iy = oy * 2 + dy
                    guard iy < height else { continue }
                    for dx in 0..<2 {
                        let ix = ox * 2 + dx
                        guard ix < width else { continue }
                        let idx = iy * width + ix
                        let w = weight[idx]
                        sumR += color[idx].r * w
                        sumG += color[idx].g * w
                        sumB += color[idx].b * w
                        sumWeight += w
                        sampleCount += 1
                    }
                }
                let outIdx = oy * outWidth + ox
                if sumWeight > 1e-6 {
                    outColor[outIdx] = RGB(r: sumR / sumWeight, g: sumG / sumWeight, b: sumB / sumWeight)
                }
                outWeight[outIdx] = sampleCount > 0 ? sumWeight / sampleCount : 0
            }
        }
        return Level(width: outWidth, height: outHeight, color: outColor, weight: outWeight)
    }

    /// pull 的回填：本层权重不足的像素，用更粗一层的双线性插值结果按权重混合。
    /// 权重已经是 1 的像素（顶层的原始非洞像素）直接跳过——它们最终会被调用方
    /// 原样写回，这里改不改都不影响结果，跳过只是省一次无意义的自混合。
    mutating func fillHoles(from coarser: Level) {
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let w = weight[i]
                if w >= 1 { continue }

                // 粗层每个像素代表细层一个 2×2 块，块中心相对细层坐标偏移 0.5。
                let cx = (Float(x) - 0.5) / 2.0
                let cy = (Float(y) - 0.5) / 2.0
                let (upColor, upWeight) = coarser.bilinearSample(x: cx, y: cy)

                color[i] = RGB(
                    r: color[i].r * w + upColor.r * (1 - w),
                    g: color[i].g * w + upColor.g * (1 - w),
                    b: color[i].b * w + upColor.b * (1 - w)
                )
                weight[i] = w + (1 - w) * upWeight
            }
        }
    }

    /// clamp-to-edge 双线性采样。
    private func bilinearSample(x: Float, y: Float) -> (RGB, Float) {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx.rounded(.down))
        let y0 = Int(cy.rounded(.down))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0)
        let fy = cy - Float(y0)

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        let i00 = y0 * width + x0, i10 = y0 * width + x1
        let i01 = y1 * width + x0, i11 = y1 * width + x1

        let r = color[i00].r * w00 + color[i10].r * w10 + color[i01].r * w01 + color[i11].r * w11
        let g = color[i00].g * w00 + color[i10].g * w10 + color[i01].g * w01 + color[i11].g * w11
        let b = color[i00].b * w00 + color[i10].b * w10 + color[i01].b * w01 + color[i11].b * w11
        let w = weight[i00] * w00 + weight[i10] * w10 + weight[i01] * w01 + weight[i11] * w11

        return (RGB(r: r, g: g, b: b), w)
    }
}

/// 金字塔的一层（`fillScalar` 用）：与 `Level` 结构完全对称，只是把三通道
/// `RGB` 换成一个 `Float`——push/pull/双线性采样的逻辑没有任何分支性差异，
/// 拆成独立类型只是不想为了单通道数据硬套一个只用得上一个字段的 `RGB`。
private struct ScalarLevel {
    let width: Int
    let height: Int
    var value: [Float]
    var weight: [Float]

    /// 顶层（原始分辨率）初始化：非洞像素权重 1，洞像素权重 0。
    init(width: Int, height: Int, values: [Float], holeMask: [Float], threshold: Float) {
        self.width = width
        self.height = height
        var value = [Float](repeating: 0, count: width * height)
        var weight = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            guard holeMask[i] < threshold else { continue }
            value[i] = values[i]
            weight[i] = 1
        }
        self.value = value
        self.weight = weight
    }

    init(width: Int, height: Int, value: [Float], weight: [Float]) {
        self.width = width
        self.height = height
        self.value = value
        self.weight = weight
    }

    /// push 的降采样：2×2 盒式加权平均，只有非洞（权重 > 0）像素参与平均，
    /// 权重取该 2×2 块里权重的平均值。奇数边长时最后一块只覆盖 1 个像素，
    /// 按实际覆盖到的像素数取平均，不越界读取。
    func downsampled() -> ScalarLevel {
        let outWidth = max(1, (width + 1) / 2)
        let outHeight = max(1, (height + 1) / 2)
        var outValue = [Float](repeating: 0, count: outWidth * outHeight)
        var outWeight = [Float](repeating: 0, count: outWidth * outHeight)

        for oy in 0..<outHeight {
            for ox in 0..<outWidth {
                var sumValue: Float = 0
                var sumWeight: Float = 0
                var sampleCount: Float = 0
                for dy in 0..<2 {
                    let iy = oy * 2 + dy
                    guard iy < height else { continue }
                    for dx in 0..<2 {
                        let ix = ox * 2 + dx
                        guard ix < width else { continue }
                        let idx = iy * width + ix
                        let w = weight[idx]
                        sumValue += value[idx] * w
                        sumWeight += w
                        sampleCount += 1
                    }
                }
                let outIdx = oy * outWidth + ox
                if sumWeight > 1e-6 {
                    outValue[outIdx] = sumValue / sumWeight
                }
                outWeight[outIdx] = sampleCount > 0 ? sumWeight / sampleCount : 0
            }
        }
        return ScalarLevel(width: outWidth, height: outHeight, value: outValue, weight: outWeight)
    }

    /// pull 的回填：本层权重不足的像素，用更粗一层的双线性插值结果按权重混合。
    /// 权重已经是 1 的像素（顶层的原始非洞像素）直接跳过——它们最终会被调用方
    /// 原样写回，这里改不改都不影响结果，跳过只是省一次无意义的自混合。
    mutating func fillHoles(from coarser: ScalarLevel) {
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let w = weight[i]
                if w >= 1 { continue }

                // 粗层每个像素代表细层一个 2×2 块，块中心相对细层坐标偏移 0.5。
                let cx = (Float(x) - 0.5) / 2.0
                let cy = (Float(y) - 0.5) / 2.0
                let (upValue, upWeight) = coarser.bilinearSample(x: cx, y: cy)

                value[i] = value[i] * w + upValue * (1 - w)
                weight[i] = w + (1 - w) * upWeight
            }
        }
    }

    /// clamp-to-edge 双线性采样。
    private func bilinearSample(x: Float, y: Float) -> (Float, Float) {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx.rounded(.down))
        let y0 = Int(cy.rounded(.down))
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0)
        let fy = cy - Float(y0)

        let w00 = (1 - fx) * (1 - fy)
        let w10 = fx * (1 - fy)
        let w01 = (1 - fx) * fy
        let w11 = fx * fy

        let i00 = y0 * width + x0, i10 = y0 * width + x1
        let i01 = y1 * width + x0, i11 = y1 * width + x1

        let v = value[i00] * w00 + value[i10] * w10 + value[i01] * w01 + value[i11] * w11
        let w = weight[i00] * w00 + weight[i10] * w10 + weight[i01] * w01 + weight[i11] * w11

        return (v, w)
    }
}
