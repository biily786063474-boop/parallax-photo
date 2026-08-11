.PHONY: test probe probe-build clean

# ParallaxCore 单元测试——TDD 的主循环，秒级反馈
test:
	swift test --package-path ParallaxKit

# 生成探针 Xcode 工程
probe:
	xcodegen generate --project Probe --spec Probe/project.yml

# 构建探针（模拟器，只验证能编译；真机运行见 Task 12）
probe-build: probe
	xcodebuild -project Probe/ParallaxProbe.xcodeproj \
	           -scheme ParallaxProbe \
	           -sdk iphonesimulator \
	           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	           -quiet build

clean:
	rm -rf ParallaxKit/.build Probe/ParallaxProbe.xcodeproj
