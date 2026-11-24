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
├── JitsiCall       来电呈现：RegionPolicy、CallCenter、SystemInterruptionPresenter（通知 + 浮层）
├── JitsiCore       公开 API 与类型：JitsiMeet / JitsiConnection / JitsiConference / MeetingEvent / JSONValue
├── JitsiJSRuntime  JavaScriptCore 宿主 + shim 注入 + Swift↔JS 桥
│   └── Resources/js  按文件名序号顺序加载的 shim
├── JitsiObjC       Objective-C 门面（JitsiSDK / JitsiSDKDelegate）
└── JitsiMedia      MediaBackend 抽象、采集(CaptureCoordinator/AudioSessionManager)、libwebrtc 实现

JitsiMeetExample    完全自研 UI 的参考实现（DemoMeetingScreen / LevelStore），依赖上面三层公开 API
└── JitsiMeetDemoApp  可执行宿主 app：SwiftPM 下用 Scripts/make-demo-app.sh 打进模拟器；
                      同一份源码也被 Demo/JitsiDemo.xcodeproj 直接编译（framework 形态，见第 10 节）

DemoObjC            纯 Objective-C 集成示例：只用 dist/ 的 xcframework + CocoaPods 的 JitsiWebRTC，
                    验证连接 → 入会 → 参会者列表/音量，见 DemoObjC/README.md
```

交付时这些源码 module 会被 `Scripts/build-xcframework.sh` 摊平成**一个** `JitsiMeetSDK` module，
所以集成方只需要 `import JitsiMeetSDK`，不再有 7 个 framework 的搜索路径问题。

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

> UIKit（Objective-C / Swift）宿主的完整接入文档见
> [`Docs/UIKitIntegration.md`](Docs/UIKitIntegration.md)：工程配置、预览入会、画布网格、
> 事件与排错都按 `JitsiSDK` 门面整理。

最省事的入口是一次调用 —— 连接、prejoin、入会、等候室/密码、断线重连都由同一个状态机接管：

```swift
import JitsiMeetSDK

let request = MeetingRequest(
    connection: ConnectionOptions(
        serviceUrl: "wss://meet.example.org/xmpp-websocket",
        hosts: .init(domain: "example.org", muc: "conference.meet.example.org"),
        token: jwt
    ),
    conference: ConferenceOptions(name: "room-1", userInfo: UserInfo(displayName: "张三"))
)

// 只要状态机，不要现成界面
let session = try await JitsiMeetSDK.startMeeting(request)
await session.join()                       // 或直接 session.startAndJoin(request)

// 或者一次拿到可分层的完整界面（prejoin → lobby/密码 → 会议 → 结束）
JitsiMeetSDK.meetingContainer(request: request) { /* 用户挂断后回调 */ }
```

`startMeeting` 会复用已安装的引擎；如果现有引擎的 host 与 `request.connection.serviceUrl` 不一致，
直接抛 `invalidArgument`，不会偷偷重连到另一个部署（切换部署要先 `shutdown()`）。

仍然可以按原来的分层方式自己驱动：

```swift
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
    ConferenceOptions(name: "room-1", userInfo: UserInfo(displayName: "张三"))
)
try await conference.capture([.audio, .video])

// 或直接用现成的界面
JitsiMeetSDK.meetingView(connection: options, conference: conferenceOptions)
```

事件从 `JitsiMeet.shared.events` 扇出，UI 侧由 `MeetingModel` 订阅并维护参与者/轨道状态。

`serviceUrl` 是 Strophe 的**传输端点**，与 XMPP 域无关：BOSH 用 `https://host:port/http-bind`，
WebSocket 用 `wss://host:port/xmpp-websocket`。默认 `transport = .auto`：SDK 从 `serviceUrl`
推导出另一种端点，两条连接**同时发起**，先拿到 `CONNECTION_ESTABLISHED` 的胜出，另一条立即
`disconnect()`——某条传输握手卡住不会再拖死整次连接。需要固定传输时显式传 `.websocket` / `.bosh`。
`connectTimeout` 是整次连接的上限（默认 60 秒，`nil` 表示不设 SDK 侧截止）；超时会关闭所有
尝试，不会出现“调用已失败、socket 之后又连上”的状态。自建部署的 `hosts.domain` /
`hosts.muc` 看对方 `config.js`（docker-jitsi-meet 默认 `meet.jitsi` / `muc.meet.jitsi`）。
匿名登录还要看 `hosts.anonymousdomain`：官方 `meet.jit.si` 是 `guest.meet.jit.si`，不填会尝试
在只接受认证用户的主域上做匿名 SASL；自建部署没有该字段时留空。
`ServerAddress(host, transport:domain:muc:)` 可以一次生成这四个值。

## 4. 自定义 UI 使用方法

UI 层是可选皮肤：`JitsiUI` 里没有任何私有状态，全部输入都来自 `JitsiCore` 的公开类型。
你可以只用它的积木，也可以完全不 import `JitsiUI`、自己订阅事件流。

三层可用的入口

| 你要的 | 用什么 |
| --- | --- |
| 一次调用跑完整入会流程 | `JitsiMeetSDK.startMeeting(_:)` → `MeetingSession` |
| 整屏入会流程（prejoin/lobby/密码/结束屏） | `JitsiMeetSDK.meetingContainer(request:layout:autoJoin:onEnded:)` |
| 整屏现成会议页（已连接） | `JitsiMeetSDK.meetingView(connection:conference:onEnded:)` |
| 自己的布局 + 现成状态机 | `MeetingSession`（`MeetingModel` 是它的兼容别名） |
| 完全自研状态机 | `JitsiMeet.shared.events` + `JitsiConnection`/`JitsiConference` + `engine.frameStream(for:)` |

### 4.1 积木清单（都是 public）

* `VideoSurface(frames:mirrored:)`：`UIViewRepresentable`，内部用 `AVSampleBufferDisplayLayer`
  子层渲染（采集给的是横屏 buffer + 旋转角，转 sublayer 才不会破坏镜像变换），
  直接吃 `CVPixelBuffer`（NV12），不建 Metal 管线、不进渲染进程。输入是
  `AsyncStream<VideoPixelFrame>`，每个 surface 一条流，后端 fan-out 只保留每轨道最新一帧。
* `TrackVideo(model:trackID:mirrored:)`：没有 track 时自动降级成头像占位。
* `ParticipantAvatar(name:url:size:)`：远码头像，`http(s)` URL 用 `AsyncImage` 加载，其余情况
  （没有头像、加载失败、`file:` 等非 http scheme）显示昵称首字母。
* `VideoGrid(model:filmstripHeight:)`：舞台 + 胶片条，纯由 `model.tiles` 渲染；说话者带绿色描边，
  非静音参与者显示 `AudioLevelMeter`，摄像头关闭时盖 `video.slash.fill`。
* `AudioLevelMeter(level:)`：4 格音量条（0...1），全部填满时视为满格说话；自定义 tile 可直接放。
* `ParticipantCanvas` / `ParticipantCanvasStyle`：单人自更新画布（视频 fill/fit、头像占位及位置/大小、
  名称位置/字号、说话描边、麦克风徽标、举手、连接质量徽标），由 `MeetingSession.onRemoteCanvasJoined`
  交付，适配自由布局；`ParticipantCanvasContent` 是同一套外观的会话无关版本，供非 SwiftUI 宿主复用。
* `MeetingTimerText(session:style:)`：会议时钟（已用 / 剩余 / 已用+上限），每秒刷新，
  数据来自 `MeetingSession.meetingTiming` 与 `onMeetingTiming`。
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
                onMute: { Task { try? await model.toggleAudio() } },
                onLeave: { Task { await model.hangUp(); dismiss() } }
            )
        }
        .task {
            // 停在 .ready（prejoin）；调 model.join() 才真正入会
            try? await model.start(MeetingRequest(
                connection: ConnectionOptions(serviceUrl: "wss://meet.example.org/xmpp-websocket",
                                              hosts: .init(domain: "example.org", muc: "conference.meet.example.org")),
                conference: ConferenceOptions(name: "room-1", userInfo: UserInfo(displayName: "张三"))
            ))
        }
    }
}
```

`MeetingSession`（`MeetingModel` 是兼容别名）的读侧：`phase`、`connectionStatus`、`isJoined`、
`tiles`、`localMedia`、`isAudioMuted`/`isVideoMuted`/`isScreenSharing`、`isRecording`、`quality`、
`message`、`transcript`、`conference`。写侧：`start(_:)`/`startAndJoin(_:)`、`join()`、
`submitPassword(_:)`、`hangUp()`、`setAudioMuted(_:)`/`setVideoMuted(_:)`、`toggleAudio()`/
`toggleVideo()`、`switchCamera()`、`startScreenShare()`/`stopScreenShare()`、`retry()`、
`setQuality(_:)`、`sendChat(_:)`、`sendJSONMessage(_:to:)`、
`applyVideoConstraints(width:height:frameRate:)`、`videoCapabilities()`、`devices()`、`frames(for:)`。
失败汇到 `message` 与 `phase`，控制类调用直接 `throw`；`onEvent` 额外给出被远端静音/被踢等生命周期事件。

要拿原始状态（比如自定义排序、按角色分区）就直接读 `model.conference`：`participants`、
`localTracks`、`remoteTracks`、`dominantSpeaker`、`joined`，配合 `conference.onStateChange`
（每个事件后触发一次）做失效。

#### 参会者回调、状态变更与逐人音频电平

自定义会议画面不需要轮询 `tiles`：每次快照变化后 `MeetingSession` 都会做 diff 并回调。
`Tile` 就是"一个参会者此刻该画成什么样"，本地与远端用同一个结构（本地 `id == Tile.localID`）：

```swift
session.onParticipantJoined = { tile in
    // 新人（或本端刚入会）：tile.displayName / videoTrackID / avatarURL / email / role
    myStage.insert(tile)
}
session.onParticipantLeft = { tile in
    // 行是最后一份快照，名字头像还在，可以做退场动画后再移除
    myStage.remove(tile.id)
}
session.onParticipantChanged = { tile, change in
    if change.contains(.microphoneMuted) { badges[tile.id] = .muted }
    if change.contains(.cameraMuted)     { hideCamera(tile.id) }
    if change.contains(.speakingStarted) { ring(on: tile.id) }
    if change.contains(.speakingStopped) { ring(off: tile.id) }
    if change.contains(.dominantSpeakerChanged) { promote(tile.id) }
    if change.contains(.videoTrackChanged) { rebind(tile.id, to: tile.videoTrackID) }
}
```

`ParticipantChange` 是 `OptionSet`：`microphoneMuted/Unmuted`、`cameraMuted/Unmuted`、
`speakingStarted/Stopped`、`dominantSpeakerChanged`、`raisedHandChanged`、`videoTrackChanged`、
`profileChanged`。音频电平每 ~200 ms 一跳，但只在跨越说话阈值时才合并成 `speaking*`，
所以用回调驱动 UI 不会被逐帧唤醒。

读侧字段：`tiles[].audioMuted`、`tiles[].videoMuted`、`tiles[].audioLevel`（0...1，静音时为 0）、
`tiles[].isSpeaking`（`!audioMuted && audioLevel >= MeetingSession.speakingThreshold`，阈值 0.05）、
`tiles[].videoTrackID`。`session.audioLevels` 是 `[ParticipantID: Double]` 的汇总；
要自己画没节流的电平条就接 `onAudioLevel = { id, level in ... }`。远端电平来自
RTPStatsCollector（`TRACK_AUDIO_LEVEL_CHANGED`），本地来自 `startLocalStats`，都已在 JS 侧开启。

自定义整屏会议画面用 `MeetingLayout.room`（见 4.3），这些回调在自带布局里同样可用；
不写布局时 `VideoGrid` 已内建描边 + 音量条 + 摄像头关闭图标。

#### 自由布局画布（`ParticipantCanvas`）

`tiles` 适合网格，但完全自由的布局（拖动、缩放、分页、按角色排位）更适合直接拿“一个人一块画布”。
`MeetingSession` 在每个远端出现/消失时回调一次，交付一个自更新的 `ParticipantCanvas`：

```swift
session.canvasStyle = ParticipantCanvasStyle(videoFillMode: .fill, cornerRadius: 10)
session.onRemoteCanvasJoined = { canvas in
    canvases.append(canvas)                 // 保存值即可，不需要自己 diff
}
session.onRemoteCanvasLeft = { id in
    canvases.removeAll { $0.id == id }
}
// 本端：始终可用，不需要等回调
let me = session.localCanvas()

// 布局里按 frame / position 自由摆放；晚订阅或视图重建后按 id 取回同一块画布
let canvas = session.canvas(for: id)
canvas?
    .frame(width: 220, height: 124)
    .position(x: 110, y: 300)
```

`ParticipantCanvas` 内部 `@ObservedObject` 订阅会话，所以视频帧、静音、说话描边、举手、连接质量
（左上角三格徽标）都会自己跟着变；摄像头关闭时显示头像占位，和参考客户端一致。需要用现成样式但
自己控制某个人的外观时，用 `.style(_:)` 复制一份（不影响 `canvasStyle` 默认值）：
`avatarPlacement` / `avatarSize` 控制摄像头关闭时头像的位置与直径，`namePlacement` /
`nameFontSize` 控制底部说明行（麦克风电平 + 名称）的位置与字号。位置值是 `.center` /
`.topLeading` / `.topTrailing` / `.bottomLeading` / `.bottomTrailing`。改名后
`canvas.displayName` 仍是交付时的名字，实时名字用 `canvas.tile()?.displayName`。
`canvas(for:)` 供“晚订阅”的场景（比如视图重建后按 id 找回），本端用 `localCanvas()`。

底层 `ParticipantCanvasContent(participant:isLocal:style:frames:)` 是不依赖会话的纯渲染，
给非 SwiftUI 宿主（ObjC 门面、UIKit 容器）复用同一套外观。

#### 远端媒体变化与“主持人全体静音”

```swift
session.onRemoteMediaChanged = { change in
    // change.participantID / displayName / mediaType / isMuted
    // 只报“变化”，首帧的初始状态随 onParticipantJoined 的 Tile 一起给出
}
session.onHostMuteAll = { batch in
    // batch.mediaType == .audio / .video, batch.participantIDs 是被静音的人
    showBanner("主持人已静音 \(batch.participantIDs.count) 人")
}
session.onAVModerationChanged = { change in
    // 房间级开关（权威信号）：change.isEnabled / mediaType / actorID / actorDisplayName
}
```

静音语义与 lib-jitsi-meet 一致：没有该类型的 track 视为静音，presence 早于 track 到达时先按静音
展示，track 到了再翻转（`tracks[].muted` 折叠，见 4.4 的事件侧说明）。

**`onHostMuteAll` 是启发式**：LJM 没有“主持人静音所有人”的房间级事件，远端 track 静音也不带 actor，
所以 SDK 把 800 ms 内 ≥2 人的同类静音合并成一批回调。多人几乎同时自己关麦也会命中。
需要精确到人就用 `onRemoteMediaChanged`；需要房间级权威信号就用 AV moderation
（`onAVModerationChanged`，主持人开启后会锁住自助开麦直到单独授权，`onAVModerationSelfChanged`
回调本端被授权/拒绝）。

#### 会议时长与时限

会议时间以服务端为锚：MUC disco#info 的 `muc#roominfo_created_timestamp`（毫秒）优先，
`mod_time_restricted` 发来的房间级 `{type:"time_restricted",durationSeconds,elapsedSeconds}`
次之，两者都没有时退回本地入会时刻。时限同理：服务端下发的时限优先，其次才是宿主在
`MeetingRequest.meetingTimeLimit` 里给的展示值。没有时限的部署只显示已用时间。

```swift
session.onMeetingTiming = { timing in           // 入会握手后回调一次
    // timing.startedAt / startSource / timeLimit / limitSource / limitStartedAt
    print(timing.elapsed(at: Date()), timing.remaining(at: Date()) as Any)
}
session.meetingTiming                            // @Published，可随时读
session.elapsedSeconds(at: Date())
session.remainingSeconds(at: Date())             // 无时限时为 nil

MeetingTimerText(session: session)               // 每秒刷新的现成文本
MeetingTimerText(session: session, style: MeetingTimerStyle(mode: .remaining))
```

回调只发一次：服务端时间戳与时限都到齐就立即发，否则等入会 2 秒（给 disco#info 与时限消息留出
到达时间）后按已有信息发一次快照；之后再有时间信息只更新 `meetingTiming`，不会二次回调。
`MeetingTimerText` 在 `meetingTiming` 为空时渲染空串，可以放在入会前就存在的头部栏里。

### 4.3 入会流程与扁平控制（`MeetingSession` / `MeetingContainer`）

`MeetingSession` 把“连服务器 → 是否入会（prejoin）→ 是否进等候室 → 密码/主持人放行 → 入会 →
生命周期 → 结束”收敛成一个 `phase`，不再需要层层回调：

| `phase` | 含义 | UI 该做什么 |
| --- | --- | --- |
| `.idle` / `.connecting` | 未开始 / 正在建立信令连接 | 加载页 |
| `.ready` | 已连接、采集已打开，但还没发布到房间 | prejoin：预览、选设备、初始静音 |
| `.joining` | 正在入会 | 加载页 |
| `.waitingInLobby(LobbyAdmission)` | 等候室等待；`.moderatorApproval` 等审核，`.waitingForHost` 等主持人开房 | 等候页 |
| `.passwordRequired(isRetry)` | 房间需要密码；`isRetry` 表示上次密码错误 | 密码输入页 |
| `.joined` | 已入会 | 会议界面 |
| `.reconnecting(attempt:maxAttempts:)` | 断线自动重连中 | 会议界面 + 提示条 |
| `.ended(MeetingEndReason)` | `.leftByUser` / `.kicked` / `.replacedByAnotherSession` / `.endedByHost` / `.connectionLost` | 结束页（`leftByUser` 通常直接关闭） |
| `.failed(message:)` | 不可恢复的失败 | 错误页 + `retry()` |

```swift
let session = MeetingSession()
try await session.start(request)        // 停在 .ready，这就是 prejoin 时机
try await session.join()                // 或 session.startAndJoin(request) 一次走完
// 等候室中：session.phase == .waitingInLobby(...)
// 收到密码要求：try await session.submitPassword("123456")
await session.hangUp()
```

入会阶段全是可跳过的：`autoJoin: true` 会跳过 prejoin；不调用 `join()` 就一直停在本机预览；
`cancelJoin()` 从任何入会前阶段退出。

扁平控制 API（失败统一 `throw`，不再各自维护错误回调）：

```swift
try await session.setAudioMuted(true)   // 麦克风
try await session.setVideoMuted(true)   // 摄像头
try await session.toggleAudio()
try await session.toggleVideo()
try await session.switchCamera()        // 前后摄像头，保留轨道与 sender
try await session.startScreenShare()
await session.stopScreenShare()
await session.hangUp()                  // 等价于原 leave()
try await session.endMeetingForAll()
```

音频输出路由（`AudioOutputRoute` 返回真实路由，写入只接受内置的 `receiver`/`speaker`）：

```swift
let route = await session.audioOutputRoute()   // receiver/speaker/headphones/bluetooth/carPlay
session.setAudioOutputRoute(.speaker)          // 外接耳机/蓝牙/CarPlay 连接时仍由系统优先
session.onEvent = { event in
    if case .audioOutputRouteChanged(let route) = event {
        // 耳机插入、蓝牙连上或断开；同步更新扬声器按钮
    }
}
```

远端强制静音不会静默丢失：`onEvent` 会收到 `.microphoneMutedByHost` / `.cameraMutedByHost` /
`.screenShareMutedByHost`，`localMedia` 同步更新，按钮状态跟着变；被踢出会走
`.ended(.kicked(actor:message:))`，断线重连则走 `.reconnecting`，再失败才 `.ended(.connectionLost)`。

只想换掉流程中的某一屏时，用 `MeetingLayout` 覆盖对应 slot，其余继续用内置实现：

```swift
var layout = MeetingLayout.standard
layout.prejoin = { session in AnyView(MyPrejoin(session: session)) }
layout.waitingInLobby = { session, admission in AnyView(MyLobby(session: session, admission: admission)) }
layout.room = { session in AnyView(MyRoom(session: session)) }   // 整块替换，需自带挂断
JitsiMeetSDK.meetingContainer(request: request, layout: layout)
```

### 4.4 完全自研：不经 `MeetingModel`

```swift
@MainActor
final class MyStore: ObservableObject {
    @Published var speaking: [ParticipantID: Double] = [:]
    @Published var muted: Set<String> = []          // "participantID/mediaType"
    @Published var breakoutRooms: BreakoutRoomsState?

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
        case .breakoutRoomsUpdated(let state):             // 分组讨论房间列表
            breakoutRooms = state
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
`recordingStateChanged`/`e2EEStateChanged` 的原始 payload，以及 `raw` 里的 40 个未建模事件。

UI 层现状（写自定义界面时会踩到，按需要自己补）

* `switchCamera()` 只在前后摄像头之间切换，保留原轨道与 sender（原生换 input，不重新协商）；
  想切到指定设备仍然走 `conference.removeTrack(_:)` + `capture([.video], deviceIDs: ["video": uniqueID])`。
* `isAudioMuted`/`isVideoMuted` 只在 `start` 时同步一次，被 moderator 远端强制静音时按钮图标不会跟着变。
  自研 store 应该订阅 `trackMuteChanged` 与 `participantMuted` 自己维护。
* `tiles` 每次重算都是全量重建（`participants` 排序 + 本地轨道 + 孤儿远端轨道）。几十人以内的会议没问题；
  大房间请自己按 `dominantSpeaker`/`lastN` 做可见性裁剪，`MeetingEvent.raw` 里的
  `lastNEndpointsChanged` 就是为此准备的。

### 4.5 跑起来的 demo（`JitsiMeetExample` + `JitsiMeetDemoApp`）

`Sources/JitsiMeetExample` 是上面那条"完全自研"路线的参考实现，刻意**不用** `VideoGrid`/`ControlBar`
（只用 `ChatView`、`VideoSurface` 和 `MeetingModel`）：

* `DemoMeetingScreen`：自适应 1/2/3 列网格、状态胶囊（连接状态/质量/当前说话者/录制点/轨道数）、
  可折叠事件控制台、自研 dock（麦克风、摄像头、举手、码率菜单、聊天、挂断）。
* `DemoMeetingPanes`：参会者面板（角色/举手/远端静音/踢人）、投票面板（创建、投票、结果计数）、
  字幕浮层、邀请分享（系统 share sheet）。
* `LevelStore`：不经 `MeetingModel` 的自研 store，把 `audioLevels`、`participantMuted`、
  `dominantSpeakerChanged`、`participantLeft` 和 `breakoutRoomsUpdated` 归约成音量环、
  远端静音集合与日志窗口；没有引擎也能跑，所以单测直接喂事件（`TestSupport.StubEngine` 补引擎路径）。
* `JitsiMeetDemo`：`bootstrap`/`connection`/`conference`/`screen`，以及给 UIKit、OC 宿主的
  `viewController(...)`（`UIHostingController` 包装）。

```bash
# 组装 .app（SwiftPM 的模拟器可执行文件没有 bundle），装到模拟器并自动入会
DEMO_AUTOJOIN=1 ./Scripts/make-demo-app.sh --device <simulator-udid>
xcrun simctl io <simulator-udid> screenshot /tmp/demo.png

# 覆盖 host/房间等再启动（脚本只内置 AUTOJOIN，其余变量自己加 SIMCTL_CHILD_ 前缀）
SIMCTL_CHILD_JITSI_DEMO_AUTOJOIN=1 \
SIMCTL_CHILD_JITSI_DEMO_ROOM=jitsi-swift-demo-$(date +%s) \
  xcrun simctl launch <simulator-udid> org.jitsi.swift.demo
```

默认 host 是自建部署 `https://tmeeting.maesgroup.com:8443`，默认房间 `teambind`：按其
`config.js` 推导 `hosts.domain = meet.jitsi`、`hosts.muc = muc.meet.jitsi`，该部署没有
`hosts.anonymousdomain`（访客按 `meet.jitsi` 登录），传输默认 WebSocket
（`wss://tmeeting.maesgroup.com:8443/xmpp-websocket`）；同一 host 的 `/http-bind` 也在 config.js
里声明，需要 BOSH 时只改首屏 Transport 一项。公开部署 `https://meet.jit.si` 仍可一键切回：
填 host 后匿名域只在 Host 解析出的 XMPP 域**精确等于** `meet.jit.si` 时推导为
`guest.meet.jit.si`。切回公开部署时注意两点（2026-11-11 实测）：该部署的
`/http-bind` 由 Cloudflare + HAProxy 在多 shard 间无粘性分发，BOSH 握手会偶发 `item-not-found`
（同一 HTTP 连接内复测可稳定完成 SASL），所以默认用 WebSocket；并且**匿名房间是 members-only**：
guest 能建立 XMPP、拿到 focus 分配的会议，但 MUC 入会返回 407 `registration-required` +
`waiting-for-host`（附 lobbyroom），SDK 表现为 `conference.connectionError.membersOnly`。这是部署
策略——房间必须由已登录的主持人创建或批准，guest 只能 `joinLobby(displayName:email:)` 进等候室。
`MeetingModel` 现在按上游 jitsi-meet 的路径自动处理：收到 `membersOnly` 后立即用入会时的
display name/email 敲门，`isWaitingInLobby` 置位、Demo 显示等待卡片。注意 407 带
`waiting-for-host` 时（`isWaitingForHost`）走的是部署侧的 persistent lobby：**没有“主持人审批”这一步**，
已登录主持人开房时 Prosody 销毁 lobby 并把里面的人自动放进主房间，卡片刻意提示“等待主持人开始会议”。
普通等候室（主持人手动开启 lobby）才会出现在主持人的 lobby 列表里，放行后 lib 自己把同一个 conference
加入主房间并发 `CONFERENCE_JOINED`，等待态随之清除，不需要再次点加入。
如果主持人在线时房间仍未开、或访客被拒绝，走的是 `accessDenied`，等待态清除并提示重试。
敲门与失败原因会以 `[sdk][lobby]` 打在 Xcode 控制台（lobby JID、waitingForHost、失败文本，不含凭据），
联调时先看这几行就能区分“没进 lobby”和“进了但没人放行”（见 §12.3）。
完整功能验证仍需主持人账号/JWT（见 §12.3）。
首屏因此有 Host / XMPP domain / MUC domain / Transport 四项，全部走 `@AppStorage` 持久化；
换服务器时按对方 `config.js` 填；匿名域仅对 meet.jit.si 自动推导，其他部署留空（避免误命中
`meet.jit.si.example.org` 这类相似域）。
Conference 区还有 Display name / Email / Avatar URL，三者进入 `UserInfo` 随入会 presence 一起发出
（第 7 节），空串按“不设置”处理。另有 Room password 一行（`SecureField`），非空时写入
`ConferenceOptions.password`，由 lib 在 MUC join presence 的 `<x xmlns="muc">` 里带
`<password>`。Prosody 的 `mod_muc_lobby_rooms` 在 lobby 判定之前先校验密码：**密码正确会直接
授予 member 并放入主房间，完全不进等候室**；密码缺失/错误才落到 407 与 `joinLobby` 路径。
没有密码就会收到 `conference.passwordRequired`，`MeetingModel` 暴露 `requiresPassword` 并提示
“This room requires a password.”，不自动重试也不敲门，等宿主带 `ConferenceOptions.password`
重新加入（见 §12.3）。Room 值本身会按 jitsi-meet 的规则归一化（URL 解码 → NFKC → 小写 →
`encodeURIComponent`，见 §12.2），所以从浏览器地址栏直接复制的房间名即使含大写，也会落到
浏览器所在的同一个 MUC，而不会在本地报 `Invalid conference name`。
"Auto join on launch" 打开后每次启动直连，真机反复 attach 调试器时不用重新填表（第 10 节）。
模拟器摄像头没有画面源（`FigCaptureSourceSimulator err=-12784`），采集会成功但不出帧，本地 tile 因此是一块黑色；
真机才能看到自画面。

无头回归用的环境变量（配合 `SIMCTL_CHILD_` 前缀传给 `simctl launch`）：

| 变量 | 作用 |
| --- | --- |
| `JITSI_DEMO_HOST` / `JITSI_DEMO_DOMAIN` / `JITSI_DEMO_MUC` / `JITSI_DEMO_TRANSPORT` | 覆盖首屏的 Host / XMPP 域 / MUC 域 / 传输方式（`auto`、`websocket`、`bosh`；首屏默认 `auto`） |
| `JITSI_DEMO_CONNECT_TIMEOUT` | 覆盖 `ConnectionOptions.connectTimeout`（秒；`0` 表示不设截止），用来复现慢网络下的连接行为 |
| `JITSI_DEMO_ROOM` / `JITSI_DEMO_NAME` | 覆盖房间名 / 昵称（`@AppStorage` 存在 app 容器里，`simctl spawn defaults` 够不到） |
| `JITSI_DEMO_PASSWORD` | 覆盖房间密码，脚本化进入密码保护的房间（正确密码会跳过等候室） |
| `JITSI_DEMO_AUTOJOIN=1` | 启动即入会，跳过点击 |
| `JITSI_DEMO_DEBUG=1` | 打开信令与桥接日志 |
| `JITSI_DEMO_STATS=1` | 每 10 秒打印双向音频 RTP 字节数与接收侧音频能量（`inbound-rtp.totalAudioEnergy`），用来客观判定“有没有声音” |
| `JITSI_DEMO_MUTE_CYCLE=<n>` | 入会 20 秒后每 12 秒切换一次麦克风，共 n 次，并打印 `[demo-mute]` 行，用来验证静音在多方会议里的传播 |
| `JITSI_DEMO_VIEWER=1` | 不采集任何本地轨道（纯观众）。两人房只剩这类客户端时 P2P 仍由它们协商，用来回归“关麦关摄像头入会” |
| `JITSI_DEMO_START_MUTED=1` | 走预加入路径：先采集、再静音音视频、然后入会，等价于首屏关着麦和摄像头点 Join |

改完环境变量记得先 `simctl terminate`：`simctl launch` 会复用已在跑的进程，环境变量不会重新注入。

Objective-C 集成方看 `DemoObjC/`：同一套 `JITSI_DEMO_*` 自动化入口（`JITSI_DEMO_URL` 取代
`JITSI_DEMO_HOST`/`TRANSPORT`），外加参会者列表与逐人音量条，只依赖 xcframework + CocoaPods 的
`JitsiWebRTC`，见 `DemoObjC/README.md`。

### 4.6 连接与信令排查（debug 模式）

`SDKConfig.debugSignaling = true` 会打开完整链路日志：

```swift
let config = SDKConfig(
    region: .chinaMainland,
    debugSignaling: true        // 同时把 lib-jitsi-meet 调到 DEBUG
)
// 或走 LJM 的级别（LogLevel 枚举），但不会抓原始帧/ stanza：
// SDKConfig(logLevel: .debug)
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

# 2) 编译校验
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --build-tests --triple arm64-apple-ios15.0-simulator --sdk "$SDK"

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

`check-js-shims.swift` 做四件事：加载全部 shim 并跑 49 条行为断言（DOM/XML、Strophe 的 `:scope`
查询、XML 大小写保留、WebSocket、XHR、fetch、RTCPeerConnection、getUserMedia、`new MediaStream(tracks)`、
navigator 身份、localStorage、crypto、setTimeout→native、Blob/URL、polls/举手/token 刷新方法表、
身份 presence 能否在 join 前写入 room 的 presence map），
其中两条是**异步**的：把 runloop
泵起来，要求 `__sdkSettle('lib.init')` 真的 resolve、未知方法真的 reject——同步断言看不见一条永不落地的 Promise；
再用真实产物构造 `JitsiConnection` 与
`JitsiConference`，核对 facade 解引用的每个 lib 成员是否存在；再核对 facade 里每个 `on('EVENT_NAME')`
都在 lib 的事件枚举中；最后交叉核对两张表——`JSMeetingEngine.swift` 里 `invoke("x.y")` 的每个方法都必须
存在于 `__sdkMethods()`，reducer 里每个 `case "name"` 都必须由 facade 真正 `emit` 过。名字对不上在 JS 侧
只会变成运行时 rejection 或被静默跳过的监听器，所以把它们都变成 FAIL。另有一条走完整 facade 路径的
异步检查：用假的 `JitsiConnection` 跑 `connection.connect` + `conference.join(userInfo)`，断言房间上
依次写入了 `nick`、`avatar-url`、`email` 和 `jitsi_participant_*`，再触发 facade 注册的两个
presence 命令监听器，断言 `participantAvatarChanged` / `participantEmailChanged` 带着参与者 id 和值
进入事件通道——命令名写错或监听器漏注册都会直接 FAIL。最后一条异步检查跑主持人控制：
`end`/`lock`/`unlock`/`grantOwner`/`revokeOwner`/`setSilent`/`setSubject`/`setStartMutedPolicy`
必须带着 Swift 参数名落到对应的 lib 调用（含 `setIsSilent` 的命名映射、`revokeOwner` 接受本地 id），
并断言触发 `LOCK_STATE_CHANGED` 后 `conference.state().isLocked` 与入会静音策略能被读回。
最后一条异步检查覆盖本地属性、等候室与 AV moderation：`setLocalParticipantProperty` 写入 `string[]`
后本地镜像必须原样读回（不能被 lib 的字符串 getter 拉平），删除后回落到 lib getter；等候室
approve/deny/message 必须映射到 `lobbyApproveAccess`/`lobbyDenyAccess`/`sendLobbyMessage`；
AV moderation 四个调用必须落到 `avModerationApprove`/`avModerationReject`；并断言
`PARTICIPANT_PROPERTY_CHANGED`、`PROPERTIES_CHANGED`、`LOBBY_USER_*`、`AV_MODERATION_*`
都被重组成 Swift reducer 认识的 façade 事件（含 lobby 增量合并与 actor id 提取）。
最后一条异步检查覆盖分组讨论：`BREAKOUT_ROOMS_UPDATED` 的 map 必须拍平成数组、管理四调用必须
落到 `getBreakoutRooms()` 并以完整 JID 调用；`conference.switch` 必须以 `switch_room` 离开旧房间、
带 `customDomain` 重建 conference、重挂已附加轨道并重新写入本地属性，且旧房间的瞬时
`CONFERENCE_LEFT` 不能变成 `conferenceLeft` 事件。
另一条异步检查覆盖通用信令：`sendCommand`/`sendCommandOnce`/`removeCommand` 必须落到同名 lib
方法，`addCommandListener` 注册后触发的 presence 节点要重组成 `commandReceived`（属性拍平、保留
`value`/`children`），`sendEndpointMessage`/`sendReaction` 必须走各自的 lib 路径而不是聊天消息，
并断言 `REACTION_RECEIVED` 映射成带 reactions 数组与 messageId 的 `reactionReceived`。
倒数第二条覆盖 P2 事件通道：22 个统计/可见性事件必须按各自载荷到达 `sdk.event`（含会议级
`CONNECTION_ESTABLISHED` 与连接层同名事件不混淆、`PHONE_NUMBER_CHANGED` 读取 `getPhoneNumber()`、
统计 Map 压平、`VISITORS_REJECTION` 空载荷）。最后一条覆盖生命周期事件：`KICKED` 必须带
`actor`/`reason`/`replaced`，焦点静音（lib 没有公开事件）在轨道静音后 100 ms 复检
`isMutedByFocus` 并发出 `localMutedByFocus {mediaType, desktop, actor}`——脚本会泵 `timer.fire`，
否则这两条断言永远停在等待态。

## 6. lib-jitsi-meet 产物在资源里的位置

`Sources/JitsiJSRuntime/Resources/js/99-lib-jitsi-meet.bundle.js` 是真正的 webpack UMD 产物
（1.04 MiB；构建链：`npm ci` → `gen-version` → `webpack`；没有跑 `build:tsc`，它只产 `.d.ts` 且会被无关
类型错误拖挂）。同目录 `98-lib-jitsi-meet.LICENSE.txt` 是压缩头注释指向的第三方许可证文本；两者都由
SPM 的 `.copy("Resources/js")` 整目录搬进 `JitsiMeetSDK_JitsiJSRuntime.bundle/js/`，宿主按文件名序加载，
`.txt` 不会被当成脚本。产物尾部两行注释记录了源目录与构建时间，替换时以 `git rev-parse` 为准。

webpack 同时产出 `dist/umd/lib-jitsi-meet.e2ee-worker.js`（18 KB）。E2EE 阶段才需要它，现在**没有**安装进
资源目录，脚本会提示它的存在。

## 7. lib-jitsi-meet 功能覆盖

facade 暴露 88 个方法（Swift 侧调用 84 个），`MeetingEvent` 建模 71 类事件，其余 31 个 emit 名走
`MeetingEvent.raw`（统计、认证状态、桥接通道、字幕状态等），需要时按事件名
提升为强类型 case，不需要改桥。

本版本 lib 的几个签名与直觉不同，facade 已按真实 API 处理，改动时别退回旧写法：
* `JitsiConnection` 只有 `addEventListener`，没有 `on`（`on` 只在 `JitsiConference` 上）。
* `mediaDevices.enumerateDevices(callback)` 是回调式，不是 Promise；`isDeviceListAvailable` 已被移除。
* 本地发送分辨率是 `setSenderVideoConstraint(h)`，不存在 `setLocalVideoQuality`。
* `RECORDER_STATE_CHANGED` 的唯一参数是 `JibriSession`（`getStatus/getMode/getID/getError`），
  录制与直播共用这一个事件；`stopRecording(sessionID)` 要的是会话 id，所以 `startRecording` 会记住会话。
* 主持人控制：lib 没有 `setSilent`，真实方法是 `setIsSilent(silent)`；`lock(password)` 返回
  Promise，且**没有** `isLocked()` getter，锁状态只能从 `LOCK_STATE_CHANGED` 镜像（facade 存在
  `state.locked`，`conference.state().isLocked` 由此读出）；`end()` 返回 void，调用前必须以
  `isEndConferenceSupported()` 判断部署是否支持。
* 等候室：lib 的审核方法叫 `lobbyApproveAccess`/`lobbyDenyAccess`（不接受空 id），自己的 id 是
  `myLobbyUserId()` 而不是 `myUserId()`；`sendLobbyMessage(message, id)` 的 id 传空串表示广播。
* AV moderation 的媒质是 `audio|video|desktop` 三值，比 Swift 的 `MediaType` 多 `desktop`，所以用独立的
  `AVModerationMediaType`；`AV_MODERATION_CHANGED` 的 actor 是 participant 对象，facade 只透传 id。
* 分组讨论：管理方法在 `conference.getBreakoutRooms()` 返回的对象上（不是 conference 本身），且非主持人
  或部署没装组件时**静默 no-op**，所以 facade 先判 `isSupported`/`isModerator` 并抛错；房间 JID 是
  `node@breakout.domain`，切房间时要拆成 MUC 名 + `configOverwrite.customDomain`。
* 通用信令：`addCommandListener(name, handler)` 的 handler 收 `(presenceNode, participantId, from)`，
  节点形如 `{ tagName, attributes, value?, children? }`；facade 把 `attributes` 拍平进
  `commandReceived.values`，`value`/`children` 按需保留。监听器挂在 room 上，重连/切房间重建
  conference 后必须重挂（facade 用 `state.commandListeners` 记住并自动补挂）。
* 表情：`sendReaction(reaction, messageId, receiverId)` 的 `receiverId` 传空串才是广播；lib 在
  `ChatRoom.sendReaction` 里校验 emoji，非表情会抛错。`REACTION_RECEIVED` 的参数是
  `(participantId, reactions[], messageId)`，不是单个字符串。
* 聊天事件签名：`MESSAGE_RECEIVED = (participantId, text, ts, displayName, …)`，
  `PRIVATE_MESSAGE_RECEIVED = (participantId, text, ts, messageId, displayName, …)`；没有旧版的
  `isPrivate` 位置参数，facade 按事件名区分群聊/私聊。
* Strophe 发原始 stanza 用 `connection.send(node)`，节点由 DOM shim 的 `DOMParser` 生成（走
  `createElementNS` 路径，因此保留标签大小写）。


已接通：连接/XMPP 登录（token 与 user/password）、加入/离开会议、会议密码与 lobby、
昵称/头像/邮箱身份发布、本地轨道创建与增删、静音（本地、接收端订阅、版主强制）、改名、前后摄像头切换、
聊天（纯文本与结构化 JSON 对象）、通用 presence command、endpoint message 与表情反应、踢人、录制（stream/file/YouTube）、`lastN`、
分辨率与接收端码率约束、运行期采集约束（`videoCapabilities`/`applyVideoConstraints` 原地切
`activeFormat` 与帧率，不重建轨道）、设备枚举与切换、dominant speaker、参与人与角色事件、
连接质量、统计（`conference.stats` 走 `getStats()` 原始记录）、原始 XMPP 命令、
任意 presence command 的发送/监听（`sendCommand`/`sendCommandOnce`/`removeCommand` +
`addCommandListener` → `commandReceived`）、数据通道 `sendEndpointMessage`、
XEP-0459 表情（`sendReaction` → `reactionReceived`）、
屏幕共享（ReplayKit，见下）、本地举手、
投票（Prosody polls 组件）、实时字幕（transcription endpoint message）、
XMPP resume 的 token 刷新（`JitsiConnection.refreshToken`）、P2P 的显式 STUN/TURN 配置、
主持人控制（结束会议、房间加锁/解锁、转让/收回主持人、静默入会、设置主题、入会静音策略）、
本地参会者属性（`string[]` 原样保留）、jicofo 房间属性、等候室审核与消息、AV moderation、
分组讨论（房间列表、创建/改名/删除、指派参会者、同连接切换主/子房间，默认跟随
`breakoutRoomsMoveToRoom`）、
连接区域/分片信息（`serverRegion`/`serverShard`）。

结构化 JSON 消息收发都会打印 `[sdk][json-message] send to …` / `[sdk][json-message] recv from …`
（JS `console` 经 `log.write` 落到 Xcode 控制台），联调不需要打开 signaling tracing。

断线恢复与网络状态：

* **断线重连（P0）**：传输层真断时 lib 报 `CONNECTION_FAILED` 且 `connection.droppedError` 为真，
  SDK 把它收敛成 `connectionLost`。`MeetingModel` 与 `JitsiObjC` 都会在后台原地重建整条链路：
  `resetForRejoin → connect → prepareConference → 重新采集并恢复静音状态 → joinConference`，
  1.5s 起步、带抖动的退避，连续失败 3 次后提示“重新入会”。
  还能走 XEP-0198 resume 的传输仍由 lib 自己恢复，不会触发这条路径（默认的 WebSocket 会先尝试
  resume，失败才升级为重连）。
* **重连以入会事件为准**：`conference.join()` 在 MUC 入会还在路上时就返回，早期版本因此在入会实际
  失败时也把重连标成成功、清空重试计数。重连现在带 `waitForJoin`，只有 `CONFERENCE_JOINED` 才 resolve，
  `CONFERENCE_FAILED`/`CONFERENCE_LEFT` 或 15s 超时都会 reject，失败会真正进入下一次尝试。首次入会
  仍不等事件。若重连落到 members-only 房间，`waitForJoin` 的失败不再消耗重试配额：并发的
  `CONFERENCE_FAILED` 会触发下一节的自动敲门，重连循环直接退出并停在等待态。
* **抖动阻尼**：成功重连不再立刻把退避清零，而是要求连接稳定 30s 才回落。Wi-Fi 与蜂窝反复切换时，
  每掉一次退避就抬高一档（1.5s → 最高 6s 基值、含抖动），界面提示“Network unstable, reconnecting…”，
  避免“每 30 秒掉一次、每次都 1.5s 重连”的死循环。三次上限只统计**连续失败**，成功过的抖动不会把
  用户锁进终态；真正耗尽次数时会 `disconnect()` 释放音频会话再提示重进。
* **释放媒体栈**：掉线路径不再只是忘掉 conference。JS 侧的 PeerConnection 注册表会在
  `connectionLost`/`disconnect`/`lib.dispose` 时统一 `pc.close`，否则 `JingleSessionPC` 得不到
  `leave()`、原生 peer（编解码器、ICE agent）会在每次掉线后泄漏一个。
* **重连不拆音频会话**：`resetForRejoin()` 只断信令，不 deactivate `AVAudioSession`；重连周期通常只有
  几秒，反复 deactivate/activate 会引起路由切换与音频中断。只有 `leave()`、完整 `disconnect()` 和重连
  次数耗尽时才真正释放。采集的“停”也改成串行队列：停摄像头的 native 调用是异步的，门控放行后可能
  立刻重开采集，`getUserMedia` 会先等上一次 stop 落地，避免相机占用导致重连白白失败一次。
* **网络门控（P1）**：`JSMeetingEngine` 用 `NWPathMonitor` 把可达性同时送进 lib 的
  `setNetworkInfo({isOnline})` 和 Swift 的 `networkChanged(online:)` 事件。离线时重连**不消耗**次数，
  界面显示“等待网络…”，路径恢复后立刻发起下一次尝试（最长等待 30s 后仍会尝试，避免受限内网
  被判为不可达时永远不重试）；`MeetingModel.isNetworkOnline` /
  `JitsiObjC` 状态字典的 `isNetworkOnline` 可直接驱动断网提示条。
* **重连前刷新 JWT**：`performRejoin` 在 `connect` 之前调用 `tokenProvider`，用新 token 重建
  `ConnectionOptions`。JWT 通常比会议寿命短，复用首次入会的 token 会让恢复后的每次鉴权都失败；
  lib 的 `tokenExpired` 只在 resume 时触发，覆盖不到这种场景。OC 门面的 provider 必须回调
  （返回 nil 表示沿用旧 token），否则重连会停在等待处。
* **恢复会话状态**：重连成功后重新写回本地举手、`setQuality` 选定的发送分辨率、接收策略
  （`maxHeight`/`lastN` 在新建 PeerConnection 上不存在，必须重推）以及屏幕共享轨道
  （广播扩展会在下一帧自动重连 App Group socket）。
* **token 过期**：resume 期间 JWT 过期时 lib 发 `tokenExpired`。Swift 宿主设
  `MeetingModel.tokenProvider = { await auth.currentJWT() }`，OC 门面设 `tokenProvider` block
  （主线程回调，返回 nil 表示拿不到）。lib 给 3 秒窗口，超时或返回 nil 则 resume 作废、连接断开，
  再由上面的全量重连兜底。
* **连接代次隔离**：被替换的 `JitsiConnection` 仍会补发 Strophe 的迟到回调。JS 门面按
  `state.connection === connection` 丢弃旧连接的事件，`connection.disconnect` 也会清空连接与本地轨道，
  避免旧响应的 `droppedError` 在健康会话上再触发一次全量重连、或离会后摄像头麦克风仍在采集。
* **生命周期与手动重试**：宿主把 `scenePhase == .active` 传给 `MeetingModel.setAppActive(_:)`
  （`MeetingView` 与 Demo 已内建；`JitsiObjC` 有同名方法）。只有“入过会 → 退到后台 → 回前台且当前
  不在会中”才会补发一次带退避的重连：`isJoined` 为真的健康通话、首次入会与 lobby 等待（还没收到过
  `CONFERENCE_JOINED`）都保持原样，仍在跑的自动重连也不会被重复启动。服务端 5xx、BOSH 499/400 和
  Prosody 主动断开不属于 `connection.droppedError`，SDK 不做自动重试，宿主用 `retryConnection()`
  （两个门面都有）手动发起，复用同一套退避、JWT 刷新与状态恢复；`canRetryConnection` 可直接驱动
  “重试”按钮。

投票、字幕与举手都不需要新桥层：

| 能力 | 入口 | 说明 |
| --- | --- | --- |
| 举手 | `MeetingModel.toggleHand()` / `JitsiConference.raiseHand(_:)` | 写 `jitsi_participant_raiseHand` presence 扩展；所有 jitsi-meet 客户端都能看到 |
| 用户资料 | `ConferenceOptions(name:userInfo:)` / `UserInfo(displayName:email:avatarURL:extras:)` | 发送：入会 presence 一次发出；接收：`ParticipantSnapshot.avatarURL/email`、`Tile.avatarURL/email`；见下方协议说明 |
| 投票 | `JitsiConference.pollsSupported()/createPoll/answerPoll`，`MeetingModel.polls` | 走 Prosody polls 组件；未部署组件时 `pollsSupported` 为 false，创建会报错 |
| 字幕 | `MeetingModel.captions/transcriptionActive` | 订阅 `transcription-result`/`translation-result` endpoint message，interim 行按 `message_id` 原位替换 |
| 参会者面板 | `MeetingModel.tiles` 的 `role/isModerator/raisedHand` + `muteParticipant/kick` | 版主操作由服务器校验，非版主会收到错误而不是假成功 |

用户资料协议（`UserInfo`）：lib-jitsi-meet 没有 `setAvatar`/`setEmail`，jitsi-meet 客户端之间用的是
presence 约定。`displayName` 写 MUC presence 的 `<nick>`；`avatarURL` / `email` 用 `sendCommand`
写 `avatar-url` / `email`（jitsi-meet web 端在 `addCommandListener` 里读这两个命令）；`extras` 的每个
键写成 `jitsi_participant_<key>` 扩展，对端用 `getProperty(key)` 读。SDK 在 `conference.join()` **之前**
把这些节点放进 room 的 presence map，所以入会首包就带全，不会先出现服务器分配的随机名再刷新。
`extras` 的键必须是 Strophe 能编码的 XML 名称（ASCII 字母/下划线开头，后接字母、数字、`_`、`-`、`.`），
否则 `joinConference` 抛 `JitsiError.invalidArgument`，不会发出坏 stanza。注意 JWT 登录时，对端
jitsi-meet 以 token 里的 `context.user`（含 `avatar`）为准，presence 里的头像/邮箱只在其后作为补充。

接收侧走同一个约定：facade 在 `wireConference` 里为 `avatar-url` / `email` 注册
`conference.addCommandListener`，把 `(node, participantId)` 归一成 `participantAvatarChanged` /
`participantEmailChanged` 事件；`JitsiConference` 把它们写进对应参与者的
`ParticipantSnapshot.avatarURL/email`，`MeetingModel.Tile` 再透出给 UI。命令被撤回时值为空，
头像/邮箱恢复为 `nil`，UI 退回首字母占位。本地参与者的头像/邮箱直接取自 `UserInfo`。

```swift
let userInfo = UserInfo(
    displayName: "张三",
    email: "zhangsan@example.com",
    avatarURL: "https://example.com/avatars/zhangsan.png",
    extras: ["department": "研发", "employeeId": "A1024"]
)
let conference = try await connection.join(
    ConferenceOptions(name: "room-1", userInfo: userInfo, password: nil)
)
// 已入会后改昵称走 setDisplayName；头像/邮箱目前没有单独的更新入口，
// 与 jitsi-meet 一样在入会前一次性写入 presence。
```

P2P 说明：lib-jitsi-meet 在没有配置时默认使用 `stun:meet-jit-si-turnrelay.jitsi.net:443`。
SDK 总是显式下发 `ConnectionOptions.p2p`（默认空列表），避免连接第三方 STUN；需要直连时填自己的
STUN/TURN，`iceTransportPolicy: .relay` 可强制走 TURN。音频/视频中断通过
`MeetingEvent.connectionInterrupted/connectionRestored` 暴露。

静音/踢人的语义（facade 按真实 API 分派，改之前先看第 11 节）：

| API | 行为 |
| --- | --- |
| `JitsiConference.setAudioMuted` / `setVideoMuted` | 本地轨道 `mute()`/`unmute()` |
| `JitsiConference.setRemoteAudioMuted` | **只**改变本机接收订阅（`muteRemoteAudio`），不发信令、不需要主持人权限 |
| `JitsiConference.muteParticipant(id, .audio/.video, muted:)` | 主持人 IQ，目标是让**对方**静音自己；`muted: false` 在 Jitsi 里不存在，直接报 `unsupported`，不会假装成功 |
| `JitsiConference.kickParticipant(id, reason:)` | `role="none"` 的 IQ，15 秒内等 `sendIQ` 结果，失败会抛错 |

屏幕共享走 ReplayKit：`MeetingModel.startScreenShare()` 创建 LJM 的 `desktop` 轨道，
`RPSystemBroadcastPickerView` 让用户启动 **Broadcast Upload Extension**；扩展用
`ScreenShareBroadcastSender` 把 `CVPixelBuffer` 通过 App Group 里的 Unix socket 发给主 app 的
`ScreenShareReceiver`，再由 `WebRTCBackend` 转成 `RTCVideoFrame` 送进 `RTCVideoSource`。
模板在 `Templates/JitsiBroadcastExtension/`，App Group id 由
`ScreenShareConfiguration.appGroupIdentifier` 统一配置（第 10 节）。

尚未接通（明确 `unimplemented`，不会静默降级）：
* **E2EE**：需要 `createEncodedStreams`（编码帧变换器）+ `crypto.subtle`（CryptoKit 后端）+ Worker 桥。
  相关入口在 `30-webrtc.js` 的 `createEncodedStreams`、facade 的 `conference.e2ee`、
  `NativeRouter.swift` 里 `worker.*` 的分支。本轮按计划不实施。
* **解除远端参与者视频静音**（lib 侧本身依赖 S Frame 转发）。

## 8. libwebrtc（仓库内置用于开发，交付物不包含）

`Frameworks/WebRTC.xcframework` 是 Jitsi 官方发布的 libwebrtc 构建（pod `JitsiWebRTC 155.0.1`，
即 libwebrtc M155），由
`Package.swift` 里 `.binaryTarget(name: "WebRTC", path: "Frameworks/WebRTC.xcframework")` 声明，
`JitsiMedia` 直接依赖它。**在 SPM/CocoaPods 里集成时它会自动成为依赖**，所以不需要额外配置；
只有手动拖 `dist/` 的静态 framework 时，才要自己提供同一份 WebRTC（`Frameworks/` 里的就是
打包脚本编译时用的那一份，Demo 工程直接从那里链接）。

* 只保留 `ios-arm64` 与 `ios-arm64_x86_64-simulator` 两个 slice，删掉 macOS slice 与两个 `dSYMs`
  目录（442MB 符号，运行时无用），落地 34MB；framework 二进制与发布包逐字节相同。
  `Frameworks/WebRTC-LICENSE.txt` 记录了来源 URL、版本、裁剪方式和 BSD-3 许可证正文
  （二进制分发必须保留许可证，所以别删这个文件）。最低系统 iOS 12，低于本包的 iOS 15 门槛。
* 想让仓库更轻：换成 `.binaryTarget(name: "WebRTC", url: "…/v155.0.1/WebRTC.xcframework.zip",
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

## 9. 来电呈现：通知 + 应用内浮层

SDK **不链接也不引用**任何系统来电界面或 VoIP 推送框架，所有 region 的呈现方式一致。
`SDKConfig.Region` 仍保留在配置里（兼容已有调用），但不再影响来电呈现。

分发与呈现：
* **在线**：App 自己的 XMPP/WebSocket 长连接就是信令通道，前台直接弹 overlay
  （`CallOverlayController` 挂在 `UIWindowScene` 上）。
* **离线**：APNs **alert** 推送（普通可见通知），由集成方交给 `CallCenter.report(_:)`。
* **未前台**：`UNNotificationCategory` 上挂 `ANSWER`（`.foreground`）与 `DECLINE`（`.destructive`）
  两个动作按钮 + 自定义铃声 `incoming.caf`。

代价（设计时必须承认）：后台无法在用户点击前加入会议，也不能在锁屏点亮屏幕或抢占 audio unit。
所以 `CallCenter` 返回的是一个 `CallDecision` 而不是预热好的会话——点击接受之后才启动
engine 入会。

`RegionPolicy.presenter(for:)` / `describe(for:)` 与 `JitsiMeetSDK.callPresentation(for:)`
的签名保留，调用方不用改。

## 10. 打包：一个 xcframework，WebRTC 走外部依赖

`swift build` 只能证明编译，采集方向、渲染、音频会话和旋转都只能在真机确认。
`./Scripts/build-xcframework.sh` 把 8 个源码 module **摊平成一个 Swift module**，产出**单个**
`dist/JitsiMeetSDK.xcframework`；WebRTC 不再打包进去，由集成方通过 SPM binary target /
CocoaPods pod 提供（`Frameworks/WebRTC.xcframework` 就是仓库里用来开发和验证的那一份）。

```bash
./Scripts/build-xcframework.sh          # dist/: 1 个 xcframework + JS bundle + INTEGRATION.txt
open Demo/JitsiDemo.xcodeproj           # 无 SwiftPM 依赖，Signing & Capabilities 里选 Team 后 Run
```

| 产物 | 说明 |
| --- | --- |
| `JitsiMeetSDK.xcframework` | **唯一**的 SDK 产物；静态 framework，`ios-arm64` + `ios-arm64-simulator` 两个 slice，`Headers/` 里有 Swift 与 ObjC 两套头 |
| `JitsiMeetSDK_JitsiMeetSDK.bundle` | lib-jitsi-meet 产物 + 7 个 shim，必须额外拷进 app 的 Resources |
| `INTEGRATION.txt` | 集成方要照着做的链接 / Embed / App Group 清单 |
| `WebRTC-LICENSE.txt` | 编译时所用 WebRTC 的来源与 BSD-3 许可证正文（二进制分发必须保留） |

包内的 module 名、bundle 名都叫 `JitsiMeetSDK`，所以：

```swift
import JitsiMeetSDK           // 已 @_exported 所有上层 module，无需再 import JitsiCore
```

```objectivec
#import <JitsiMeetSDK/JitsiMeetSDK.h>

JitsiSDK.shared.delegate = self;
[JitsiSDK.shared bootstrapWithConferenceHost:@"tmeeting.maesgroup.com:8443"
                                   logLevel:JitsiLogLevelInfo
                             debugSignaling:NO
                                     region:@"chinaMainland"
                                 completion:^(NSError *error) {}];
```

`logLevel` 取 `JitsiLogLevel`（`Trace` / `Debug` / `Info` / `Warning` / `Error`，分别对应 JS 的
`trace` / `debug` / `info` / `warn` / `error`，Swift 侧对应 `SDKConfig(logLevel: LogLevel)`）。
音频输出路由也是枚举：`sdk.audioOutputRoute` 返回 `JitsiAudioOutputRoute`（`Unknown` / `Receiver` /
`Speaker` / `Headphones` / `Bluetooth` / `CarPlay`；未入会或刚切换尚未稳定时为 `Unknown`），
请求走 `[sdk setAudioOutputRoute:JitsiAudioOutputRouteSpeaker completion:…]`——只接受 `Receiver` /
`Speaker`，外接设备连接期间由系统优先，变化经 `jitsiDidChangeAudioOutputRoute:` 上报。
`@objc` 枚举不能带方法，所以名字互转放在 `JitsiAudioOutputRoutes`：
`[JitsiAudioOutputRoutes nameForRoute:route]` 取小写名，`[JitsiAudioOutputRoutes routeNamed:@"speaker"]`
从配置字符串解析。Swift 侧对应 `AudioOutputRoute`（`.stringValue` 语义一致）。

ObjC 门面 `JitsiSDK` 是 `@objcMembers` 的 NSObject：状态属性（`isConnected`/`isJoined`/
`isAudioMuted`/`isVideoMuted`/`isScreenSharing`/`lastError`）、入会/离会、静音、切摄像头、
聊天、改名、举手、踢人、版主静音、lobby/录制/E2EE，以及 `participants`/`localTracks`/
`remoteTracks`（`[[String: Any]]`（按键值可读的快照））。所有异步方法最后一个参数是
`void (^)(NSError *)`，在主队列回调；`JitsiSDKDelegate` 的 `jitsiDidChangeState:` 是必选，
`jitsiDidReceiveEvent:payload:` 是可选的事件透传。

参会者定制走三处：`participants` 的每行带 `isAudioMuted`/`isVideoMuted`/`audioLevel`/`isSpeaking`；
`audioLevels()` 返回 `NSDictionary<NSString *, NSNumber *>`（键是 MUC id，本端是 `"local"`）；
可选回调 `jitsiDidUpdateAudioLevels:` 每 ~200 ms 给一次同样内容，适合直接刷新自绘的电平条。
`stateSnapshot()` 里的 `localAudioLevel`/`localIsSpeaking` 可驱动自己的控制栏。
参会者加入/离开/静音/摄像头开关仍通过 `jitsiDidReceiveEvent:payload:`（`participantJoined`/
`participantLeft`/`participantMuted` 等）透传；要整屏自定义画面就用 SwiftUI 的
`MeetingLayout.room` 或直接订阅 `MeetingSession` 回调。

ObjC 侧的自由布局画布：`jitsiDidJoinRemoteCanvas:participantID:displayName:` 交付一个已经接好
视频/静音/质量更新的 `UIView`（宿主由门面持有，视图自己跟着会议更新），宿主自己决定
`frame` / 层级；离开时 `jitsiDidLeaveRemoteParticipant:`，晚订阅用
`canvasViewForParticipant:` 按 id 取回同一个视图，状态不丢。本机自拍是 `localCanvasView`，
跨预览页/会议页移动同一个 view 即可，采集不中断。

外观用 `JitsiCanvasStyle`：`defaultCanvasStyle` 是所有画布的默认值，
`setCanvasStyle:forParticipant:`（`"local"` 表示本机）只覆盖其中一块，传 nil 恢复默认；属性改动
实时作用到已经显示的画布。字段有 `cornerRadius`、`fillMode`（`JitsiCanvasFillModeFill` 裁切、
`JitsiCanvasFillModeFit` 留黑边；Swift 侧是 `.fill` / `.fit`）、
`showsName`（名称）、`showsAvatar`（相机关闭时的头像）、`showsMicrophoneBadge`（静音图标）、
`showsAudioLevel`（名称左侧随说话跳动的电平条，关掉后名称不再动）、`showsConnectionBadge`
（左上角网络质量条）、`showsSpeakingHighlight`（说话时右下角的闪动脉冲与绿色描边，默认开）、
`avatarSize`、`avatarPosition`、`namePosition`、`nameFontSize`；位置取
`"center"` / `"topLeading"` / `"topTrailing"` / `"bottomLeading"` / `"bottomTrailing"`。旧的
`canvasCornerRadius` / `canvasFillMode` / `canvasShowsName` / `canvasShowsConnectionBadge` /
`canvasAvatarSize` / `canvasShowsSpeakingHighlight` 仍然可用，是 `defaultCanvasStyle` 的快捷方式。
说话提示在 Swift 侧对应 `ParticipantCanvasStyle.speakingHighlight`（`.ring` / `.none`），一个开关
同时管描边和脉冲：`.none` 时该画布在有人说话时完全静止。

媒体与主持人动作：`jitsiRemoteParticipant:didChangeMicrophoneMuted:` /
`…didChangeCameraMuted:` 是逐人的精确变化（初始状态随 `participants` 行给出，不会重复回调）；
`jitsiDidMuteAllRemotes:participantIDs:` 是“主持人静音所有人”的合并启发式（800 ms 内 ≥2 人，
和 Swift 侧 `onHostMuteAll` 同一口径）；`jitsiDidChangeAVModeration:enabled:actorID:` 是房间级的
AV moderation 开关，属于权威信号。

会议时长：初始化时设 `meetingTimeLimit`（秒，0 表示只显示已用时间），入会后
`jitsiDidJoinMeetingTiming:` 回调一次 `JitsiMeetingTiming`（`startedAt` / `elapsedSecondsAtJoin` /
`timeLimitSeconds` / `startSource` / `limitSource`）；之后用 `meetingElapsedSeconds`、
`meetingRemainingSeconds`（`NSNumber`，无时限为 nil）或带时间参数的
`meetingElapsedSecondsAt:` / `meetingRemainingSecondsAt:` 驱动自己的计时视图。语义与 Swift 侧一致：
服务端时间戳优先，服务端时限优先于宿主配置的展示值。

三条硬约束，缺任何一条都是运行期才炸：

1. **静态链接**：集成方只 embed WebRTC 一个 dylib，SDK 自己的代码链进主二进制，真机签名只剩一步。
   为了让 `import JitsiMeetSDK` 能一次解析全部分层，脚本把源码复制到一个临时 SwiftPM 包、
   sed 掉跨 module 的 import，再编译成一个 module。早先“7 个 framework 各自带 swiftmodule”
   的方案不可行：swiftmodule 里的依赖存的是绝对路径，换台机器就报
   `missing required module 'JitsiCore'`。
2. **JS bundle 要进 app**：静态库不能自带资源，`Bundle.module` 只在 `Bundle.main.resourceURL`、
   `Bundle(for:).resourceURL`、`Bundle.main.bundleURL` 三处找 `JitsiMeetSDK_JitsiMeetSDK.bundle`，
   找不到就 `fatalError`。把 `dist/` 里那个 bundle 拖进 Copy Bundle Resources 即可。
3. **只有 WebRTC 走 Embed & Sign**：静态的 `JitsiMeetSDK.xcframework` 放
   "Frameworks, Libraries and Embedded Content" 时选 **Do Not Embed**；WebRTC 才需要
   `PBXCopyFilesBuildPhase`（`dstSubfolderSpec = 10`）与 CodeSignOnCopy。

屏幕共享还需要宿主工程的两件事（缺了也能编译，只是共享轨道没有帧）：

1. 新建 **Broadcast Upload Extension**，把 `Templates/JitsiBroadcastExtension/SampleHandler.swift`
   和 `Info.plist` 拷过去，extension 的 `NSExtensionPointIdentifier` 是
   `com.apple.broadcast-services-upload`。
2. app 与 extension 配同一个 **App Group**，把 id 赋给
   `ScreenShareConfiguration.appGroupIdentifier`（示例是 `group.com.jitsi.meetsdk`），
   再把 extension 的 bundle id 赋给 `ScreenShareConfiguration.extensionBundleIdentifier`，
   否则 `RPSystemBroadcastPickerView` 不会列出扩展。

模拟器 slice 只有 arm64（WebRTC 有 x86_64，我们的模块没有），命令行构建模拟器要加
`ARCHS=arm64 ONLY_ACTIVE_ARCH=NO`；Apple Silicon 上从 Xcode 直接 Run 到模拟器不受影响。

真机验证清单（默认 host 指向自建 `https://tmeeting.maesgroup.com:8443`，WebSocket +
`meet.jitsi` / `muc.meet.jitsi`；换到公开 `https://meet.jit.si` 时匿名域自动切到
`guest.meet.jit.si`，其 members-only 限制见 §4.5）：

* [ ] 入会：状态胶囊走到 `Connected`，事件控制台出现 `joined`（BOSH 首次 `conference request (IQ)`
      可能收到一次 `invalid session`，lib-jitsi-meet 会 1 秒后自动重试，属于服务端 Jicofo 行为）
* [ ] 采集：本地 tile 出帧——模拟器没有画面源，这一条必须真机
* [ ] 前后摄切换，以及旋转后画面方向（`VideoSurface` 的旋转角取自 track）
* [ ] 静音/取消静音：音量环与 `participantMuted` 同步，远端能听到
* [ ] 会议密码（错误密码被拒）与 lobby（等待页 → 主持人放行）
* [ ] 主持人踢人 / 强制静音：目标端收到事件，发起端拿到 IQ 结果
* [ ] 主持人控制：结束会议、加锁后非主持人被拒、转让/收回主持人、设置主题同步到各端
* [ ] 屏幕共享：系统广播选择器里出现扩展，远端看到桌面，停止后轨道被移除
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

`dist/JitsiMeetSDK.xcframework` 不含系统来电界面或 VoIP 推送符号，也不依赖任何系统电话 UI，
可直接用于大陆发行；Region 选择不再改变来电呈现（所有 region 都是通知 + 浮层，见第 9 节）。


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
* **`URLSessionWebSocketTask` 没有 open 回调**：握手完成只能从 `URLSessionWebSocketDelegate` 的
  `didOpenWithProtocol` 得知。`NetworkModule` 之前只转发 message/close/error，WebSocket 传输因此永远
  停在 CONNECTING（Strophe 在 `onopen` 前不发 stream open）；现在 delegate 补发 `open`，并对
  `didCloseWith` 与 receive 失败做去重，避免同一连接关两次。
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
* **presence 属性的值是字符串**：`jitsi_participant_raiseHand` 解析出来是 `'true'`/`'false'`，
  用 `!!value` 会把放下的手当成举着。facade 统一走 `asBool()`（`value === true || value === 'true'`），
  `participantSnapshot` 和 `PARTICIPANT_PROPERTY_CHANGED` 两处都用它。
* **会议名是 XMPP node，必须小写**：`JitsiSwiftDemo` 会被 lib 在构造函数里直接判成
  `Invalid conference name`（`JitsiConference.ts` 的 `toLowerCase()` 校验），连不上服务器。
  jitsi-meet 网页端从 URL 取房间名时会先归一化（`uri.ts` 的 decode → NFKC → 小写 → encode），
  所以浏览器地址栏里的 `ReligiousHealthcaresKickFree` 实际进的是
  `religioushealthcareskickfree`。`ConferenceOptions.init` 现在做同样的归一化（含 breakout 的
  `room(atJID:)`），宿主传入 URL 里的原样房间名即可，不会再本地抛错；demo 的默认房间仍是
  `teambind`。
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
* **音频会话不激活 = 双向静音**：`WebRTCBackend` 用 `RTCAudioSession.useManualAudio = true` 接管
  `AVAudioSession`，但 `AudioSessionManager` 必须真的被调用。没有 `playAndRecord + voiceChat` 且
  `setActive(true)` 的会话时，AURemoteIO 仍可能“启动”，但采集到的是静音、播放也没有输出路由；
  `outbound-rtp` 字节数照样增长（Opus 静音帧），所以字节数不能当作“有声音”的证据。现在
  `JSMeetingEngine.openCapture/joinConference` 会先 `activateAudioSession`，由
  `AudioSessionManager` 配置并激活会话，再调用 `RTCAudioSession.audioSessionDidActivate` 交给
  WebRTC 的音频单元；离开/断线时对称地 `deactivateAudioSession`。类别选项里不能带 `.mixWithOthers`。
  验证时看对端 `inbound-rtp.totalAudioEnergy` 是否随说话/测试音显著增长。
* **本地轨道必须在 `joinConference` 之前建好**：jitsi-meet 的 `_conferenceWillJoin` 就是这个顺序。
  先入会再 `addTrack` 会走 `RTCRtpSender.replaceTrack`，而 JVB answer 的 recvonly transceiver 在 shim 里
  原本 `sender === null`，`replaceTrack` 在 `Promise.allSettled` 里静默抛错——表现是 2 人 P2P 正常、
  3 人以上双方都听不到声音，且本机静音传不到对端（m-lines 与 sender 都对不上）。现在
  `capture()` 在入会前注册轨道，`pc.addTrack` 同步返回 `senderId`，每个 transceiver 都有占位 sender，
  `replaceTrack` 走到 native 的 `sender.track = track`。`check-js-shims.swift` 里
  “replaceTrack reaches native with the sender id”“remote m-lines expose a sender”两条断言守着它。
* **`simctl spawn defaults` 改不到 app 容器里的 `@AppStorage`**（iOS 17+ runtime）：容器 plist 与
  `defaults` 读写的是两份域。要脚本化启动就用 demo 的 `JITSI_DEMO_*` 环境变量（见 4.5）。
* **模拟器多人音频偶发 `AURemoteIO ... Initialize: RPC timeout. Apparently deadlocked`**：这是
  Simulator 的 AudioToolbox 环境问题，不是 SDK 死锁；关掉该模拟器再 boot 即可恢复，真机不受影响。
* **SwiftPM 的 iOS 可执行文件要手工打包**（`Scripts/make-demo-app.sh`）：`WebRTC.framework` 在
  `.build/<config>-iphoneos*/` 产物根目录而**不是** `PackageFrameworks/`；`@executable_path/Frameworks`
  在 iOS 上不是隐式搜索路径，必须 `install_name_tool -add_rpath` 显式加；沿用 RN 模板 plist 里的
  `UIRequiredDeviceCapabilities: [armv7]` 会让 app 在 arm64 模拟器上直接起不来（表现为 SpringBoard 崩溃循环）。
* **`simctl` 没有 `--setenv`**：子进程环境用 `SIMCTL_CHILD_<VAR>` 前缀传；`--stdout=`/`--stderr=` 必须写成
  等号形式，否则后面的参数被当成设备名。
* **`xcodebuild -create-xcframework` 不吃静态 framework**：静态产物没有 `.swiftinterface`，命令直接报
  "No 'swiftinterface' files found within …/Modules/X.swiftmodule"。`.xcframework` 只是目录加一份
  `Info.plist`（`CFBundlePackageType=XFWK` + `AvailableLibraries`），所以 `build-xcframework.sh` 手写它。
  代价是只带 `.swiftmodule`（二进制模块接口），**集成方的 Xcode/Swift 版本必须与打包机一致**；
  换工具链就用源码包（SPM）或重新跑一次打包脚本。
* **单 module 是打包期摊平出来的**：脚本把 8 个 module 的 `.swift` 拷进临时包、`sed` 掉跨 module 的
  `import Jitsi…`、再编成一个 target。两个坑：文件名必须全局唯一（脚本会先查重并报错），
  以及源码里不能再出现只存在于分层结构的 import（`JitsiMeetDemoApp` 里
  `#if canImport(JitsiMeetExample)` 就是为兼容两种形态）。改分层结构时同步改
  `SOURCE_MODULES`。
* **Swift 生成的 ObjC 头不在 `-emit-objc-header-path` 指定的地方**：SwiftPM 的 xcbuild 构建会把它
  放到 `.build/out/Intermediates.noindex/GeneratedModuleMaps-<sdk>/JitsiMeetSDK-Swift.h`，
  命令行参数被覆盖。脚本先看指定路径，找不到再按 sdk 名去 intermediates 里捞。
  `JitsiMeetSDK.h`（伞头）必须先 `#import <UIKit/UIKit.h>`：生成的头里有 `UIView` 子类
  （`PixelUIView`），只 import Foundation 会让 ObjC 集成方编译失败。
* **资源 bundle 名是 `包名_目标名`**：SwiftPM 生成的访问器找的是
  `JitsiMeetSDK_JitsiMeetSDK.bundle`（不是分层时的 `JitsiMeetSDK_JitsiJSRuntime.bundle`）。
  改临时包的 package/target 名就必须同步改脚本和集成说明。
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
  所以脚本每编完一个平台就立刻把产物拷进 `.build/single-xcframework-stage`，不要延后统一取。
* `AsyncStream` 只有一个消费者，所以 `statusChanges()` 每次调用新建一条流，不做共享属性。
* iOS 15 下限：`Locale…languageCode`（16）、`AVCaptureDevice.DeviceType.microphone`（17）、
  `.builtInHeadphone`、值型 `NavigationLink`、`isFlipped`、`SymbolEffect` 都不可直接使用。
* **`WebRTCBackend.swift` 的锁用在 async 函数里**：`NSLock.lock()` 在异步上下文中会报
  "unavailable from asynchronous contexts" 警告，Swift 6 语言模式下升级为错误。本包固定在
  Swift 5 模式（见 `Package.swift` 顶部注释），迁 strict concurrency 时要把这些临界区抽成同步方法。


## 12. 对齐目标与已知边界

**对齐目标只有一个：`lib-jitsi-meet-master`**（`~/Downloads/lib-jitsi-meet-master`，已登记为
工作空间共享来源，见仓库根目录 `AGENTS.md`）的库公共 API 与事件。`jitsi-meet` 只是产品层 UI 的
参考输出，后续会单独改造，**不作为对齐目标**；因此不要在这里记录“少了某个网页版界面/组件”之类的
产品差异。功能是否遗漏，一律对照 LJM 的 `JitsiConference` / `JitsiConnection` / `JitsiMeetJS` /
`JitsiMediaDevices` / `JitsiTrack` / `JitsiParticipant` 判断。

**在 LJM master 完全对齐之前，所有任务都围绕本仓库的对齐展开；E2EE 与 jitsi-meet UI 改造是冻结项**
（见 §12.4），除非用户特别说明，不启动、不排优先级。

### 12.1 与 lib-jitsi-meet-master 的差距（第一对齐目标）

引擎层没有版本差距：打包的 `99-lib-jitsi-meet.bundle.js` 已包含 master 的全部 88 个会议事件、
7 个连接事件和公共方法符号。**下面所有差距都是门面 / Swift 层没有暴露，不是库缺功能**，不需要
升级 bundle。当前门面 88 个方法（Swift 调用 84 个），校验器口径为监听 94 个事件名、发出 102 个
事件名（71 个在 Swift 里建模，31 个作为 `MeetingEvent.raw` 透传）。

* **会议事件已全部转发**：最后 22 个事件已接入强类型通道——
  `AUDIO_UNMUTE_PERMISSIONS_CHANGED`、`BEFORE_STATISTICS_DISPOSED`、`BOT_TYPE_CHANGED`、
  `BRIDGE_BWE_STATS_RECEIVED`、`CONFERENCE_CREATED_TIMESTAMP`、`CONFERENCE_JOIN_IN_PROGRESS`、
  `CONFERENCE_UNIQUE_ID_SET`、`CONFERENCE_VISITOR_CODECS_CHANGED`、`CONNECTION_ESTABLISHED`
  （会议级的首次 ICE 连通，不是连接事件）、`ENCODE_TIME_STATS_RECEIVED`、
  `ENDPOINT_STATS_RECEIVED`、`FILE_SHARING_FILE_ADDED`、`FILE_SHARING_FILE_REMOVED`、
  `INBOUND_VIDEO_STATS_RECEIVED`、`MEMBERS_ONLY_CHANGED`、`PERMISSIONS_RECEIVED`、
  `PHONE_NUMBER_CHANGED`、`SILENT_STATUS_CHANGED`、`VIDEO_UNMUTE_PERMISSIONS_CHANGED`、
  `VISITORS_MESSAGE`、`VISITORS_REJECTION`、`VISITORS_SUPPORTED_CHANGED`。房间可见性事件同时
  更新 `JitsiConference` 镜像（members-only → `lobbyEnabled`、visitors → `visitorsSupported`、
  silent/bot 标记写回参会者快照、拨入号码写入 `phoneNumber`）。
* **已完成（本轮）**：参会者详情——`JitsiParticipant` 的 `jid`/`connectionJID`/`status`/`botType`/
  `statsID`/`isSilent`/`isReplacing`/`isReplaced`/`isHidden`/`isAudioMuted`/`isVideoMuted`，
  以及 `getSpeakerStats`（`SpeakerStats` 含 dominant speaker 时长与 face landmarks，已离会行保留）；
  媒体控制扩展——任意本地轨道 `replaceTrack`（交换后释放旧轨道）、`setReceiverConstraints`
  （`lastN`/默认与按 source 的 `maxHeight`/假定带宽）、`setAssumedBandwidthBps`、
  `setDesktopSharingFrameRate`、原生音频输出路由（`AudioOutputRoute` 返回真实路由
  `receiver`/`speaker`/`headphones`/`bluetooth`/`carPlay`，写入只接受内置的 receiver/speaker，
  外接设备连接期间优先且不会被覆盖，路由变化经 `audioOutputRouteChanged` /
  `jitsiDidChangeAudioOutputRoute:` 上报）与
  `lib.preCallTest`（TURN 中继探测，缺失指标返回 nil）；连接扩展——`connection.jid`、
  `getConnectionTimes`、XEP-0115 `addFeature`/`removeFeature`、`attach`（rid/sid/jid 复用会话）
  与 `getLogs`（仅 `debugSignaling` 开启时可用）；鉴权升级
  `authenticateAndUpgradeRole`、DTMF `sendTones`、`isSIPCallingSupported`/`dial`。通用信令——presence command 的发送
  （`sendCommand`/`sendCommandOnce`）与
  监听（`addCommandListener`/`removeCommandListener` → `commandReceived`，监听器在重连/切房间
  后自动重挂）、数据通道 `sendEndpointMessage`（对面收 `endpointMessage`）、XEP-0459
  `sendReaction` + `reactionReceived`；分组讨论房间列表 `BREAKOUT_ROOMS_UPDATED`（强类型
  `BreakoutRoomsState`）、
  管理四方法（create/rename/remove/sendParticipant）与同连接房间切换（`conference.switch`，
  默认自动跟随 `BREAKOUT_ROOMS_MOVE_TO_ROOM`）；本地参会者属性
  `setLocalParticipantProperty`/`removeLocalParticipantProperty`/
  `localParticipantProperty` + `PARTICIPANT_PROPERTY_CHANGED`/`PROPERTIES_CHANGED`；等候室
  approve/deny/message、`myLobbyUserID` + `LOBBY_USER_JOINED/UPDATED/LEFT`；AV moderation
  四方法 + 全部 `AV_MODERATION_*` 事件；连接 `PROPERTIES_UPDATED`（映射为 `serverRegion`/
  `serverShard`）；`refreshServerState()` 补回 `e2eeEnabled`/`visitorsSupported`。
* **未暴露的 LJM 方法（按域）**：
  * 本轮审计列出的参会者、媒体、连接、鉴权与 DTMF/SIP 方法均已暴露；剩余差距是纯浏览器 API
    （如 `enumerateDevices`/`setSinkId` 的 Web 特例），在原生端不适用，不算差距。

**待办排序（只针对上面的 LJM 差距）：**

* **P0 — 本地属性与房间管理（已完成）**：本地参会者属性与 `PROPERTIES_CHANGED`、等候室
  approve/deny/message + `LOBBY_USER_JOINED/UPDATED/LEFT`、AV moderation 四方法与配套事件、
  连接 `PROPERTIES_UPDATED`。（会议控制与主持人 API 亦已完成。）
* **P1 — 信令与媒体扩展（已完成）**：参会者详情与 `getSpeakerStats`、任意轨道 `replaceTrack`、
  `setReceiverConstraints`/带宽/屏幕共享帧率、音频输出、通话前检测、连接扩展
  （`getJid`/耗时/features/`attach`/`getLogs`）、鉴权升级、DTMF/SIP。
* **P2 — 统计与可见性事件（已完成）**：`PERMISSIONS_RECEIVED`、`SILENT_STATUS_CHANGED`、
  `MEMBERS_ONLY_CHANGED`、`PHONE_NUMBER_CHANGED`、文件共享增删、访客/visitors 事件、
  `ENCODE_TIME`/`ENDPOINT_STATS`/`INBOUND_VIDEO_STATS`/`BRIDGE_BWE`/`BEFORE_STATISTICS_DISPOSED`
  等纯统计事件已全部进入强类型通道。

### 12.2 传输层

* **黑洞网络靠 BOSH 超时兜底**：`NWPathMonitor` 只反映 `.satisfied`，Wi-Fi 关联上但出口不通时
  路径仍是“在线”，因此探测不到。此时只能等 Strophe 的 BOSH 主超时
  （`wait(60) × TIMEOUT(1.1)` ≈ 66 秒，且 `_hitError` 需要 `errors > 4` 才判死）上报
  `CONNECTION_FAILED`，从断网到 `connectionLost` 最坏约 54–66 秒。广播断开类场景是 5–20 秒。
  想更快只能自己挂应用层探测（例如定期发 MUC ping 并看回包延迟），代价是额外的信令与流量。
* **5xx / `SERVER_ERROR` 不进自动重试**（R6）：只有 `connection.droppedError` 走自动重连，
  服务端 5xx、BOSH 499/400、Prosody 主动断开都直接以错误结束。宿主现在可以调用
  `retryConnection()` 手动重试（两个门面都有，复用退避、JWT 刷新与状态恢复），但 SDK
  不会替宿主自动重试这类错误。
* **接口切换不做主动重连**（R5）：Wi-Fi↔蜂窝切换后不会立刻重建信令，要等上一条的失败上报。
  主动切换意味着在路径变化时提前 `connect`，但这会打断还能自愈的连接（切换瞬间的 BOSH
  重发通常能恢复），收益与风险都还没验证，暂缓。
* **没有 `restartJvbIce` 主动 ICE 重启**：内置的 lib-jitsi-meet 版本早于该能力。Wi-Fi↔蜂窝
  换 IP 后靠 lib 自己的 `IceFailedHandling`（65 秒 ping + 2 秒）或 P0 全量重连恢复，
  所以最快也要几十秒，不是秒级恢复。
* **endpointId 每次全量重连都会变**（2026-11-10 决定“先维持现状”）：每次 rejoin 是新 XMPP
  会话，MUC resource 重新生成（登录用户 `randomHexString(8)`，匿名用户取 JID node），远端
  在 Prosody 回收旧 BOSH 会话（约一个 BOSH wait，几十秒）之前可能同时看到两个同名参会者。
  修复方案是持久化 nick + `resourceCreator` 覆盖，但 LJM 把 MUC `<conflict/>` 映射成通用的
  `CONFERENCE_FAILED`，没有专门处理；**没有真实部署上的冲突实测前不要动**。上游
  jitsi-meet 也是同样行为，这是接受现状的理由。
* **App 生命周期只兜底已上报的终态**（2026-11-10 已接入）：宿主把 `scenePhase == .active`
  传给 `setAppActive(_:)`（`MeetingView` 与 Demo 已内建，OC 门面同名）。从后台回到前台、且
  已经入过会而当前不在会中时，补发一次带退避的重连（重置 3 次配额、保留抖动阻尼）；健康通话
  与首次入会/lobby 等待不受影响。局限：它只处理“已知未入会”的终态。如果后台期间连接静默死亡、
  `connectionLost` 还没上报，`isJoined` 仍为真，回到前台不会主动探活，仍要等 BOSH 主超时
  （见上一条）或 lib 的失败事件。VideoToolbox 的 `suspendDetected` 也仍未接入轨道重建。

### 12.3 产品层

* **members-only 失败走等候室，而不是终态报错**：`MeetingModel` 把
  `conference.connectionError.membersOnly` 当作上游 jitsi-meet 的可恢复失败处理——用入会时的
  display name/email 自动 `joinLobby`，`isWaitingInLobby` 驱动 Demo 等待卡片，`canRetryConnection`
  在等待期间为 false，避免“重试”把 lobby 拆掉；主持人放行后同一个 conference 自己发
  `CONFERENCE_JOINED`，等待态与提示一起清除。被拒绝（`accessDenied`）才退出等待并允许重试。
  重连路径同样适用：`waitForJoin` 在 members-only 上 reject 时不再消耗 3 次配额。
* **`waiting-for-host` 不是审批流**：407 里带 `<waiting-for-host/>` 时（facade 先发
  `lobbyWaitingForHost`，SDK 暴露为 `isWaitingForHost`），客人被放进 Prosody 的 persistent
  lobby，等**已登录**主持人（JWT / 域名内 PLAIN 账号）开房时由
  `mod_muc_wait_for_host` 销毁 lobby 并自动放人。这个流程里主持人浏览器根本不会有
  “入会申请”可点；匿名房间（例如 meet.jit.si 默认配置）只要没有已登录主持人，双方都会停在
  lobby。若 UI 显示“等待主持人”但浏览器端也没有任何人被要求审批，先确认部署是否启用了
  `mod_muc_wait_for_host` 以及主持人是否会带 JWT 登录（§4.5）。
* **房间密码是进入等候室之前的关卡**（2026-11-11 已接入）：`ConferenceOptions.password` 经
  `conference.join(password)` 进入 MUC join presence，Prosody 在 `mod_muc_lobby_rooms` 里先校验
  密码（priority -4）——正确则直接授 member、不进 lobby；缺失或错误则返回
  `conference.passwordRequired`，此时没有任何密码可猜，`MeetingModel`/`JitsiObjC` 暴露
  `requiresPassword` 并给出提示，`canRetryConnection` 为 false（避免无密码的盲目重试），也**不**
  发送 `joinLobby` 敲门。宿主应让用户输入密码后带 `ConferenceOptions.password` 重新入会；
  入会成功后该标志复位。Demo 首屏有 Room password 字段，脚本化用 `JITSI_DEMO_PASSWORD`
  （§4.5）。此前“匿名用户能进、本项目不进”的现象就是这个缺失：房间启用了密码，而 demo
  的入会表单没有密码输入。
* **等候室审核仍由主持人侧 API 完成**：guest 端只负责敲门；`lobbyUsers` 增量来自
  `LOBBY_USER_*`，approve/deny 走 `lobbyApproveAccess`/`lobbyDenyAccess`（§5）。
* **分组讨论依赖部署侧组件**：公开部署 `meet.jit.si` 带 `breakout_rooms` 组件，能力由
  `breakoutRoomsState` 上报；当前自建部署 `tmeeting.maesgroup.com:8443` 没装组件时，
  运行期 `createBreakoutRoom` 等调用会由 facade 抛 `unsupported`（不会静默失败）。房间切换
  本身是“同一连接上 `leave('switch_room')` → 建新 conference → 重挂轨道 → 重新入会”，与上游
  jitsi-meet 的 `moveToRoom` 一致；收到 `breakoutRoomsMoveToRoom` 时默认自动跟随
  （`MeetingModel`/`JitsiObjC` 均内建），也可以由宿主关掉自定义流程。端到端仍需在真实部署上
  实测，本仓库目前只有 shim 探针与单元测试覆盖。
* **公开 meet.jit.si 的匿名房间必须等主持人**：已实测 XMPP/WebSocket 与 focus 分配成功，但 MUC
  入会固定返回 407 `registration-required` + `waiting-for-host`（`conference.connectionError.membersOnly`），
  这是部署策略而非 SDK 故障。guest 端由 `MeetingModel` 自动 `joinLobby` 排队（`isWaitingForHost`），
  这个流程没有审批按钮：已登录主持人开房时自动放人；匿名主持人（无 JWT）无法让房间离开该状态。
  自建部署或 JWT 部署没有这条限制。控制台 `[sdk][lobby]` 行会打印实际 lobby JID 与敲门结果。
* **远端参会者的视频解禁需要 SFrame**：目前只能本地静音/取消静音自己的视频，不能替别人开摄像头。
* **运行期视频约束只覆盖本地摄像头轨道**：`applyVideoConstraints`/`videoCapabilities` 走原生
  `activeFormat` 切换，屏幕共享轨道与远端轨道不支持。LJM 的 `track.applyConstraints` 只处理音频
  且会重新申请采集（换掉原生 track id），因此没有接入。
* **媒体控制扩展的行为边界**（2026-11-11 已接入）：`replaceTrack` 只接收 SDK 创建过的本地轨道
  id，交换成功后门面会 dispose 旧轨道；`setReceiverConstraints` 中为 nil 的字段不发送，由 lib
  保留上一值；`AudioOutputRoute` 的 `receiver`/`speaker` 是应用可请求的内置路由，
  `headphones`/`bluetooth`/`carPlay` 只作为当前真实路由上报（USB/HDMI/AirPlay 归入
  `headphones`），外接设备连接期间写入内置路由不会改变实际输出，路由变化通过
  `MeetingSessionEvent.audioOutputRouteChanged` 与 ObjC 的
  `jitsiDidChangeAudioOutputRoute:` 通知；浏览器式 `enumerateDevices`/`setSinkId` 在原生端不适用；
  `runPreCallTest` 需要 TURN
  服务器才能得到 `mediaConnectivity = true`，lib 跳过 RN 吞吐测试时 `throughput` 及其他指标
  可能为 nil，调用方按可选值处理。
* **连接扩展与 DTMF/SIP 的边界**（2026-11-11 已接入）：`connection.attach` 只在服务端仍持有该
  BOSH 会话（rid/sid）时可用，SDK 的自动重连不走它；`getLogs` 的 Jingle/XMPP 记录含 JWT、SASL
  与 TURN 临时凭据，因此只在 `SDKConfig.debugSignaling = true` 时返回，release 构建不要打开；
  `authenticateAndUpgradeRole` 在旁路连接登录后请 Jicofo 升级角色，但不暴露 lib 的 cancel 句柄；
  `isSIPCallingSupported` 是本地读取（部署需装 `sip_gateway`），`dial` 只在该组件存在时可用；
  `sendTones` 交给活动的音频 sender 后即返回，没有送达确认。
* **P2 事件通道的边界**（2026-11-11 已接入）：`CONNECTION_ESTABLISHED` 是会议级首次 ICE，与连接层
  的同名事件/`connectionStatus` 不是一个对象，前者只表示媒体通道已建立；`PHONE_NUMBER_CHANGED`
  在 lib 里不带参数，facade 在事件发生时读取 `getPhoneNumber()`；`ENCODE_TIME_STATS_RECEIVED` /
  `INBOUND_VIDEO_STATS_RECEIVED` 的 Map 以 SSRC 为键，跨桥前压平成对象并附带
  `peerConnection` 数值 id，Swift 侧保留 JSON 而不重建每个计数器；`FILE_SHARING_FILE_*` 是增量，
  全量列表仍由 `fileSharingFiles` 提供；`VISITORS_REJECTION` 没有负载；
  `PERMISSIONS_RECEIVED` 是后端强制的权限 map，与 AV moderation 的本地状态分开；
  `SILENT_STATUS_CHANGED` / `BOT_TYPE_CHANGED` 只更新参会者快照。
* **TURN `CreatePermission 403` 属部署侧**：P2P 打洞失败时的问题在 TURN 凭据/UDP 放行，
  App 侧只能记录 ICE 失败状态辅助定位。

### 12.4 明确延期

* **E2EE（第四阶段）**：2026-11-10 明确延后，未实现前不要自行补。
* **jitsi-meet 产品层 UI 改造**：网页版的界面/组件不参与本轮对齐，后续单独排期。
* **等候室审批流（lobbyroom）的端到端验证**（2026-11-11 记录）：**等产品层改造完成后再处理**。
  Swift 侧状态机、facade `[sdk][lobby]` 日志与单元测试都已就绪（membersOnly 自动敲门、
  `lobbyWaitingForHost`、approve/deny API），但还没有在真实部署上跑通“敲门 → 主持人 lobby
  列表 → 放行 → 自动入会”这条链路。阻塞原因：meet.jit.si 从本机被代理阻断 TLS；自建
  `tmeeting.maesgroup.com:8443` 没装 lobby 组件（`lobbySupported=false`）。此前“主持人看不到
  本机敲门”已定位为房间密码缺失——密码正确会直接授 member、跳过等候室（§12.3），不是 lobby
  代码故障。恢复验证时需要一个启用 `mod_muc_lobby_rooms` 的部署 + 已登录主持人账号。

### 12.5 自建 ADM 与本地录制音频（默认关闭）

`SDKConfig.useCustomAudioDevice = true` 时，`WebRTCBackend` 用
`RTCPeerConnectionFactory(encoderFactory:decoderFactory:audioDevice:)` 注入
`Sources/JitsiMedia/VoiceProcessingAudioDevice.swift`，替代 libwebrtc 内置 ADM。目的只有一个：
拿到两路 PCM——`deliverRecordedData` 是麦克风、`getPlayoutData` 是远端混音——供
`LocalVideoRecorder` 写音频轨并与视频对齐。

可行性已确认：vendored JitsiWebRTC 155.0.1 的二进制里带 `ObjCAudioDeviceModule`，注入入口可用。

**真机验收（iPhone 15，2026-11-23）**：开关打开后日志依次出现
`unit created (VoiceProcessingIO)` → `initialized rate=48000 mono` → `playout started` →
`first playout pull` → `recording started` → `first mic deliver`；双端互听正常，对端收不到
回声，静音/取消静音来回切换可恢复且无爆音，蓝牙耳机路由无异常。本机曾听到的“回声”已定位为
两台设备在同一房间（对端静音后消失），不是 ADM 问题。有线耳机插拔、来电中断、后台锁屏仍未覆盖。

**阶段 1（录制音频）**：`LocalRecordingConfiguration.audio` 非空时，`RecordingAudioWriter`
把麦克风与远端混音按 host 时钟对齐后饱和相加，编码为 48 kHz mono AAC（64 kbps）写入同一个 MP4；
视频帧 PTS 也从帧序号改为同一 host 时钟，音画不再各自漂移。`AudioTapRegistry` /
`AudioTapSource` 是注入点，测试可替换成假设备。

入口有两个：`JitsiMeetExample/LocalRecordingController`（SwiftUI demo，只在
`useCustomAudioDevice` 打开时请求音频）和 ObjC 门面的
`JitsiSDK.startLocalRecording` / `stopLocalRecording`（完成后回调
`jitsiDidFinishLocalRecording:error:`，文件落在 App 容器的 `Library/Caches/`）。
DemoObjC 控制条上的 Record 按钮走的就是后者；`JITSI_DEMO_RECORD_SECONDS=N` 可让真机
入会后自动录 N 秒再停，便于无人值守验证。

边界补充：如果整场会议从未创建过任何音频轨（例如入会即静音且房间没有其他人），ADM 不会启动，
录制文件里不会有音轨，日志中也不会出现 `[adm] initialized`；这是“没有 PCM”而不是编码失败。

当前边界：

* 设备用 `kAudioUnitSubType_VoiceProcessingIO`，与内置 ADM 一样保留硬件回声消除；换成普通
  `RemoteIO` 只剩软件 AEC3，外放会啸叫，不要这样改。
* 注入后 `AVAudioSession` 由设备负责（category / mode / 激活），`AudioSessionManager` 退化为
  路由观察（`refreshCurrentRoute`）；`RTCAudioSession.useManualAudio` 与 `isAudioEnabled`
  只在没有注入设备时设置。
* 录制音频必须有注入设备，否则 `start()` 抛 `LocalRecordingError.audioTapUnavailable`，不会
  产出静音轨；同一时刻只允许一个录制器占用 tap。
* 混音按时间戳对齐，一侧静默超过 0.5 s 后按静音补；固定 48 kHz mono，未做重采样；AAC 编码
  参数暂不可配；只输出一条混合轨，不区分本地/远端。
* 中断只做了“重新激活会话 + 重启 audio unit”的兜底，路由变化只发
  `notifyAudioIn/OutputParametersChange`；有线耳机、来电中断、后台锁屏还没真机验证。
* 开关在 install 时读取，`bootstrap` 会复用已安装引擎，所以改值要先 `shutdown()` 再 bootstrap；
  ObjC 门面通过 `JitsiSDK.useCustomAudioDevice`（同样在 `bootstrap` 前设置）。
* 没有注入时全部走原路径，行为与之前一致。诊断用 `JITSI_ADM_TRACE=1` 启动环境变量打开
  固定字符串 trace（`idevicesyslog` / `devicectl --console` 都能读，`Logger` 走统一日志，
  真机采集需要 root）。

验证口径：`swift Scripts/check-js-shims.swift` 现在 7 个脚本、49 条行为断言；改动门面或
shim 后先跑它，再跑 `./Scripts/build-xcframework.sh`。

### 12.6 屏幕录制（WYSIWYG）

ObjC 门面另有 `startScreenRecording` / `stopScreenRecording` / `isScreenRecording`：ReplayKit
录“用户看到的画面”（`Sources/JitsiMedia/ScreenRecorder.swift`），音频仍取注入设备的
麦克风 + 远端混音，一次写成一个 MP4（H.264 24 fps / 6 Mbps + 48 kHz mono AAC），
文件在 `Library/Caches/jitsi-screen-<时间戳>.mp4`。停止后 URL 同时经
`jitsiDidFinishLocalRecording:error:` 和 stop 的 completion 回传。

* 只在真机 + 前台有效；模拟器或被 MDM 禁用时 `start` 返回
  `"Screen recording is not available on this device."`（`LocalRecordingError.screenCaptureUnavailable`）。
* `recorder.isMicrophoneEnabled = false`：音频已由 ADM 给出混合 PCM，让 ReplayKit 再录一条会重复。
* 写入器尺寸取自第一帧且不可变；旋转导致分辨率变化时按信箱（letterbox）缩放，不丢后续画面。
* 与本地录制各自独立启动，但共用 `AudioTapRegistry` 的单一 tap：先开的那一路才有音轨，
  所以两种录制不要同时开。
* 音频输入必须在 `startWriting()` 之前加进 `AVAssetWriter`（写入器起写后拒绝新 input）；
  `startCapture` 的 completion 才代表“真正开始录”，点击时刻到它之间 ReplayKit 仍要 1–4 秒。
  若上一次 capture 没有正常 stop（进程被杀），下一次可能要等几十秒才回调。

**真机验收（iPhone 15，iOS 27.2.1，2026-11-24）**：DemoObjC 控制栏的 **Screen** 按钮（env
`JITSI_DEMO_SCREEN_SECONDS=N`，配合 `JITSI_DEMO_CUSTOM_ADM=1`）走完整条链路。产物
886×1920、H.264（实践 ~15 fps / ~2.1 Mbps，24 fps 只是上限）+ 48 kHz mono AAC（~60 kbps），
时长与视频一致（9.24 s 视频 / 443,719 个音频样本 = 9.24 s @48 kHz），说明 ADM 的 host 时钟与
屏幕帧共用一条时间轴。两个坑已修：`CMTimeCompare(pts, .invalid)` 恒为 0（NaN），曾让首帧永远
被丢、文件停在 0 字节；音频 input 若在 `startWriting()` 之后才 add 会被拒，音轨静默消失。

已知边界：ADM 整段没送 PCM 时（设备被占用、音频单元没起）文件只有视频轨，既不会伪造静音轨，
也不会报错——`[audio] finished flushed=0` 就是这种情况。DemoObjC 的相册保存需要
`NSPhotoLibraryAddUsageDescription`（已在 `project.yml` 补上），首次会弹权限。

### 12.7 远端屏幕共享的展示

默认**分开展示**（`SDKConfig.mergesRemoteScreenShareWithCamera == false`）：参与者自己一行
（摄像头或头像），分享单独一行，标题是 `<名字> 的屏幕`，且分享行不画麦克风 / 摄像头 / 网络
徽标，只保留名称。tile id 由 `MeetingSession.screenShareTileID(for:)` 给出
（`"<participantID>-screen"`），ObjC 门面同 id 的 canvas 走 `jitsiDidJoinRemoteCanvas`，
`displayName` 就是「<名字> 的屏幕」；分享行不触发参会者加入/离开回调。

要「分享顶掉摄像头、每人一行」，把该开关置 `true`：Swift 侧改 `SDKConfig`，
ObjC 侧设 `JitsiSDK.mergesRemoteScreenShareWithCamera`（与 `useCustomAudioDevice` 一样在
`bootstrap` 时读取，改完要重新 `bootstrap`），DemoObjC 用 `JITSI_DEMO_MERGE_SCREEN=1`。

真机验证踩到的两个坑，已修：

* `lastN = 1` 时 bridge 只转发一路视频源：分享期间摄像头那一路收不到帧，分享停掉后也不会
  自动切回，于是摄像头一直黑屏。1:1 现在用 2，其余场景按「参与者数 + 分享数」算。
* `VideoSurface` 只在 `makeUIView` 订阅一次：换轨（分享↔摄像头、摄像头关掉再打开会换新的
  track id）后仍在读旧流。现在按 `identity` 重启播放并 `flushAndRemoveImage`，`TrackVideo`
  与 `ParticipantCanvasContent` 也只在轨道变化时创建 `AsyncStream`（此前每次 body 都会新建一条
  未消费的流，sink 永久留在后端）。

### 12.8 说话电平（电平条）

真机实测：`TRACK_AUDIO_LEVEL_CHANGED` 在 WKWebView 里**本地与远端都没有事件**。bundle 里
lib 的本地电平走 WebAudio，而 `connectAudioContext()` 创建 `AudioContext` 后立即 `suspend()`，
WKWebView 里没有手势不会 resume，分析器恒为 0。

所以电平改由 `JitsiMedia/AudioLevelMonitor.swift` 从自定义 ADM 的 PCM 直接算 RMS（render
回调里 256 点采样、trylock、不分配）：

* 本机自视 → `microphoneLevel`（麦克风 RMS）；
* 远端 → `playoutLevel`（远端混音 RMS，**所有未静音远端共用一个值**，因为 ADM 只拿到混音）；
* lib 若哪天上报了某人的电平，1 秒内优先用 lib 的值（`libLevelAt`）；
* 350 ms 无新数据自动归零，不会卡在最后一帧。

显示侧 `AudioLevelMeter` 把 0…1 RMS 先除以 `fullScale = 0.1` 再开平方压缩：实测安静房间
≈0.018（点亮 1 格），说话 0.02–0.15（1–4 格）。要做到"每人独立电平"且多人同时说话不串，只能
让服务端/JVB 转发 audio level 或改用 `RTCRtpReceiver.getSynchronizationSources()`，目前未做。
