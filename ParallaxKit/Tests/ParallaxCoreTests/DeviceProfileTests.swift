import Testing
import simd
@testable import ParallaxCore

@Suite("DeviceProfile")
struct DeviceProfileTests {

    @Test("已知机型能查到")
    func findsKnownDevice() {
        let profile = DeviceProfileRegistry.profile(for: "iPhone15,3")
        #expect(profile.identifier == "iPhone15,3")
        #expect(profile.displayName.contains("14 Pro Max"))
    }

    @Test("未知机型回落到 fallback")
    func unknownDeviceFallsBack() {
        let profile = DeviceProfileRegistry.profile(for: "iPhone99,9")
        #expect(profile.identifier == DeviceProfileRegistry.fallback.identifier)
    }

    @Test("所有条目的屏幕尺寸都在合理物理范围内")
    func allScreenSizesArePlausible() {
        for profile in DeviceProfileRegistry.all {
            // 手机与平板的显示区不会小于 4cm，也不会大于 40cm
            #expect(profile.screen.width > 0.04 && profile.screen.width < 0.40,
                    "\(profile.identifier) 宽度 \(profile.screen.width) 不合理")
            #expect(profile.screen.height > 0.04 && profile.screen.height < 0.40,
                    "\(profile.identifier) 高度 \(profile.screen.height) 不合理")
        }
    }

    @Test("摄像头偏移不会落在显示区之外太远")
    func cameraOffsetIsPlausible() {
        for profile in DeviceProfileRegistry.all {
            let screen = profile.screen
            // 摄像头可能在边框上略超出显示区，但不应超出半个屏幕尺寸 + 2cm
            let maxX = screen.width / 2 + 0.02
            let maxY = screen.height / 2 + 0.02
            #expect(abs(screen.cameraOffset.x) <= maxX,
                    "\(profile.identifier) 摄像头 X 偏移 \(screen.cameraOffset.x) 超界")
            #expect(abs(screen.cameraOffset.y) <= maxY,
                    "\(profile.identifier) 摄像头 Y 偏移 \(screen.cameraOffset.y) 超界")
        }
    }

    @Test("摄像头偏移的符号必须正确")
    func cameraOffsetSignsAreCorrect() {
        // 这条守护的是最危险的一类错误：符号搞反不会让任何数值越界，
        // 但会让离轴投影的窗口位置在每一帧都错，而且肉眼很难第一时间判断方向。
        // 旁边的 cameraOffsetIsPlausible 用了 abs()，对符号完全免疫。
        let iPhone = DeviceProfileRegistry.iPhone14ProMax
        // 灵动岛在顶部，Y 轴向上，所以偏移为正；且它是屏内挖孔，必须落在显示区之内
        #expect(iPhone.screen.cameraOffset.y > 0, "iPhone 摄像头应在屏幕中心上方")
        #expect(iPhone.screen.cameraOffset.y < iPhone.screen.height / 2,
                "iPhone 是屏内挖孔，不应落在显示区之外")

        let iPad = DeviceProfileRegistry.iPadPro11M4
        // ⚠️ 下面这组 iPad 断言编码的是未经校准的 P11 猜测（DeviceProfile.isCalibrated
        // == false），不是实测事实。真机探针跑完、Task 12 回填校准值后，这里预期会被
        // 重新核对甚至改写——到时若断言与新数据冲突，那是「校准结果 vs 旧猜测」，
        // 不要把它当成回归。
        // M4 iPad Pro 把摄像头移到了长边，竖持时位于左侧边框上——在显示区之外
        #expect(iPad.screen.cameraOffset.x > 0, "iPad Pro M4 摄像头在右侧长边（Apple 手册：center right）")
        #expect(abs(iPad.screen.cameraOffset.x) > iPad.screen.width / 2,
                "iPad 摄像头在边框上，应落在显示区之外")
        #expect(abs(iPad.screen.cameraOffset.y) < 1e-6, "iPad 摄像头应在长边中点，Y 偏移为零")
    }

    @Test("标识符没有重复")
    func identifiersAreUnique() {
        let identifiers = DeviceProfileRegistry.all.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count, "设备表里有重复标识符")
    }

    @Test("原生竖持方向下高必须大于宽")
    func portraitHeightExceedsWidth() {
        // 这条能抓住宽高转置——转置后两个值仍各自落在合理区间内，
        // 只靠各自的上下界是发现不了的。
        for profile in DeviceProfileRegistry.all + [DeviceProfileRegistry.fallback] {
            #expect(profile.screen.height > profile.screen.width,
                    "\(profile.identifier) 宽高疑似转置：\(profile.screen.width) x \(profile.screen.height)")
        }
    }

    @Test("尚未经真机校准的条目都标记为 false")
    func uncalibratedEntriesAreMarked() {
        // 探针 P11 跑完之前，表里不应该有任何条目自称已校准。
        // 这条测试会在 Task 12 回填真实数据时被有意改掉。
        for profile in DeviceProfileRegistry.all + [DeviceProfileRegistry.fallback] {
            #expect(profile.isCalibrated == false,
                    "\(profile.identifier) 声称已校准，但探针 P11 还没跑")
        }
    }
}
