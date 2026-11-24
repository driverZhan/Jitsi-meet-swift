# JitsiObjCDemo

纯 Objective-C 宿主，用来验证 LJMeet 的 CocoaPods 集成是否真的“即插即用”：
只依赖 `pod 'LJMeet', :path => '../'`（本地 podspec，vendored `dist/LJMeet.xcframework` +
JS bundle，并自动带上 `JitsiWebRTC` 依赖），不 import 任何 Swift 源码，也不碰本仓库的
SwiftPM target。

覆盖的流程（常规会议式三段布局，全部在同一个 ViewController 里切换）：

1. **配置页**：`bootstrapWithConferenceHost:…` → `connectWithServiceURL:…`；服务器地址、
   XMPP domain、MUC、JWT 都是可编辑输入框，默认指向自建部署，没有回退到公共服务的逻辑。
   **Transport** 可选 `Auto (race both)` / `BOSH` / `WebSocket`：Auto 同时发起 WebSocket 与
   推导出的 BOSH 端点、先连上的胜出；固定 BOSH 或 WebSocket 时，URL 即使写成另一种形式也会
   归一化到所选端点。连接成功后下方才出现 **Disconnect**，其余输入框锁定。
2. **入会前预览页**（全屏黑底，隐藏导航栏）：中间是 16:9 的自拍画布（默认样式
   `fillMode = "fit"`，整帧可见、不拉伸不裁剪），上方是房间名与 “Joining as …”，下方是圆形
   **麦克风 / 摄像头 / 翻转** 控件和绿色 **Join now** 胶囊按钮；左上角返回箭头回到配置页并关闭
   预览。首次预览会请求系统相机/麦克风权限；任一项被拒绝时只用允许的设备继续，并弹出可跳到
   系统设置的提示。关掉的轨道仍然创建，只是入会前 disable，进房后仍可在控制栏重新打开。预热
   文案明确提示 “Nothing is sent until you join”，此时只采集、不发布；点 **Join now** 复用同一份
   采集入会，不会黑屏重启摄像头。配置页的 **Auto-join after connect** 会先走同一段预览再自动入会。
3. **会议页**（全屏黑底）：
   * **顶栏**：左侧房间名 + `昵称 · N in the room`；右侧计时、日志、参会者三个按钮。计时来自
     `meetingElapsedSeconds` / `meetingRemainingSeconds`：有会议时限时显示剩余时间（≤60 秒转红），
     否则显示自服务端建房时间起的会议时长。
   * **画廊**：自适应网格铺满顶栏与控制栏之间的区域，每格固定 16:9；算法从 1 列开始取“能放下
     全部参会者的最少列数”，行与列都居中，少量参会者时不会强行拉伸到整屏。
   * **底部控制栏**：Mute / Camera / Flip / 音频路由 / Record（本地录制）/ Screen（ReplayKit
    屏幕录制，真机）/ 红色 Leave。录完的文件落在 app 容器的 `Library/Caches/`，同时尝试写入相册。
    **Audio: …** 显示当前真实输出
     路由（`receiver`/`speaker`/`headphones`/`bluetooth`/`carPlay`），点击在 receiver 与 speaker
     之间切换；外接耳机/蓝牙/CarPlay 连接时仍由系统优先，路由变化通过
     `jitsiDidChangeAudioOutputRoute:` 回调刷新按钮并写入日志。**Leave** 离会并断开，回到配置页。
4. **画布网格**：本机画布始终在第一位，且与预览页共用同一个 `localCanvasView`——入会时
   把同一个 view 从预览宿主移到本机格子，采集不中断。远端画布按加入顺序追加，来自
   `jitsiDidJoinRemoteCanvas:participantID:displayName:` 交付的 `UIView`，离开时由
   `jitsiDidLeaveRemoteParticipant:` 移除；重连后重复下发的画布会先清掉旧 tile 再挂载。
   所有画布都是 16:9 且默认用 `defaultCanvasStyle.fillMode = "fit"`（`resizeAspect`）渲染：
   整帧可见，既不拉伸也不裁剪，非 16:9 的画面在画布内留黑边；格子带 1pt 淡描边，模拟器上
   没有摄像头画面时黑底格子也能看出边界。本机画布通过
   `setCanvasStyle:forParticipant:@"local"` 单独调大了头像（72pt、右上角）与名称字号（15pt），
   远端保持默认样式——这就是逐画布设置的示例。摄像头关闭时画布显示头像占位 + 昵称 + 静音/电平条。
5. **参会者面板**：右上角 **参会者** 按钮弹出 page sheet（medium / large 两档）。本地行 +
   `participants` 每一行显示昵称、麦克风/摄像头开关状态、4 格麦克风电平条；该参与者正在说话时
   整行变绿。数据来自 `audioLevels()` 与可选回调 `jitsiDidUpdateAudioLevels:`，加入/离开/静音
   事件由 `jitsiDidReceiveEvent:payload:` 刷新。
6. **日志面板**：右上角 **日志** 按钮弹出的等宽字体窗口，保留有上限的会话日志（连接、预览、
   入会、媒体、画布与事件），音频电平/统计这类高频事件已过滤；**Done** 关闭。
7. **状态与事件**：`JitsiSDKDelegate` 的 `jitsiDidChangeState:` 驱动按钮与页码切换（配置 →
   预览 → 会议），`jitsiDidReceiveEvent:payload:` 把房间事件写进日志。
8. **生命周期**：前后台切换通过 `setAppActive:` 交给 SDK 的自动重连逻辑。

## 启动参数（脚本/自动化）

界面里能填的入口参数也支持 launch environment，方便 `simctl` 无 UI 驱动：

| 变量 | 作用 |
| --- | --- |
| `JITSI_DEMO_URL` | service URL（如 `wss://host:8443/xmpp-websocket`） |
| `JITSI_DEMO_TRANSPORT` | `auto`（默认，竞速 WebSocket + BOSH）/ `bosh` / `websocket` |
| `JITSI_DEMO_DOMAIN` / `JITSI_DEMO_MUC` | XMPP domain / MUC |
| `JITSI_DEMO_TOKEN` | JWT，留空即匿名/访客登录 |
| `JITSI_DEMO_ROOM` / `JITSI_DEMO_NAME` | 房间名 / 显示名 |
| `JITSI_DEMO_AUTO_CONNECT=1` | 启动后自动连接，连接成功即打开本机预览（仍停在本机，不发布） |
| `JITSI_DEMO_AUTO_JOIN=1` | 预览就绪后自动入会；若遇到等候室或密码则停下等界面处理 |
| `JITSI_DEMO_AUDIO=0` / `JITSI_DEMO_VIDEO=0` | 预览开关的初始值：入会时以静音麦克风/摄像头加入（轨道仍会创建） |
| `JITSI_DEMO_UNMUTE_AFTER_JOIN=1` | 入会后 8 秒自动打开麦克风与摄像头，验证静音入会仍可恢复 |
| `JITSI_DEMO_AUDIO_ROUTE=receiver` / `speaker` | 入会后 3 秒请求一次内置音频路由，日志里对比“请求的”和“实际的”路由 |
| `JITSI_DEMO_CUSTOM_ADM=1` | 连接前打开自建 ADM（`JitsiSDK.useCustomAudioDevice`，对应配置页同名开关）；改变后需重启 app |
| `JITSI_DEMO_RECORD_SECONDS=10` | 入会后 2 秒开始本地录制，录满 N 秒自动停止，日志里打出 `recording file: <path>` |
| `JITSI_DEMO_SCREEN_SECONDS=10` | 入会后 4 秒开始屏幕录制（ReplayKit，真机专用），**从真正开始录的那刻**计时 N 秒后停止；日志里打出 `screen recording saved: <path>` |
| `JITSI_DEMO_SHEET=people` / `logs` | 入会后 2 秒自动弹出参会者或日志面板（验证 sheet 与截图） |
| `JITSI_DEMO_AUTO_LEAVE=1` | 入会后 8 秒自动点 Leave，验证回到配置页的收尾流程 |

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

# 1) 生成 Xcode 工程（framework 与 bundle 由 CocoaPods 注入，工程里不再手动引用 dist/）
xcodegen generate

# 2) 安装 LJMeet（本地 podspec）与 WebRTC（需要网络；pod 版本与 dist/WebRTC-LICENSE.txt 一致）
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

* LJMeet 由 `Podfile` 的 `pod 'LJMeet', :path => '../'` 集成：vendored 的
  `dist/LJMeet.xcframework` 是静态框架，只链接不嵌入；`dist/LJMeet_LJMeet.bundle` 经
  podspec 的 `s.resources` 自动进 app 的 Copy Bundle Resources（否则 SDK 找不到 JS
  运行时会在启动时 `fatalError`）。
* `JitsiWebRTC` 是唯一的动态框架，由 CocoaPods 负责 Embed & Sign。
* 使用 **UIScene 生命周期**（`Info.plist` 的 `UIApplicationSceneManifest` + `SceneDelegate`）：
  iOS 26+ 运行时会对仍用旧 `AppDelegate.window` 生命周期、且用新 SDK 链接的 app 直接 trap——
  停在 `main` 的 `EXC_BREAKPOINT`，日志是
  `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` /
  “UIScene life cycle is required for apps built with this SDK”。窗口由 `SceneDelegate` 创建，
  `AppDelegate` 只保留启动回调。
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
* 模拟器没有摄像头画面：预览和远端画布会显示黑底 + 昵称/静音图标/电平条，这是模拟器采集限制；
  真机上画布会显示真实画面，比例仍按 16:9 留边不裁剪。
* 日志里出现 `connect failed`：先确认 service URL 的 scheme（`wss`/`https`）与端口，以及部署是否
  允许匿名登录（自建通常要求主域登录 + `guest` 域）。
