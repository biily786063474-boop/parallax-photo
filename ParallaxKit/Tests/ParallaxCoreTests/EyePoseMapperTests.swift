import Testing
import simd
@testable import ParallaxCore

@Suite("EyePoseMapper")
struct EyePoseMapperTests {

    /// iPhone 14 Pro Max，摄像头在顶部、水平居中
    static let iPhone = ScreenGeometry(
        width: 0.07121,
        height: 0.15439,
        cameraOffset: SIMD3(0, 0.15439 / 2 - 0.0064, 0)
    )

    @Test("Z 必须翻转：相机空间的负 Z 变成屏幕空间的正 Z")
    func flipsZ() {
        // 真机实测相机空间眼位是 (−0.0126, −0.1024, −0.4526)，Z 为负。
        // 屏幕空间 Z 指向用户，所以观看距离必须是正的。
        let cameraSpace = SIMD3<Float>(0, 0, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(screenSpace.z > 0, "Z 未翻转，观看距离成了负数：\(screenSpace.z)")
        #expect(abs(screenSpace.z - 0.35) < 1e-6)
    }

    @Test("眼睛正对摄像头时，屏幕空间位置恰好等于摄像头偏移")
    func eyeAlignedWithCameraLandsOnCameraOffset() {
        // 这条钉死加号：眼睛与摄像头在 X/Y 上重合时，
        // 「眼相对屏幕中心」就等于「摄像头相对屏幕中心」。
        // 用减号会得到反号的结果，差 2 倍偏移量。
        let cameraSpace = SIMD3<Float>(0, 0, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x - Self.iPhone.cameraOffset.x) < 1e-6)
        #expect(abs(screenSpace.y - Self.iPhone.cameraOffset.y) < 1e-6,
                "Y 未落在摄像头偏移上：\(screenSpace.y) vs \(Self.iPhone.cameraOffset.y)")
    }

    @Test("眼睛在摄像头下方 cameraOffset.y 处时，正对屏幕中心")
    func eyeBelowCameraLandsOnScreenCenter() {
        // 摄像头在屏幕上方约 71mm，所以眼睛比摄像头低 71mm 时才正对屏幕中心。
        let offsetY = Self.iPhone.cameraOffset.y
        let cameraSpace = SIMD3<Float>(0, -offsetY, -0.35)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x) < 1e-6)
        #expect(abs(screenSpace.y) < 1e-6, "未落在屏幕中心：\(screenSpace.y)")
    }

    @Test("X 与 Y 平移量原样传递")
    func translatesLaterally() {
        let cameraSpace = SIMD3<Float>(0.03, -0.02, -0.4)
        let screenSpace = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: cameraSpace, screen: Self.iPhone
        )
        #expect(abs(screenSpace.x - (0.03 + Self.iPhone.cameraOffset.x)) < 1e-6)
        #expect(abs(screenSpace.y - (-0.02 + Self.iPhone.cameraOffset.y)) < 1e-6)
    }

    @Test("非有限输入不产生 NaN")
    func rejectsNonFinite() {
        let out = EyePoseMapper.screenSpaceEye(
            cameraSpaceEye: SIMD3(Float.nan, Float.infinity, Float(-0.35)), screen: Self.iPhone
        )
        #expect(out.x.isFinite && out.y.isFinite && out.z.isFinite)
    }
}
