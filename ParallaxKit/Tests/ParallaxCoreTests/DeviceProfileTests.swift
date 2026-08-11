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

    @Test("标识符没有重复")
    func identifiersAreUnique() {
        let identifiers = DeviceProfileRegistry.all.map(\.identifier)
        #expect(Set(identifiers).count == identifiers.count, "设备表里有重复标识符")
    }

    @Test("尚未经真机校准的条目都标记为 false")
    func uncalibratedEntriesAreMarked() {
        // 探针 P11 跑完之前，表里不应该有任何条目自称已校准。
        // 这条测试会在 Task 12 回填真实数据时被有意改掉。
        for profile in DeviceProfileRegistry.all {
            #expect(profile.isCalibrated == false,
                    "\(profile.identifier) 声称已校准，但探针 P11 还没跑")
        }
    }
}
