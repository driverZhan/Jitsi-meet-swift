# JitsiObjCDemo

纯 Objective-C 宿主，用来验证发布的 `dist/JitsiMeetSDK.xcframework` 是否真的“即插即用”：
只依赖 xcframework + CocoaPods 的 `JitsiWebRTC`，不 import 任何 Swift 源码，也不碰本仓库的
SwiftPM target。

覆盖的流程：

1. **创建连接**：`bootstrapWithConferenceHost:…` → `connectWithServiceURL:…`；服务器地址、
   XMPP domain、MUC、JWT 都是可编辑输入框，默认指向自建部署，没有回退到公共服务的逻辑。
2. **连接成功 → 加入房间**：连接成功后出现 Join 区，可以手动点 **Join**、点 **Skip**（保持连接，
   不进入房间），或者打开 **Auto-join after connect** 跳过 prejoin 直接入会。
3. **会议内**：静音麦克风/摄像头、前后摄像头切换、Leave、Disconnect。
4. **参会者列表**：本地行 + `participants` 每一行显示昵称、麦克风/摄像头开关状态、
   4 格麦克风电平条；该参与者正在说话时整行变绿。数据来自 `audioLevels()` 与可选回调
   `jitsiDidUpdateAudioLevels:`，加入/离开/静音事件由 `jitsiDidReceiveEvent:payload:` 刷新。
5. **状态与事件**：`JitsiSDKDelegate` 的 `jitsiDidChangeState:` 驱动按钮和状态文案，
   `jitsiDidReceiveEvent:payload:` 把房间事件写进日志（音频电平/统计事件已过滤）。
6. **生命周期**：前后台切换通过 `setAppActive:` 交给 SDK 的自动重连逻辑。

## 启动参数（脚本/自动化）

界面里能填的入口参数也支持 launch environment，方便 `simctl` 无 UI 驱动：

| 变量 | 作用 |
| --- | --- |
| `JITSI_DEMO_URL` | service URL（如 `wss://host:8443/xmpp-websocket`） |
| `JITSI_DEMO_DOMAIN` / `JITSI_DEMO_MUC` | XMPP domain / MUC |
| `JITSI_DEMO_TOKEN` | JWT，留空即匿名/访客登录 |
| `JITSI_DEMO_ROOM` / `JITSI_DEMO_NAME` | 房间名 / 显示名 |
| `JITSI_DEMO_AUTO_CONNECT=1` | 启动后自动连接（仍停在本机预览） |
| `JITSI_DEMO_AUTO_JOIN=1` | 连接成功后自动入会；若遇到等候室或密码则停下等界面处理 |

```bash
SIMCTL_CHILD_JITSI_DEMO_AUTO_CONNECT=1 \
SIMCTL_CHILD_JITSI_DEMO_AUTO_JOIN=1 \
SIMCTL_CHILD_JITSI_DEMO_ROOM=demo-room \
xcrun simctl launch <device> org.jitsi.swift.objc.demo
```

`/tmp/objc-demo-joined.png` 这类截图即由上述方式产出：连接失败时界面会停在
`connect failed: …` 错误行，不会继续入会。

## 生成与运行

```bash
cd DemoObjC

# 1) 生成 Xcode 工程（project.yml 已经把 dist/ 下的 xcframework 与资源 bundle 接好）
xcodegen generate

# 2) 安装 WebRTC（需要网络，pod 版本与 dist/WebRTC-LICENSE.txt 一致）
pod install

# 3) 打开 workspace
open JitsiObjCDemo.xcworkspace
```

命令行构建：

```bash
xcodebuild -workspace DemoObjC/JitsiObjCDemo.xcworkspace \
  -scheme JitsiObjCDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO build
```

## 工程关键点

* `dist/JitsiMeetSDK.xcframework` 是静态框架：`embed: false`，只链接不嵌入。
* 使用 **UIScene 生命周期**（`Info.plist` 的 `UIApplicationSceneManifest` + `SceneDelegate`）：
  iOS 26+ 运行时会对仍用旧 `AppDelegate.window` 生命周期、且用新 SDK 链接的 app 直接 trap——
  停在 `main` 的 `EXC_BREAKPOINT`，日志是
  `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` /
  “UIScene life cycle is required for apps built with this SDK”。窗口由 `SceneDelegate` 创建，
  `AppDelegate` 只保留启动回调。
* `dist/JitsiMeetSDK_JitsiMeetSDK.bundle` 必须进 app 的 Copy Bundle Resources（否则 SDK 找不到
  JS 运行时会在启动时 `fatalError`）。
* `JitsiWebRTC` 是唯一的动态框架，由 CocoaPods 负责 Embed & Sign。
* 应用本身是 Objective-C，但保留了 `Sources/SwiftRuntimeAnchor.swift` 这一个空 Swift 类型：
  SDK 是 Swift 静态框架，纯 ObjC target 不会配置 Swift 运行时链接与拷贝，链接时会报
  `auto-linked library 'swiftCompatibility56'`。“混合”target 才会带上这些设置
  （`ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES`）。
* `Podfile` 里的 `post_install` 把 `JitsiWebRTC` 的部署版本从 podspec 声明的 iOS 12 提到 15，
  否则 Xcode 27 直接拒绝构建。
* 默认自建参数（全部可在界面里改，取自部署的 `config.js`）：
  * Service URL：`wss://tmeeting.maesgroup.com:8443/xmpp-websocket`
    （同一 host 的 `https://tmeeting.maesgroup.com:8443/http-bind` 也可用，直接改输入框即可）
  * XMPP domain：`meet.jitsi`
  * MUC：`muc.meet.jitsi`

## 常见现象

* Xcode 里启动停在 `main` 的 `EXC_BREAKPOINT`：构建 SDK 与运行时不低于 iOS 26，而 app 未采用
  UIScene 生命周期。本工程已带 `UIApplicationSceneManifest`；如果你的宿主仍是旧
  `AppDelegate.window` 写法，照 `Sources/SceneDelegate.m` 迁移即可。
* `requiresPassword`：房间有密码，填好密码后再点一次 **Join**，不需要重连。
* `isWaitingInLobby`：members-only 房间已自动敲门，等主持人放行；`isWaitingForHost` 表示等主持人开房。
* 日志里出现 `connect failed`：先确认 service URL 的 scheme（`wss`/`https`）与端口，以及部署是否
  允许匿名登录（自建通常要求主域登录 + `guest` 域）。
