# JitsiWebRTC.podspec
#
# ⚠️ 本文件是 lint 影子 spec（shadow spec），仅用于本仓库内验证：
#
#   pod lib lint JitsiMeetSDK.podspec --include-podspecs=JitsiWebRTC.podspec --allow-warnings
#
# 原因：CocoaPods trunk 的 JitsiWebRTC 124.0.2 声明 ios 12.0（最新 155.0.1 也只有 14.0），
# 低于 Xcode 27 构建系统的最低部署目标 15.0；`pod lib lint` 的验证 Podfile 无法配置
# post_install，依赖 target 会被构建系统直接拒绝。--include-podspecs 让 lint 以 :path
# 方式解析本文件（deployment_target 15.0），绕开 trunk 的旧声明。
#
# 宿主真实集成不受本文件影响：JitsiMeetSDK.podspec 的 `s.dependency 'JitsiWebRTC',
# '~> 124.0'` 在宿主工程里仍从 trunk/git 正常解析。若你的 JitsiWebRTC 仓库已把
# deployment_target 抬到 15.0，本文件可删除。

Pod::Spec.new do |s|
  s.name         = 'JitsiWebRTC'
  s.version      = '124.0.2'
  s.summary      = 'WebRTC prebuilt binary by Jitsi (M124) — lint shadow spec.'
  s.description  = 'Mirror of the published JitsiWebRTC pod, vendoring the same Jitsi M124 WebRTC.xcframework with the deployment target raised to 15.0 for Xcode 27 compatibility.'
  s.homepage     = 'https://github.com/jitsi/webrtc'
  s.license      = { :type => 'BSD', :file => 'Frameworks/WebRTC-LICENSE.txt' }
  s.author       = { 'Jitsi Team' => 'dev@jitsi.org' }
  s.source       = { :git => 'https://github.com/driverZhan/JitsiWebRTC.git', :tag => s.version.to_s }

  s.platform          = :ios
  s.ios.deployment_target = '15.0'
  s.vendored_frameworks   = 'Frameworks/WebRTC.xcframework'
end
