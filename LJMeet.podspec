# LJMeet.podspec
#
# 二进制 pod：直接消费 Scripts/build-xcframework.sh 产出的 dist/ 交付物——
#
#   dist/LJMeet.xcframework         单一静态框架（模块名 LJMeet；真机 + arm64/x86_64 模拟器）
#   dist/LJMeet_LJMeet.bundle       JS 运行时资源（lib-jitsi-meet + shims）
#
# pod 本身不再携带源码，安装即链接，无编译步骤。媒体栈 WebRTC 走独立 pod 依赖：
#
#   s.dependency 'JitsiWebRTC', '~> 155.0'
#
# trunk 的 JitsiWebRTC 155.0.1 与本仓库 Frameworks/WebRTC.xcframework 是同一 Jitsi
# 官方 M155 构建（dist/LJMeet.xcframework 已用该构建重新编译），链接安全。CocoaPods 的分工：
#
#   LJMeet（静态）       → 只链接、不嵌入、不签名（Do Not Embed 语义）
#   JitsiWebRTC（动态）  → 嵌入宿主 App 并签名，是唯一 signed binary
#
# ⚠️ 已知限制：trunk JitsiWebRTC 155.0.1 声明 ios 14.0，低于 Xcode 27 构建系统的最低
# 部署目标 15.0，宿主构建需用 post_install 抬到 15.0（见下方集成要求）。
#
# 资源说明：静态框架里编译进的是 SwiftPM 的 `Bundle.module` 访问器，它在 App 主包
# 根目录按名字查找 LJMeet_LJMeet.bundle；`s.resources` 会把这个预构建 bundle 原样
# 拷进宿主资源，名字不变，查找路径天然吻合，无需任何 shim。
#
# 集成要求（宿主 Podfile）：
#
#   use_frameworks! :linkage => :static
#
#   post_install do |installer|
#     # trunk JitsiWebRTC(155.0.1) 声明 ios 14.0，低于 Xcode 27 的 15.0 下限
#     installer.pods_project.targets.each do |t|
#       t.build_configurations.each do |c|
#         c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
#       end
#     end
#   end
#
#   target 'YourApp' do
#     pod 'LJMeet'    # 自动带上 JitsiWebRTC 依赖
#   end
#
# Swift 用法：import LJMeet
# ObjC 用法：#import <LJMeet/LJMeet-Swift.h>
#
# 已知边界（同 dist/INTEGRATION.txt）：二进制 swiftmodule 未带 .swiftinterface，
# 宿主必须使用与打包时一致的 Xcode/Swift 版本。用 Xcode 27.1（Swift 6.4）打包的
# 产物在 Xcode 26.3 宿主上会报 auto-link 警告（CoreAudioTypes/UIUtilities/AudioUnit）
# 与 CMTime Swift 扩展符号 Undefined symbol。解法（二选一）：
#   a) 宿主统一升级 Xcode 27.1；
#   b) 在装有最旧目标 Xcode（如 26.3）的机器上重跑 ./Scripts/build-xcframework.sh
#      重新打包——旧工具链的产物在旧/新宿主上都能链接（新编译器可读旧 swiftmodule）。
# SDK 代码变更后先重跑 ./Scripts/build-xcframework.sh 再发新 pod 版本。

Pod::Spec.new do |s|
  s.name             = 'LJMeet'
  s.version          = '1.0.1'
  s.summary          = 'lib-jitsi-meet 的 Swift 原生集成：JavaScriptCore 运行 lib-jitsi-meet，原生 WebRTC 媒体栈与 SwiftUI/ObjC 双门面。'
  s.description      = <<-DESC
                       把 lib-jitsi-meet 跑在 iOS 的 JavaScriptCore 上，媒体走原生 libwebrtc
                       （JitsiWebRTC pod 依赖）后端。提供 Swift 与 Objective-C 双门面：连接/
                       会议全量 API、断线重连、等候室、分组讨论、录制、屏幕共享（ReplayKit）、
                       投票/字幕/表情，以及 SwiftUI 会议 UI 与逐人音频电平回调。
                       WebRTC 依赖随 pod 自动接入，安装即链接使用。
                       DESC
  s.homepage         = 'https://github.com/driverZhan/Jitsi-meet-swift'
  s.license          = { :type => 'Apache 2.0', :file => 'Sources/JitsiJSRuntime/Resources/js/98-lib-jitsi-meet.LICENSE.txt' }
  s.author           = { 'zhanyong' => 'zhanyong@example.com' }
  s.source           = { :git => 'https://github.com/driverZhan/Jitsi-meet-swift.git', :tag => s.version.to_s }

  s.ios.deployment_target = '15.0'
  s.vendored_frameworks = 'dist/LJMeet.xcframework'
  s.resources           = 'dist/LJMeet_LJMeet.bundle'

  # WebRTC 媒体栈走独立 pod（动态框架，CocoaPods 自动嵌入签名）；~> 155.0 允许 M155
  # 内的补丁版本。注意：换 WebRTC 大版本前必须先用新 WebRTC 重新构建 dist/LJMeet.xcframework。
  s.dependency 'JitsiWebRTC', '~> 155.0'

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
