# JitsiMeetSDK — lib-jitsi-meet 的 Swift 原生骨架（方案 A）

把 `lib-jitsi-meet` 的**全部**信令与协商逻辑原样跑在 JavaScriptCore 上，由 Swift 提供它依赖的
宿主环境（DOM / XHR / WebSocket / WebRTC 等 shim，Worker 桥留给 E2EE 阶段），UI 与视频渲染 100% 原生。
**没有 WKWebView，没有渲染进程，没有 iframe**：WebView 只出现在被移除的路径里。

最低支持版本：**iOS 15.0**（`Package.swift` 里的 `platforms`）。

---

## 1. 分层

```
JitsiMeetSDK        伞形入口：bootstrap / shutdown / meetingView
├── JitsiUI         SwiftUI：MeetingView、VideoGrid、ControlBar、VideoSurface(AVSampleBufferDisplayLayer)
├── JitsiCall       来电呈现：RegionPolicy、CallCenter、SystemInterruptionPresenter、CallKit(编译开关)
├── JitsiCore       公开 API 与类型：JitsiMeet / JitsiConnection / JitsiConference / MeetingEvent / JSONValue
├── JitsiJSRuntime  JavaScriptCore 宿主 + shim 注入 + Swift↔JS 桥
│   └── Resources/js  按文件名序号顺序加载的 shim
└── JitsiMedia      MediaBackend 抽象、采集(CaptureCoordinator/AudioSessionManager)、libwebrtc 实现

JitsiMeetExample    完全自研 UI 的参考实现（DemoMeetingScreen / LevelStore），依赖上面三层公开 API
└── JitsiMeetDemoApp  可执行宿主 app：SwiftPM 下用 Scripts/make-demo-app.sh 打进模拟器；
                      同一份源码也被 Demo/JitsiDemo.xcodeproj 直接编译（framework 形态，见第 10 节）
```

依赖方向只有一个：`JitsiCore` 定义协议（`MeetingEngine`、`MediaBackend`），上层实现它。
因此换掉 JS 运行时或换掉 libwebrtc 都不影响 UI 与公开 API。

## 2. 桥契约

只有一条窄契约，升级 lib-jitsi-meet 时**只**动 `50-sdk-facade.js`。

JS → Swift
* `__nativeReceive(json)`：`mode:"call"`，异步，用 `__nativeResolve/__nativeReject` 回填 Promise；
  `mode:"sync"`，只通知（事件上报、timer、日志）。
* `__nativeSyncReceive(json) -> String?`：同步读，必须同步返回。用于
  `env.describe`、`pc.create`、`ws.open`、`http.send`、`storage.get`、`crypto.randomUUID`、
  `crypto.randomBytes`、`media.canPlayType`。

Swift → JS
* `__nativeEmit(channel, name, payload)`：把 native 事件（WebSocket/XHR/PC 状态/track/timer）送回 shim 的监听器。
* `__sdkSettle(method, argsJSON, resolve, reject)`：Swift 侧调用 SDK 的入口（`JSCEngineHost.invoke`）。
  它在**同一次 JS 执行**里包住 `__sdkInvoke` 并挂上回调——JavaScriptCore 只在最外层执行返回时排空
  microtask 队列，分两次执行（先拿 Promise、再 `call(withArguments:)` 调 `.then`）的回调永远不会被触发。
* `__sdkInvoke({method, args}) -> Promise`：JS 内部的调用入口，方法表在 `50-sdk-facade.js`。

Shim 加载顺序：
`00-native.js` → `10-dom-xml.js` → `20-network.js` → `30-webrtc.js` → `40-globals.js` →
`50-sdk-facade.js` → `99-lib-jitsi-meet.bundle.js`

宿主身份：`navigator.product = 'ReactNative'` + iOS UA。这样 lib 的 `BrowserCapabilities.isReactNative()`
成立（走它已经验证过的、无 DOM 渲染的路径），同时 `getOS()` 解析为 iOS。

## 3. 上手

```swift
import JitsiMeetSDK

let engine = try await JitsiMeetSDK.bootstrap(
    config: SDKConfig(region: .chinaMainland),
    conferenceHost: "meet.example.org"
)

let connection = try JitsiMeet.shared.createConnection(
    ConnectionOptions(
        serviceUrl: "wss://meet.example.org/xmpp-websocket",
        hosts: .init(domain: "example.org", muc: "conference.meet.example.org"),
        token: jwt
    )
)
try await connection.connect()
let conference = try await connection.join(
    ConferenceOptions(name: "room-1", displayName: "张三")
)
try await conference.capture([.audio, .video])

// 或直接用现成的界面
JitsiMeetSDK.meetingView(connection: options, conference: conferenceOptions)
```

事件从 `JitsiMeet.shared.events` 扇出，UI 侧由 `MeetingModel` 订阅并维护参与者/轨道状态。

`serviceUrl` 是 Strophe 的**传输端点**，与 XMPP 域无关：BOSH 用 `https://host:port/http-bind`，
WebSocket 用 `wss://host:port/xmpp-websocket`，两者不会自动回退。自建部署的 `hosts.domain` /
`hosts.muc` 看对方 `config.js`（docker-jitsi-meet 默认 `meet.jitsi` / `muc.meet.jitsi`）。
`ServerAddress(host, transport:domain:muc:)` 可以一次生成这四个值。

## 4. 自定义 UI 使用方法

UI 层是可选皮肤：`JitsiUI` 里没有任何私有状态，全部输入都来自 `JitsiCore` 的公开类型。
你可以只用它的积木，也可以完全不 import `JitsiUI`、自己订阅事件流。

三层可用的入口

| 你要的 | 用什么 |
| --- | --- |
| 整屏现成会议页 | `JitsiMeetSDK.meetingView(connection:conference:onEnded:)` |
| 自己的布局 + 现成状态机 | `MeetingModel`（`@StateObject`/`@ObservableObject`） |
| 完全自研状态机 | `JitsiMeet.shared.events` + `JitsiConnection`/`JitsiConference` + `engine.frameStream(for:)` |

### 4.1 积木清单（都是 public）

* `VideoSurface(frames:mirrored:)`：`UIViewRepresentable`，内部用 `AVSampleBufferDisplayLayer`
  子层渲染（采集给的是横屏 buffer + 旋转角，转 sublayer 才不会破坏镜像变换），
  直接吃 `CVPixelBuffer`（NV12），不建 Metal 管线、不进渲染进程。输入是
  `AsyncStream<VideoPixelFrame>`，每个 surface 一条流，后端 fan-out 只保留每轨道最新一帧。
* `TrackVideo(model:trackID:mirrored:)`：没有 track 时自动降级成头像占位。
* `VideoGrid(model:filmstripHeight:)`：舞台 + 胶片条，纯由 `model.tiles` 渲染。
* `ControlBar(model:onLeave:)`、`ChatView(model:)`。
* `PixelUIView`：需要在 UIKit 里自己拼时可直接用，`enqueue(_:)` 由你驱动。

### 4.2 自己的布局

```swift
struct MyMeetingScreen: View {
    @StateObject private var model = MeetingModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            // 两列等大网格，而不是舞台 + 胶片条
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(model.tiles) { tile in
                    ZStack(alignment: .bottomLeading) {
                        TrackVideo(model: model, trackID: tile.videoTrackID, mirrored: tile.isLocal)
                        if tile.audioMuted { Image(systemName: "mic.slash.fill").foregroundStyle(.red) }
                        Text(tile.displayName).font(.caption).lineLimit(1)
                    }
                    .overlay { if model.isJoined && tile.isDominantSpeaker {
                        RoundedRectangle(cornerRadius: 12).stroke(.green, lineWidth: 2)
                    } }
                }
            }
            .padding(6)

            MyBottomBar(
                muted: model.isAudioMuted,
                onMute: model.toggleAudio,
                onLeave: { Task { await model.leave(); dismiss() } }
            )
        }
        .task {
            await model.start(
                ConnectionOptions(serviceUrl: "wss://meet.example.org/xmpp-websocket",
                                  hosts: .init(domain: "example.org", muc: "conference.meet.example.org")),
                conference: ConferenceOptions(name: "room-1", displayName: "张三"),
                capture: [.audio, .video]
            )
        }
    }
}
```

`MeetingModel` 的读侧：`connectionStatus`、`isJoined`、`tiles`、`isAudioMuted`、`isVideoMuted`、
`isRecording`、`quality`、`message`、`transcript`、`conference`。写侧：`start(_:conference:capture:)`、
`leave()`、`toggleAudio()`、`toggleVideo()`、`switchCamera()`、`setQuality(_:)`、`sendChat(_:)`、
`devices()`、`frames(for:)`。所有失败都汇到 `message` 一个 binding，不会再有第二条错误通道。

要拿原始状态（比如自定义排序、按角色分区）就直接读 `model.conference`：`participants`、
`localTracks`、`remoteTracks`、`dominantSpeaker`、`joined`，配合 `conference.onStateChange`
（每个事件后触发一次）做失效。

### 4.3 完全自研：不经 `MeetingModel`

```swift
@MainActor
final class MyStore: ObservableObject {
    @Published var speaking: [ParticipantID: Double] = [:]
    @Published var muted: Set<String> = []          // "participantID/mediaType"
    @Published var breakoutRooms: JSONValue?

    private let engine: MeetingEngine
    private var subscription: Subscription?

    init(engine: MeetingEngine) { self.engine = engine }
    deinit { subscription?.unsubscribe() }

    func observe() {
        subscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    private func apply(_ event: MeetingEvent) {
        switch event {
        case .audioLevels(let levels):                     // 说话音量环
            for (id, level) in levels { speaking[id] = level }
        case .participantMuted(let id, let kind, let isMuted):
            if isMuted { muted.insert("\(id)/\(kind.rawValue)") } else { muted.remove("\(id)/\(kind.rawValue)") }
        case .raw(name: "breakoutRoomsUpdated", let payload):
            breakoutRooms = payload                        // 44 个未建模事件从这里出去
        default:
            break
        }
    }

    func surface(for trackID: TrackID) -> some View {
        VideoSurface(frames: engine.frameStream(for: trackID), mirrored: false)
    }
}
```

三条硬规则：

1. **一个 `AsyncStream` 只有一个消费者**。永远现取现用（`frames(for:)`/`frameStream(for:)`），
   不要把流存成共享属性，否则两个 tile 会互相偷帧。
2. **每屏一个 `MeetingModel` 或一个订阅者**。事件中枢是广播的，重复订阅会让同一事件被处理两次；
   `Subscription` 必须 `unsubscribe`（`MeetingModel.deinit` 已示范）。
3. **别绕过 façade 直接碰 JS**。需要的能力如果 `MeetingEvent`/`__sdkMethods()` 里没有，
   正确做法是在 `50-sdk-facade.js` 加一个方法或 emit，再在 `JSMeetingEngine.swift` 加 reducer case，
   `Scripts/check-js-shims.swift` 会守住两边名字一致。

可直接用来做 UI 的信号：`audioLevels`（逐参与者音量，说话环）、`endpointMessage`（自定义消息通道，
举手/反应/协作者等走它）、`connectionQualityLevel`（digital 级别与逐端级别）、
`recordingStateChanged`/`e2EEStateChanged` 的原始 payload，以及 `raw` 里的 44 个未建模事件。

UI 层现状（写自定义界面时会踩到，按需要自己补）

* `MeetingModel.switchCamera()` 目前是空炮：`JitsiConference.switchCamera()` 抛
  `JitsiError.unsupported("switchCamera")`，设备列表在 `CaptureCoordinator` 里已能枚举，缺的是把
  新设备重新绑到活动视频轨道。自研 UI 若要切换摄像头，先用 `conference.removeTrack(_:)` +
  `capture([.video], deviceIDs: ["video": uniqueID])` 这条路。
* `isAudioMuted`/`isVideoMuted` 只在 `start` 时同步一次，被 moderator 远端强制静音时按钮图标不会跟着变。
  自研 store 应该订阅 `trackMuteChanged` 与 `participantMuted` 自己维护。
* `tiles` 每次重算都是全量重建（`participants` 排序 + 本地轨道 + 孤儿远端轨道）。几十人以内的会议没问题；
  大房间请自己按 `dominantSpeaker`/`lastN` 做可见性裁剪，`MeetingEvent.raw` 里的
  `lastNEndpointsChanged` 就是为此准备的。

### 4.4 跑起来的 demo（`JitsiMeetExample` + `JitsiMeetDemoApp`）

`Sources/JitsiMeetExample` 是上面那条"完全自研"路线的参考实现，刻意**不用** `VideoGrid`/`ControlBar`
（只用 `ChatView`、`VideoSurface` 和 `MeetingModel`）：

* `DemoMeetingScreen`：自适应 1/2/3 列网格、状态胶囊（连接状态/质量/当前说话者/录制点/轨道数）、
  可折叠事件控制台、自研 dock（麦克风、摄像头、举手、码率菜单、聊天、挂断）。
* `LevelStore`：不经 `MeetingModel` 的自研 store，把 `audioLevels`、`participantMuted`、
  `dominantSpeakerChanged`、`participantLeft` 和 `raw("breakoutRoomsUpdated")` 归约成音量环、
  远端静音集合与日志窗口；没有引擎也能跑，所以单测直接喂事件（`FrameStreamTests` 补帧路径）。
* `JitsiMeetDemo`：`bootstrap`/`connection`/`conference`/`screen`，以及给 UIKit、OC 宿主的
  `viewController(...)`（`UIHostingController` 包装）。

```bash
# 组装 .app（SwiftPM 的模拟器可执行文件没有 bundle），装到模拟器并自动入会
DEMO_AUTOJOIN=1 ./Scripts/make-demo-app.sh --device <simulator-udid>
xcrun simctl io <simulator-udid> screenshot /tmp/demo.png
```

默认 host 是 `https://tmeeting.maesgroup.com:8443`。这个部署的传输层和 XMPP 身份不是一回事：
WebSocket 端点（`/xmpp-websocket`）返回 HTTP 501，只能用 BOSH（`/http-bind`），Prosody 的域名是
`meet.jitsi`、MUC 域名是 `muc.meet.jitsi`。首屏因此有 Host / XMPP domain / MUC domain / Transport
四项，全部走 `@AppStorage` 持久化；默认值即这套部署，换成别的服务器时按对方 `config.js` 填。
"Auto join on launch" 打开后每次启动直连，真机反复 attach 调试器时不用重新填表（第 10 节）。
模拟器摄像头没有画面源（`FigCaptureSourceSimulator err=-12784`），采集会成功但不出帧，本地 tile 因此是一块黑色；
真机才能看到自画面。

### 4.5 连接与信令排查（debug 模式）

`SDKConfig.debugSignaling = true` 会打开完整链路日志：

```swift
let config = SDKConfig(
    region: .chinaMainland,
    debugSignaling: true        // 同时把 lib-jitsi-meet 调到 DEBUG
)
// 或走 LJM 的级别，但不会抓原始帧/ stanza：
// SDKConfig(logLevel: "debug")
```

打开后控制台按通道输出（`[jitsi-js:log]` 前缀来自 JS 转发器）：

| 前缀 | 内容 |
| --- | --- |
| `[debug][sdk]` | debug 开关状态 |
| `[debug][http]` | 每次 BOSH/fetch 的 method、URL、状态码和完整请求/响应体（含 SASL `<auth>`） |
| `[debug][ws]` | WebSocket connect/open/send/recv/close/error 与每一帧 |
| `[debug][xmpp]` | 解析后的每个 stanza（`send` / `recv`），包括 IQ、presence、SDP |

`debugSignaling` 可在运行时切换：引擎已安装时再次 `bootstrap(config:)` 会调用
`MeetingEngine.setDebugSignaling(_:)`，或者直接 `await JitsiMeetSDK.setDebugSignaling(true)`，
不需要重建 `JSContext`。单条消息超过 800 字符会拆成多条带 `… ` 续行标记的记录，避免 `os_log`
在 ~1 KB 处截断。

Demo 首屏有 **Debug signaling logs** 开关；模拟器也可用环境变量直接开：

```bash
SIMCTL_CHILD_JITSI_DEMO_AUTOJOIN=1 SIMCTL_CHILD_JITSI_DEMO_DEBUG=1 \
  xcrun simctl launch <simulator-udid> org.jitsi.swift.demo
```

看日志：Xcode 控制台；或 Console.app 选中设备/模拟器进程；模拟器也可以

```bash
xcrun simctl spawn <simulator-udid> log stream --level debug \
  --predicate 'process == "JitsiMeetDemoApp"' | grep jitsi-js
```

真机没有 Xcode 时用 Console.app（窗口左侧选中 iPhone，过滤 `JitsiMeetDemoApp`）。注意这些日志会带上
JWT、SASL 载荷和 TURN 临时密码，只能用于本地排查，不要开在发布包或对外日志里。

## 5. 构建与校验

```bash
# 1) 生成 lib 产物并落到资源目录（产物已随工作区提交，需要换版本时才重跑）
./Scripts/build-js-bundle.sh /path/to/lib-jitsi-meet

# 2) 编译校验（两个开关状态都要过）
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --build-tests --triple arm64-apple-ios15.0-simulator --sdk "$SDK"
JITSI_ENABLE_CALLKIT=1 swift build --build-tests --triple arm64-apple-ios15.0-simulator --sdk "$SDK"

# 3) shim + lib 契约检查（在 macOS 上把 7 个脚本灌进真实 JSContext 跑断言）
swift Scripts/check-js-shims.swift

# 4) 真机 slice（libwebrtc 的两个 slice 都要能选到）
swift build --triple arm64-apple-ios15.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"

# 5) 单元测试跑在模拟器上
xcrun simctl boot <simulator-udid>
xcodebuild test -scheme JitsiMeetSDK-Package -destination 'platform=iOS Simulator,id=<simulator-udid>'
```

测试要跑在模拟器进程里，只能交给 `xcodebuild`；而 `xcodebuild` 会把仓库根目录里现成的 `.xcodeproj`
当成当前项目，所以第 5) 步的前提是根目录没有工程文件——`Demo/JitsiDemo.xcodeproj` 放在 `Demo/` 下正是
为了这条（见第 10 节）。

`Frameworks/WebRTC.xcframework` 是随包提交的二进制依赖，缺失时 manifest 解析直接失败（见第 8 节）。

`check-js-shims.swift` 做四件事：加载全部 shim 并跑 19 条行为断言（DOM/XML、Strophe 的 `:scope`
查询、XML 大小写保留、WebSocket、XHR、fetch、RTCPeerConnection、getUserMedia、`new MediaStream(tracks)`、
navigator 身份、localStorage、crypto、setTimeout→native、Blob/URL），其中两条是**异步**的：把 runloop
泵起来，要求 `__sdkSettle('lib.init')` 真的 resolve、未知方法真的 reject——同步断言看不见一条永不落地的 Promise；
再用真实产物构造 `JitsiConnection` 与
`JitsiConference`，核对 facade 解引用的每个 lib 成员是否存在；再核对 facade 里每个 `on('EVENT_NAME')`
都在 lib 的事件枚举中；最后交叉核对两张表——`JSMeetingEngine.swift` 里 `invoke("x.y")` 的每个方法都必须
存在于 `__sdkMethods()`，reducer 里每个 `case "name"` 都必须由 facade 真正 `emit` 过。名字对不上在 JS 侧
只会变成运行时 rejection 或被静默跳过的监听器，所以把它们都变成 FAIL。

## 6. lib-jitsi-meet 产物在资源里的位置

`Sources/JitsiJSRuntime/Resources/js/99-lib-jitsi-meet.bundle.js` 是真正的 webpack UMD 产物
（1.04 MiB；构建链：`npm ci` → `gen-version` → `webpack`；没有跑 `build:tsc`，它只产 `.d.ts` 且会被无关
类型错误拖挂）。同目录 `98-lib-jitsi-meet.LICENSE.txt` 是压缩头注释指向的第三方许可证文本；两者都由
SPM 的 `.copy("Resources/js")` 整目录搬进 `JitsiMeetSDK_JitsiJSRuntime.bundle/js/`，宿主按文件名序加载，
`.txt` 不会被当成脚本。产物尾部两行注释记录了源目录与构建时间，替换时以 `git rev-parse` 为准。

webpack 同时产出 `dist/umd/lib-jitsi-meet.e2ee-worker.js`（18 KB）。E2EE 阶段才需要它，现在**没有**安装进
资源目录，脚本会提示它的存在。

## 7. lib-jitsi-meet 功能覆盖

facade 暴露 26 个方法，`MeetingEvent` 建模 23 类事件，其余 44 个 emit 走 `MeetingEvent.raw`
（分屏讨论室、音视频 moderation、认证状态、桥接通道、字幕等），需要时按事件名提升为强类型 case，
不需要改桥。

本版本 lib 的几个签名与直觉不同，facade 已按真实 API 处理，改动时别退回旧写法：
* `JitsiConnection` 只有 `addEventListener`，没有 `on`（`on` 只在 `JitsiConference` 上）。
* `mediaDevices.enumerateDevices(callback)` 是回调式，不是 Promise；`isDeviceListAvailable` 已被移除。
* 本地发送分辨率是 `setSenderVideoConstraint(h)`，不存在 `setLocalVideoQuality`。
* `RECORDER_STATE_CHANGED` 的唯一参数是 `JibriSession`（`getStatus/getMode/getID/getError`），
  录制与直播共用这一个事件；`stopRecording(sessionID)` 要的是会话 id，所以 `startRecording` 会记住会话。
* Strophe 发原始 stanza 用 `connection.send(node)`，节点由 DOM shim 的 `DOMParser` 生成（走
  `createElementNS` 路径，因此保留标签大小写）。


已接通：连接/XMPP 登录（token 与 user/password）、加入/离开会议、本地轨道创建与增删、
静音（本地与远端强制）、改名、举手、聊天与 endpoint message、踢人、录制（stream/file/YouTube）、
`lastN`、分辨率与接收端码率约束、设备枚举与切换、 dominant speaker、参与人与角色事件、
连接质量、统计（`conference.stats` 走 `getStats()` 原始记录）、原始 XMPP 命令。

尚未接通（明确 `unimplemented`，不会静默降级）：
* **E2EE**：需要 `createEncodedStreams`（编码帧变换器）+ `crypto.subtle`（CryptoKit 后端）+ Worker 桥。
  相关入口在 `30-webrtc.js` 的 `createEncodedStreams`、facade 的 `conference.e2ee`、
  `NativeRouter.swift` 里 `worker.*` 的分支。
* **解除远端参与者视频静音**（lib 侧本身依赖 S Frame 转发）。

## 8. libwebrtc（已内置，无需外部依赖）

`Frameworks/WebRTC.xcframework` 是 Jitsi 官方发布的 libwebrtc 构建（pod `JitsiWebRTC 124.0.2`，
即 libwebrtc M124，与 jitsi-meet / react-native-webrtc 124.0.7 pin 的那条线一致），由
`Package.swift` 里 `.binaryTarget(name: "WebRTC", path: "Frameworks/WebRTC.xcframework")` 声明，
`JitsiMedia` 直接依赖它。集成方拿到本包就能开会，不用再单独找 WebRTC。

* 只保留 `ios-arm64` 与 `ios-arm64_x86_64-simulator` 两个 slice，删掉 macOS slice 与两个 `dSYMs`
  目录（442MB 符号，运行时无用），落地 34MB；framework 二进制与发布包逐字节相同。
  `Frameworks/WebRTC-LICENSE.txt` 记录了来源 URL、版本、裁剪方式和 BSD-3 许可证正文
  （二进制分发必须保留许可证，所以别删这个文件）。最低系统 iOS 12，低于本包的 iOS 15 门槛。
* 想让仓库更轻：换成 `.binaryTarget(name: "WebRTC", url: "…/v124.0.2/WebRTC.xcframework.zip",
  checksum: "…")`，代价是集成时联网下载完整包（含 dSYMs）。
* 想用自己的 libwebrtc（换解码器、开 SVC）：替换同名 xcframework 即可，`#if canImport(WebRTC)`
  自动生效。彻底不要 WebRTC 时，删掉目录和那一行 `.binaryTarget`，`MediaBackendFactory` 退回
  `UnavailableMediaBackend`——大声失败，而不是假装能开会。
* 编成动态 framework（`type: .dynamic`）时产物是 `JitsiMeetSDK.framework` 加同级的
  `WebRTC.framework`，前者的 `LC_LOAD_DYLIB` 指向 `@rpath/WebRTC.framework/WebRTC`；
  两个 framework 必须一起进包（用 SPM 集成则自动处理）。
* 改过 xcframework 的 `Info.plist` 后要 `swift package clean`：SwiftPM 缓存 slice 描述，
  否则一直报 `Missing path .../dSYMs`。

`WebRTCBackend.swift` 已按这份头文件真机编译校验过。下面这些是骨架阶段凭直觉写的、M124 里
其实不存在的签名，改动时不要退回去：

| 想当然的写法 | M124 实际 |
| --- | --- |
| `peerConnection(with:constraints:report:)` | `peerConnection(with:constraints:delegate:)`，返回 optional |
| `sender.mediaConstraints` 控码率 | 改 `sender.parameters.encodings[].maxBitrateBps/minBitrateBps` 再回写 `sender.parameters` |
| `videoSource.capture(frame)` | `RTCVideoSource` 只当 `RTCVideoCapturerDelegate`：建 `RTCVideoCapturer(delegate: source)`，然后 `source.capturer(capturer, didCapture: frame)` |
| `RTCAudioSession.isManual = true` | `useManualAudio = true` **且** `isAudioEnabled = true`，只设前者麦克风不会启动 |
| `track.stop()` | 轨道没有 stop，用 `isEnabled = false` |
| `dataChannel(withLabel:config:)` | `dataChannel(forLabel:configuration:)` |
| `renderer.render(frame)` | `RTCVideoRenderer` 要求 `setSize(_:)` 与 `renderFrame(_:)`（frame 可为 nil） |
| 枚举 `.name` | NS_ENUM 没有 `name`；四个状态枚举由后端映射成 W3C 字符串（`browserName`） |
| `didAdd track:streams:` | Unified Plan 下只有 `didAdd rtpReceiver:streams:`；`didAdd/didRemove stream:` 是 Plan B 专用，永不触发 |
| `statistics` 返回记录数组 | 返回 `RTCStatisticsReport`，`statistics` 是 `[String: RTCStatistics]`（`id/type/timestamp_us/values`）；JS 侧 `RTCStatsReport` 要的是**记录数组**且计数字段直接挂在记录上 |
| colibri 用 `channelId` 的数据通道 | colibri 通道是 WebSocket（`20-network.js`），数据通道只有 reliable/ordered 一种 |

集成时仍需自己确认的事：

1. `MediaCapabilities` 必须与真正编译进去的编解码器一致（默认 `vp8/vp9/h264` + `opus`）；它同时喂给
   JS 侧的 `media.canPlayType`，报错了会产出对端解不了的 SDP。
2. Simulcast：`enableSimulcast` 已在 `pc.create` 路径透传；这份 M124 的
   `RTCRtpEncodingParameters` **没有** `scalabilityMode`，要用 SVC 得换自己的 libwebrtc 构建。
3. 摄像头方向：`frameRotation(for:)` 由 `AVCaptureConnection.videoOrientation` 推 WebRTC 语义的
   顺时针旋转角；横竖屏切换要真机验证。
4. 采集/渲染/带宽的整体表现只能在设备上跑通后确认，本仓库的校验只覆盖编译与 JS 契约。

## 9. 中国大陆：不用 CallKit 的来电方案

`SDKConfig.Region.chinaMainland` 的产物**根本不链接** CallKit/PushKit 符号：
`CallKitPresenter.swift` 整个文件被 `#if JITSI_ENABLE_CALLKIT` 包住，而该 flag 只由
`Package.swift` 读取环境变量决定；即使误设了 flag，`RegionPolicy.presenter(for: .chinaMainland)`
也只会返回 `SystemInterruptionPresenter`。

分发与呈现：
* **在线**：App 自己的 XMPP/WebSocket 长连接就是信令通道，前台直接弹 overlay
  （`CallOverlayController` 挂在 `UIWindowScene` 上）。
* **离线**：APNs **alert** 推送（普通可见通知，不是 `PKPushTypeVoIP`，不需要 PushKit）。
* **未前台**：`UNNotificationCategory` 上挂 `ANSWER`（`.foreground`）与 `DECLINE`（`.destructive`）
  两个动作按钮 + 自定义铃声 `incoming.caf`。

代价（设计时必须承认）：后台无法在用户点击前加入会议，也不能像 CallKit 那样在锁屏点亮屏幕或抢占
audio unit。所以 `CallCenter` 返回的是一个 `CallDecision` 而不是预热好的会话——点击接受之后才启动
engine 入会。

国际版：设置 `JITSI_ENABLE_CALLKIT=1` 编译，`RegionPolicy` 返回 `CallKitPresenter`，集成方还需自备
PushKit token 与 `pushRegistry(_:didReceive:for:)` → `CallCenter.report(_:)`、CallKit entitlement、
以及 `CXProviderConfiguration` 里的 `templateIcon`。`IncomingCall` / `CallDecision` 契约不变。

## 10. 打包成 framework，在真机上验证

`swift build` 只能证明编译，采集方向、渲染、音频会话和旋转都只能在真机确认。
`./Scripts/build-xcframework.sh` 把每个 public module 打成独立的 `.xcframework` 放进 `dist/`，
`Demo/JitsiDemo.xcodeproj` 是只吃这些产物的 Xcode 工程——没有 SwiftPM 依赖，集成方拿到的形态和
本工程验证的形态一致。

```bash
./Scripts/build-xcframework.sh          # dist/: 7 个 xcframework + WebRTC + JS bundle
open Demo/JitsiDemo.xcodeproj           # Signing & Capabilities 里选自己的 Team 后 Run
```

| 产物 | 说明 |
| --- | --- |
| `JitsiCore/JitsiMedia/JitsiJSRuntime/JitsiUI/JitsiCall/JitsiMeetSDK/JitsiMeetExample.xcframework` | 每个 public module 一个静态 framework，`ios-arm64` + `ios-arm64-simulator` 两个 slice |
| `WebRTC.xcframework` | 原样搬过来，是**唯一**需要 embed（因而需要重签名）的二进制 |
| `JitsiMeetSDK_JitsiJSRuntime.bundle` | lib-jitsi-meet 产物 + 7 个 shim，必须额外拷进 app 的 Resources |

三条硬约束，缺任何一条都是运行期才炸：

1. **静态链接**（`.library(type: .static)`）：集成方只 embed WebRTC 一个 dylib，SDK 自己的代码链进主
   二进制，真机签名只剩一步。一个 umbrella dylib 做不到这件事——Swift 的 `import X` 只解析
   `X.framework/Modules/X.swiftmodule`，嵌套 module 的接口不会随伞文件暴露，所以一个模块一个 framework。
2. **JS bundle 要进 app**：静态链接下 `Bundle.module` 只在 `Bundle.main.resourceURL`、
   `Bundle(for:).resourceURL`、`Bundle.main.bundleURL` 三处找 `JitsiMeetSDK_JitsiJSRuntime.bundle`，
   找不到就 `fatalError`。把 `dist/` 里那个 bundle 拖进 Copy Bundle Resources 即可（iOS 资源落在 .app
   根目录，正好命中第一个候选）。
3. **只有 WebRTC 走 Embed & Sign**：pbxproj 的 `PBXCopyFilesBuildPhase`（`dstSubfolderSpec = 10`）里只放
   WebRTC，其余 7 个静态库留在编译阶段。

模拟器 slice 只有 arm64（WebRTC 有 x86_64，我们的模块没有），命令行构建模拟器要加
`ARCHS=arm64 ONLY_ACTIVE_ARCH=NO`；Apple Silicon 上从 Xcode 直接 Run 到模拟器不受影响。

真机验证清单（默认 host 已指向 `https://tmeeting.maesgroup.com:8443`，BOSH + `meet.jitsi`/`muc.meet.jitsi`）：

* [ ] 入会：状态胶囊走到 `Connected`，事件控制台出现 `joined`（BOSH 首次 `conference request (IQ)`
      可能收到一次 `invalid session`，lib-jitsi-meet 会 1 秒后自动重试，属于服务端 Jicofo 行为）
* [ ] 采集：本地 tile 出帧——模拟器没有画面源，这一条必须真机
* [ ] 前后摄切换，以及旋转后画面方向（`VideoSurface` 的旋转角取自 track）
* [ ] 静音/取消静音：音量环与 `participantMuted` 同步，远端能听到
* [ ] 聊天收发、举手、（有 Jibri 时）`toggleRecording`
* [ ] 切后台/锁屏后音频是否继续（`AVAudioSession` 是 `.playAndRecord`）
* [ ] 挂断回到首屏再次入会，engine 不残留、不串流

Xcode 停在 `Preparing <iPhone>` / `Timed out waiting for all destinations` 时，是 CoreDevice 与手机
之间的准备流程卡住，不是签名或工程配置问题（签名有效、`devicectl install` 能装）。命令行兜底：

```bash
xcodebuild -project Demo/JitsiDemo.xcodeproj -scheme JitsiDemo -configuration Debug \
  -destination 'generic/platform=iOS' build
xcrun devicectl device install app --device <UDID> \
  .build/demo/Debug-iphoneos/JitsiDemo.app
```

装好后直接点桌面图标启动（`devicectl process launch` 本身也可能挂起，不影响安装和手动启动）。
要把 Xcode Run 修回来，依次试：解锁手机并保持亮屏 → 重新插拔 USB / 重新信任 → Xcode 的
Window → Devices and Simulators 等 “Preparing” 结束 → 重启 iPhone 和 Mac。

中国大陆：`dist/` 里的 `JitsiCall.xcframework` 默认就**不含** CallKit/PushKit 符号（flag 只有
`JITSI_ENABLE_CALLKIT=1` 时才注入），可直接用于大陆发行；首屏 Region 选 "China mainland" 时
呈现方案说明会跟着变（见第 9 节）。

## 11. 已知坑（改动前先看）

* **JSValue 的下标语法在本工具链里不可用**：ObjC 属性桥接不会变成 Swift subscript。
  只能用 `forProperty(_:)`、`setValue(_:forProperty:)`、`hasProperty(_:)`、
  `JSValue(object:in:)`、`JSValue(nullIn:)`、`JSValue(undefinedIn:)`。
  见 `JSValue+JSON.swift`。
* **没有 JSON→JSValue 的初始化器**：`JSONBridge.jsValue` 走 `JSON.parse` 求值，因为
  `valueWithObject:` 会把 `NSNull` 桥成一个非 null 对象。
* **XML 环境里 `createElement` 不能按 HTML 大写标签名**：Strophe 用 `createElement('body')` 造 BOSH
  包装，输出 `<BODY>` 时 Prosody 直接回 `condition='bad-request'`；`createElement`/`createElementNS`/parser
  现在都保留原始大小写，`check-js-shims.swift` 守着这一条。
* **Strophe 用属性注册回调**（`xhr.onreadystatechange`、`socket.onopen`）而不是 `addEventListener`：
  `EventTarget.dispatchEvent` 必须调用 `this['on' + type]`，否则 BOSH/WebSocket 都停在第一步。
* **BOSH 长轮询要长于服务端 `wait`**：`NetworkModule` 的 request timeout 是 120 秒（Prosody 默认 wait 60 秒）；
  30 秒会把空闲轮询当成传输错误并断线。
* **Strophe 序列化依赖 NamedNodeMap 与 `nodeValue`**：`attributes.length`、`getNamedItem()`、文本节点的
  `nodeValue` 缺一个就会在 `xmlescape` 里炸（`undefined.replace`）。
* **XML selector 里的 `#`/`.` 可能属于命名空间 URI**：`:scope>x[*|xmlns="…#user"]>status[code="201"]`
  是 lib-jitsi-meet 的判定条件，class/id 检查只能看标签名部分，属性谓词要支持 `*|local`。
* **`http.send` 的同步返回值是事件通道 id**（字符串），XHR shim 用它拼事件名；改成对象会断掉回调。
* **JavaScriptCore 只在最外层 JS 执行返回时排空 microtask 队列**：Swift 里先 `call(withArguments:)` 拿到
  Promise、再另起一次执行调它的 `.then`，回调永远不会落地，表现是 `bootstrap()`/`connect()` 无限挂起。
  必须在一次执行里把 promise 和回调一起挂上（`__sdkSettle`），并且用 `check-js-shims.swift` 的异步断言守住。
* **shim 要按 W3C 形状被使用，而不是按我们的内部约定**：lib 会 `new MediaStream(stream.getAudioTracks())`
  把一条流拆成音频流和视频流，再对 `track.getSettings()` 取 `deviceId`/`facingMode`/宽高。只认
  `{id, tracks}` 快照的构造函数会静默产出一条空流，错误则变成远处一句
  `undefined is not an object (evaluating 's.getSettings')`。`30-webrtc.js` 现在两种形式都吃。
* **会议名是 XMPP node，必须小写**：`JitsiSwiftDemo` 会被 lib 直接判成 `Invalid conference name`，
  连不上服务器。demo 的默认房间名因此是 `jitsi-swift-demo`。
* **console 转发别用 `JSON.stringify` 兜底 Error**：Error 序列化结果是 `{}`，等于把 lib 报错全丢了；
  `00-native.js` 现在优先取 `error.stack`。
* **`JitsiLocalTrack.mute()` 不带参数**：它固定静音，取消静音必须调 `unmute()`。把标志传给 `mute(false)`
  等于再静音一次，并在 `isMuted() === true` 处静默短路——媒体完全不动、也没有日志，表现就是
  “关摄像头再打开本机/远端都没画面、关麦克风再打开远端一直静音”。门面里
  `conference.setMuted` 已按标志分派到 `mute()`/`unmute()`。
* **视频静音走 `track.enabled` 而不是 stream-remove**：`50-sdk-facade.js` 把
  `JitsiMeetJS.util.browser.doesVideoMuteByStreamRemove` 设为 `() => false`。默认路径会在静音时把
  stream 移出 PC、取消静音时重新 `getUserMedia`，新轨道 id 与本机采集/渲染的映射全部错位；采集本来
  就在 native 侧持续运行，`enabled` 路径保持 id 稳定，`SourceInfo` 仍照常通知对端静音状态。
* **SwiftPM 的 iOS 可执行文件要手工打包**（`Scripts/make-demo-app.sh`）：`WebRTC.framework` 在
  `.build/<config>-iphoneos*/` 产物根目录而**不是** `PackageFrameworks/`；`@executable_path/Frameworks`
  在 iOS 上不是隐式搜索路径，必须 `install_name_tool -add_rpath` 显式加；沿用 RN 模板 plist 里的
  `UIRequiredDeviceCapabilities: [armv7]` 会让 app 在 arm64 模拟器上直接起不来（表现为 SpringBoard 崩溃循环）。
* **`simctl` 没有 `--setenv`**：子进程环境用 `SIMCTL_CHILD_<VAR>` 前缀传；`--stdout=`/`--stderr=` 必须写成
  等号形式，否则后面的参数被当成设备名。
* **`xcodebuild -create-xcframework` 不吃静态 framework**：静态产物没有 `.swiftinterface`，命令直接报
  "No 'swiftinterface' files found within …/Modules/X.swiftmodule"。`.xcframework` 只是目录加一份
  `Info.plist`（`CFBundlePackageType=XFWK` + `AvailableLibraries`），所以 `build-xcframework.sh` 手写它。
* **远端轨道和参会者是两条上报通道**：lib 只发 `TRACK_ADDED`，不会把轨道挂到
  `participant.getTracks()` 上，所以参与者快照里永远没有 tracks。`JitsiConference` 现在把
  `remoteTrackAdded`/`remoteTrackRemoved`/`trackMuteChanged` 同步进
  `participant.snapshot.tracks`；自定义 UI 按参会者渲染时可以直接读它，不要再假设 JS 侧已经填好。
* **采集方向不能从 `AVCaptureConnection.videoOrientation` 推**：它只是连接创建时的默认值
  （`.landscapeLeft`），不跟随手机姿态，按它算帧旋转会多转 90°。iOS 17+ 用
  `AVCaptureDevice.RotationCoordinator` 物理旋转（`videoRotationAngleForHorizonLevelCapture`），
  旋转后缓冲直接上送 `rotation = ._0`；iOS 15/16 退回 `UIDevice` 方向元数据。自视图镜像只翻转左右，
  两条路径下自视图与远端看到的方向因此一致。
* **`.build/release` 是指向"最后一次构建的 triple"的符号链接**：连着编两个平台时第二个会挪走落点，
  所以脚本每编完一个平台就立刻把产物拷进 `.build/xcframework-stage`，不要延后统一取。
* `AsyncStream` 只有一个消费者，所以 `statusChanges()` 每次调用新建一条流，不做共享属性。
* iOS 15 下限：`Locale…languageCode`（16）、`AVCaptureDevice.DeviceType.microphone`（17）、
  `.builtInHeadphone`、值型 `NavigationLink`、`isFlipped`、`SymbolEffect` 都不可直接使用。
* **`WebRTCBackend.swift` 的锁用在 async 函数里**：`NSLock.lock()` 在异步上下文中会报
  "unavailable from asynchronous contexts" 警告，Swift 6 语言模式下升级为错误。本包固定在
  Swift 5 模式（见 `Package.swift` 顶部注释），迁 strict concurrency 时要把这些临界区抽成同步方法。
