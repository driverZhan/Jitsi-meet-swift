# JitsiMeetSDK.podspec
#
# 二进制 pod：直接消费 Scripts/build-xcframework.sh 产出的 dist/ 交付物——
#
#   dist/JitsiMeetSDK.xcframework           单一静态框架（真机 + arm64 模拟器）
#   dist/JitsiMeetSDK_JitsiMeetSDK.bundle   JS 运行时资源（lib-jitsi-meet + shims）
#
# pod 本身不再携带源码，安装即链接，无编译步骤。媒体栈 WebRTC 直接 vendored 进 pod
# （Frameworks/WebRTC.xcframework，Jitsi 官方 M124 构建，34MB 已入库），不再依赖
# trunk 的 JitsiWebRTC pod——trunk 版声明 ios 12.0，低于 Xcode 27 的 15.0 下限，
# spec/lib lint 都会被构建系统拒绝。CocoaPods 的分工：
#
#   JitsiMeetSDK（静态）        → 只链接、不嵌入、不签名（Do Not Embed 语义）
#   WebRTC（vendored 动态框架） → CocoaPods 自动嵌入宿主 App 并签名，唯一 signed binary
#
# 资源说明：静态框架里编译进的是 SwiftPM 的 `Bundle.module` 访问器，它在 App 主包
# 根目录按名字查找 JitsiMeetSDK_JitsiMeetSDK.bundle；`s.resources` 会把这个预构建
# bundle 原样拷进宿主资源，名字不变，查找路径天然吻合，无需任何 shim。
#
# 集成要求（宿主 Podfile）：
#
#   use_frameworks! :linkage => :static
#
#   target 'YourApp' do
#     pod 'JitsiMeetSDK'    # SDK + WebRTC + JS bundle 一并接入，无其他依赖
#   end
#
# Swift 用法：import JitsiMeetSDK
# ObjC 用法：#import <JitsiMeetSDK/JitsiMeetSDK-Swift.h>
#
# 已知边界（同 dist/INTEGRATION.txt）：二进制 swiftmodule 未带 .swiftinterface，
# 宿主必须使用与打包时一致的 Xcode/Swift 版本；SDK 代码变更后先重跑
# ./Scripts/build-xcframework.sh 再发新 pod 版本。

Pod::Spec.new do |s|
  s.name             = 'JitsiMeetSDK'
  s.version          = '1.0.1'
  s.summary          = 'lib-jitsi-meet 的 Swift 原生集成：JavaScriptCore 运行 lib-jitsi-meet，原生 WebRTC 媒体栈与 SwiftUI/ObjC 双门面。'
  s.description      = <<-DESC
                       把 lib-jitsi-meet 跑在 iOS 的 JavaScriptCore 上，媒体走原生 libwebrtc
                       （vendored WebRTC.xcframework）后端。提供 Swift 与 Objective-C 双门面：
                       连接/会议全量 API、断线重连、等候室、分组讨论、录制、屏幕共享
                       （ReplayKit）、投票/字幕/表情，以及 SwiftUI 会议 UI 与逐人音频电平
                       回调。SDK 与 WebRTC 一并接入，安装即链接使用。
                       DESC
  s.homepage         = 'https://github.com/driverZhan/Jitsi-meet-swift'
  s.license          = { :type => 'Apache 2.0', :file => 'Sources/JitsiJSRuntime/Resources/js/98-lib-jitsi-meet.LICENSE.txt' }
  s.author           = { 'zhanyong' => 'zhanyong@example.com' }
  # 发布到私有/公共仓库前，把 git 地址换成真实仓库地址。
  s.source           = { :git => 'https://github.com/driverZhan/Jitsi-meet-swift.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.vendored_frameworks = 'dist/JitsiMeetSDK.xcframework', 'Frameworks/WebRTC.xcframework'
  s.resources           = 'dist/JitsiMeetSDK_JitsiMeetSDK.bundle'

  # WebRTC 媒体栈直接 vendored（Jitsi 官方 M124 构建，与打包 dist 用的字节一致，链接安全）。
  # 动态框架由 CocoaPods 自动嵌入宿主并签名。注意：升到 M155 前必须先用新 WebRTC
  # 重新构建 dist/JitsiMeetSDK.xcframework，并同步更新本文件对应的 Frameworks/WebRTC.xcframework。

  # 与 dist/INTEGRATION.txt 要求链接的系统框架保持一致。
  s.frameworks = 'UIKit', 'SwiftUI', 'AVFoundation', 'CoreMedia', 'CoreVideo',
                 'Accelerate', 'CoreImage', 'JavaScriptCore', 'ReplayKit',
                 'Network', 'UserNotifications', 'Combine'

  # 静态框架内嵌了 Swift 兼容库自动链接指令（swiftCompatibility56 / swiftCompatibilityPacks，
  # SwiftPM 编译时写入）。宿主含 Swift 代码时 Xcode 会自动把工具链 Swift 库目录加进链接
  # 搜索路径；纯 ObjC 宿主则不会，导致 `-lswiftCompatibility56` 找不到（Undefined symbol:
  # __swift_FORCE_LOAD_$_swiftCompatibility56）。这里显式补上搜索路径，两种宿主都覆盖。
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -L"$(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"'
  }
end
