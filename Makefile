.PHONY: test probe probe-build app app-build clean

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

# 生成正式 App 的 Xcode 工程
app:
	xcodegen generate --project App --spec App/project.yml

# 构建 App（模拟器，只验证能编译且链路能跑通；真机验证见 Task 4）
app-build: app
	xcodebuild -project App/Parallax.xcodeproj -scheme Parallax \
	           -sdk iphonesimulator \
	           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	           -quiet build

clean:
	rm -rf ParallaxKit/.build Probe/ParallaxProbe.xcodeproj App/Parallax.xcodeproj
