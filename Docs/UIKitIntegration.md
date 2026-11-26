# JitsiMeetSDK UIKit 接入文档

面向 **UIKit 宿主**（Objective-C 或 Swift）的完整接入说明。SDK 以单个静态
`JitsiMeetSDK.xcframework` 交付，会议 UI 由宿主自己搭；SDK 负责信令、媒体、画布渲染与状态。
ObjC 宿主通过 `JitsiSDK` 门面接入，Swift UIKit 宿主使用同一套 ObjC 可见 API。

- 包内主导入头：`<JitsiMeetSDK/JitsiMeetSDK.h>`（Swift：`import JitsiMeetSDK`）
- 门面类型：`JitsiSDK`（单例）、`JitsiSDKDelegate`、`JitsiCanvasStyle`、`JitsiMeetingTiming`
- 画布：`localCanvasView`（本机自拍）+ `jitsiDidJoinRemoteCanvas:…`（远端每人一个 `UIView`，
  内部已接好视频/静音/说话/质量刷新）；外观用 `JitsiCanvasStyle` 统一设置或逐人覆盖
- 所有回调和 `completion` 都在 **主队列** 执行

---

## 1. 交付物与系统要求

| 项 | 值 |
| --- | --- |
| 最低系统 | iOS 15.0 |
| 架构 | 真机 `ios-arm64`；模拟器 `ios-arm64-simulator`（Apple Silicon 直接跑） |
| SDK 形态 | 静态 xcframework，**Do Not Embed** |
| 资源 | `JitsiMeetSDK_JitsiMeetSDK.bundle`，必须拷进 app 的 Copy Bundle Resources |
| WebRTC | 外部依赖，CocoaPods `JitsiWebRTC` **124.0.2**（与 SDK 编译时版本一致，不要浮动） |
| 许可证 | 二进制分发需保留 `dist/WebRTC-LICENSE.txt` |
| 无 WKWebView | JS 跑在 JavaScriptCore，渲染是原生 `AVSampleBufferDisplayLayer` |
| E2EE | **未实现**：`enableE2EE` 返回 `unimplemented` 错误，不会静默降级 |

---

## 2. 工程集成

### 2.1 加入 SDK

把 `dist/JitsiMeetSDK.xcframework` 拖进 target 的
“Frameworks, Libraries, and Embedded Content”，选择 **Do Not Embed**。
`WebRTC` 才是唯一需要 Embed & Sign 的动态框架。

CocoaPods 只用于 WebRTC：

```ruby
platform :ios, '15.0'

target 'YourApp' do
  use_frameworks!
  pod 'JitsiWebRTC', '124.0.2'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
```

### 2.2 拷贝 JS 运行时 bundle

静态库不能携带资源。把 `dist/JitsiMeetSDK_JitsiMeetSDK.bundle` 加到 target 的
**Copy Bundle Resources**。缺失时 SDK 启动即 `fatalError`（找不到 bundle 不会降级）。

### 2.3 链接的系统框架

SDK 用到以下系统框架，缺失会在链接期报未定义符号：

```
UIKit AVFoundation CoreMedia CoreVideo CoreImage Accelerate
JavaScriptCore ReplayKit SwiftUI
```

### 2.4 Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>需要摄像头才能加入视频会议</string>
<key>NSMicrophoneUsageDescription</key>
<string>需要麦克风才能加入语音会议</string>
```

使用 Xcode 26+ SDK 构建时，app 必须采用 **UIScene 生命周期**，否则启动会停在 `main` 的
`EXC_BREAKPOINT`（`_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`）。
`SceneDelegate` 里创建窗口即可。

### 2.5 纯 Objective-C 工程

SDK 是 Swift 静态框架，纯 ObjC target 不会配置 Swift 运行时，链接期会报
`auto-linked library 'swiftCompatibility56'`。在 Build Settings 里设置：

```
ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES
```

并保留一个空的 `.swift` 文件（内容可以是 `import Foundation`），让 target 变成“混合”工程。
ObjC 代码本身不需要写任何 Swift。

### 2.6 导入

```objectivec
@import JitsiMeetSDK;
// 或
#import <JitsiMeetSDK/JitsiMeetSDK.h>
```

---

## 3. 最小可行接入

顺序固定：`bootstrap` → `connect` → `preparePreview` → `joinPreparedRoom`。
每一步都通过 completion 报告；失败时 `lastError` 也有最近一条错误。

```objectivec
#import "MeetingViewController.h"

@interface MeetingViewController () <JitsiSDKDelegate>
@property (nonatomic) UIView *previewHost;
@property (nonatomic) UIView *localTile;
@property (nonatomic) UIView *grid;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *tiles;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *canvases;
@property (nonatomic, strong) NSMutableArray<NSString *> *tileOrder;
@property (nonatomic, strong) UIView *localCanvas;
@end

@implementation MeetingViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.tiles = [NSMutableDictionary dictionary];
    self.canvases = [NSMutableDictionary dictionary];
    self.tileOrder = [NSMutableArray array];
    // previewHost / localTile / grid 按 16:9 约束搭好（略）

    JitsiSDK *sdk = JitsiSDK.shared;
    sdk.delegate = self;
    sdk.defaultCanvasStyle.fillMode = @"fit";   // 整帧可见，不裁剪、不拉伸
    sdk.defaultCanvasStyle.showsConnectionBadge = YES;
    // 逐画布覆盖：本机自拍用更大的头像（其余画布仍走 defaultCanvasStyle，见 §5.2）。
    JitsiCanvasStyle *selfStyle = [JitsiCanvasStyle defaultStyle];
    selfStyle.fillMode = @"fit";
    selfStyle.avatarSize = 72;
    [sdk setCanvasStyle:selfStyle forParticipant:@"local"];

    // 1. 安装引擎。host 必须显式给出，SDK 不会回退到任何公共服务。
    [sdk bootstrapWithConferenceHost:@"meet.example.org:8443"
                            logLevel:@"info"
                      debugSignaling:NO          // Release 必须为 NO
                              region:@"international"
                          completion:^(NSError *error) {
        if (error) { return [self fail:@"bootstrap" error:error]; }

        // 2. 建立 XMPP 连接。transport 可写 auto / websocket / bosh。
        //    token 为空表示匿名（guest）登录，取决于部署是否允许。
        [sdk connectWithServiceURL:@"wss://meet.example.org:8443/xmpp-websocket"
                            domain:@"meet.jitsi"
                               muc:@"muc.meet.jitsi"
                             token:nil
                          username:nil
                          password:nil
                         transport:@"auto"
                        completion:^(NSError *error) {
            if (error) { return [self fail:@"connect" error:error]; }

            // 3. 打开采集但不入会。房间此时不可见，别的参会者看不到你。
            [sdk preparePreview:@"room-123"
                    displayName:@"张三"
                          email:nil
                      avatarURL:nil
                          audio:YES
                          video:YES
                     completion:^(NSError *error) {
                if (error) { return [self fail:@"preparePreview" error:error]; }
                [self attachLocalCanvasTo:self.previewHost];
                // 展示预览页的麦克风/摄像头/入会按钮（略）
            }];
        }];
    }];
}

- (void)joinTapped:(id)sender {
    // 4. 复用预览的采集直接入会，摄像头不会重启。
    [JitsiSDK.shared joinPreparedRoomWithPassword:nil completion:^(NSError *error) {
        if (error) { [self fail:@"join" error:error]; }
    }];
}

- (void)leaveTapped:(id)sender {
    [JitsiSDK.shared leave];                // 离会并断开 XMPP
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)fail:(NSString *)step error:(NSError *)error {
    NSLog(@"%@ failed: %@ (%@ %ld)", step, error.localizedDescription, error.domain, (long)error.code);
}
@end
```

---

## 4. 入会前的自拍预览

### 4.1 专用 API

| 调用 | 作用 |
| --- | --- |
| `preparePreview:displayName:email:avatarURL:audio:video:completion:` | 创建会议对象并打开采集，**不发布**；`isPreviewing == YES` |
| `localCanvasView` | 自拍视图，首次预览后创建；静音/摄像头/说话状态自动跟随 |
| `joinPreparedRoomWithPassword:completion:` | 用同一份采集入会；密码在这里补 |
| `stopPreview` | 取消预览、释放摄像头/麦克风，但保持 XMPP 连接 |
| `joinRoom:…` | 一步完成 preview + join（没有预览页时用） |

`audio` / `video` 是**入会时的静音选择**，不是“要不要创建轨道”：两条轨道都会创建，被关掉的
在入会前 disable，进房后 `setAudioMuted:` / `setVideoMuted:` 仍能打开。

权限被拒时，`preparePreview` 只丢掉被拒的那一路采集（例如只有麦克风），不会整体失败；
宿主可以提示用户后继续入会。

### 4.2 挂载自拍画布

`localCanvasView` 是一个普通 `UIView`，宿主每块画布只创建一次。在预览页和会议页之间切换时
**移动同一个 view**，不要重新创建：

```objectivec
- (void)attachLocalCanvasTo:(UIView *)host {
    UIView *canvas = JitsiSDK.shared.localCanvasView;
    if (!canvas) { return; }
    if (self.localCanvas == canvas && canvas.superview == host) { return; }

    [canvas removeFromSuperview];
    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:canvas];
    [NSLayoutConstraint activateConstraints:@[
        [canvas.topAnchor constraintEqualToAnchor:host.topAnchor],
        [canvas.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
    self.localCanvas = canvas;
}
```

自拍框建议固定 **16:9**（`height = width × 9 / 16`）；模拟器没有摄像头画面时是纯黑，
可加 1pt 淡描边让区域可见。

---

## 5. 会议画面

### 5.1 本机与远端画布

| 来源 | 获取方式 |
| --- | --- |
| 本机 | `JitsiSDK.shared.localCanvasView`（永不通过 delegate 下发） |
| 远端 | `jitsiDidJoinRemoteCanvas:participantID:displayName:` 交付已接好的 `UIView` |
| 晚订阅 | `canvasViewForParticipant:` 按 id 取回**同一个**视图 |
| 移除 | `jitsiDidLeaveRemoteParticipant:`（挂断时每个远端都会回调一次） |

画布视图会自己刷新画面、麦克风徽标、说话描边、连接质量；宿主只负责 **frame** 和层级
（直接 `addSubview:` 即可，不需要 child view controller containment）。

### 5.2 画布外观

所有画布默认使用 `defaultCanvasStyle`；某一块要不一样时用 `setCanvasStyle:forParticipant:`
（本机键是 `"local"`，远端用回调里的 `participantID`）。修改会**实时**作用到已经显示的画布，
传 `nil` 恢复默认：

```objectivec
JitsiSDK *sdk = JitsiSDK.shared;

// 默认样式：所有画布
sdk.defaultCanvasStyle.cornerRadius = 10;
sdk.defaultCanvasStyle.fillMode = @"fit";      // "fill" 裁切铺满；"fit" 整帧可见并留黑边
sdk.defaultCanvasStyle.showsName = YES;
sdk.defaultCanvasStyle.showsMicrophoneBadge = YES;
sdk.defaultCanvasStyle.showsConnectionBadge = YES;
sdk.defaultCanvasStyle.avatarSize = 56;        // 摄像头关闭时的头像直径
sdk.defaultCanvasStyle.avatarPosition = @"center";
sdk.defaultCanvasStyle.namePosition = @"bottomLeading";
sdk.defaultCanvasStyle.nameFontSize = 13;

// 只改本机自拍；远端继续走默认样式
JitsiCanvasStyle *local = [JitsiCanvasStyle defaultStyle];
local.avatarPosition = @"topLeading";
local.avatarSize = 72;
local.namePosition = @"bottomTrailing";
local.nameFontSize = 16;
[sdk setCanvasStyle:local forParticipant:@"local"];

// 也可以按远端 id 覆盖；传 nil 恢复默认
[sdk setCanvasStyle:nil forParticipant:remoteParticipantID];
```

位置字段统一取 `"center"` / `"topLeading"` / `"topTrailing"` / `"bottomLeading"` /
`"bottomTrailing"`。`avatarPosition` / `avatarSize` 控制摄像头关闭时的头像位置与直径；
`namePosition` / `nameFontSize` 控制底部说明行（举手、麦克风电平 + 名称）的位置与字号。
旧的 `canvasCornerRadius` / `canvasFillMode` / `canvasShowsName` / `canvasShowsConnectionBadge` /
`canvasAvatarSize` 仍可用，是 `defaultCanvasStyle` 对应字段的快捷方式。

### 5.3 16:9 自适应画廊（实例）

“能放下全部参会者的最少列数”，行与列都居中；每个格子固定 16:9，配合 `fit` 模式，
任何画面比例都不会被拉伸或裁剪：

```objectivec
- (void)layoutGrid {
    NSUInteger count = self.tileOrder.count;
    CGRect bounds = self.grid.bounds;
    if (count == 0 || bounds.size.width <= 0) { return; }

    CGFloat gap = 4, inset = 2;
    CGFloat maxWidth = bounds.size.width - 2 * inset;
    CGFloat maxHeight = bounds.size.height - 2 * inset;

    NSUInteger columns = 1;
    CGFloat tileWidth = 0;
    for (NSUInteger candidate = 1; candidate <= count; candidate++) {
        CGFloat width = (maxWidth - (candidate - 1) * gap) / candidate;
        CGFloat height = width * 9.0 / 16.0;
        NSUInteger rows = (count + candidate - 1) / candidate;
        if (rows * height + (rows - 1) * gap <= maxHeight) {
            columns = candidate;
            tileWidth = width;
            break;
        }
    }
    if (tileWidth <= 0) {
        columns = count;
        tileWidth = (maxWidth - (count - 1) * gap) / count;
    }

    CGFloat tileHeight = tileWidth * 9.0 / 16.0;
    NSUInteger rows = (count + columns - 1) / columns;
    CGFloat originY = inset + MAX(0, (maxHeight - (rows * tileHeight + (rows - 1) * gap)) / 2);

    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger row = index / columns;
        NSUInteger column = index % columns;
        NSUInteger items = MIN(columns, count - row * columns);
        CGFloat rowWidth = items * tileWidth + (items - 1) * gap;
        CGFloat originX = (bounds.size.width - rowWidth) / 2;

        UIView *host = [self.tileOrder[index] isEqualToString:@"local"]
            ? self.localTile : self.tiles[self.tileOrder[index]];
        host.frame = CGRectMake(originX + column * (tileWidth + gap),
                                originY + row * (tileHeight + gap),
                                tileWidth, tileHeight);
    }
}
```

`viewDidLayoutSubviews` 和每次增删 tile 后调用 `layoutGrid`，旋转/分屏时才能跟着变。

### 5.4 远端 tile 增删

```objectivec
- (void)jitsiDidJoinRemoteCanvas:(UIView *)canvas
                   participantID:(NSString *)participantID
                     displayName:(NSString *)displayName {
    [self removeRemoteTile:participantID];          // 重连会重复下发

    UIView *host = [[UIView alloc] init];
    host.backgroundColor = UIColor.blackColor;
    host.layer.cornerRadius = 10;
    host.clipsToBounds = YES;
    [self.grid addSubview:host];

    canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:canvas];
    [NSLayoutConstraint activateConstraints:@[
        [canvas.topAnchor constraintEqualToAnchor:host.topAnchor],
        [canvas.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [canvas.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [canvas.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];

    self.tiles[participantID] = host;
    self.canvases[participantID] = canvas;
    [self.tileOrder addObject:participantID];
    [self layoutGrid];
}

- (void)removeRemoteTile:(NSString *)participantID {
    UIView *host = self.tiles[participantID];
    UIView *canvas = self.canvases[participantID];
    if (!host) { return; }
    [canvas removeFromSuperview];
    [host removeFromSuperview];
    [self.tiles removeObjectForKey:participantID];
    [self.canvases removeObjectForKey:participantID];
    [self.tileOrder removeObject:participantID];
    [self layoutGrid];
}
```

实际实现见 `DemoObjC/Sources/ViewController.m`，它还处理了重连时同名画布重复下发、
离会时统一清空、以及本机自拍在预览页与会议 tile 之间的移动。

---

## 6. 控制栏

| 操作 | API |
| --- | --- |
| 麦克风 | `setAudioMuted:completion:`；读 `isAudioMuted` |
| 摄像头 | `setVideoMuted:completion:`；读 `isVideoMuted` |
| 前后摄 | `switchCameraWithCompletion:` |
| 音频路由 | `setAudioOutputRoute:@"speaker"/@"receiver"`；读 `audioOutputRoute` |
| 屏幕共享 | `startScreenShareWithCompletion:` / `stopScreenShare` |
| 分辨率/帧率 | `applyVideoConstraintsWithWidth:height:frameRate:completion:`（0 表示保持不变） |
| 离会 | `leave`（断开会话）；只断连接用 `disconnect` |

音频路由的读取值可能是 `receiver`、`speaker`、`headphones`、`bluetooth`、`carPlay`。
蓝牙/耳机/CarPlay 连接时系统优先，`setAudioOutputRoute:` 只接受 `speaker` 和 `receiver`。
路由变化通过 `jitsiDidChangeAudioOutputRoute:` 通知。

起始路由在 `bootstrap` 前配置，每次音频会话激活都会重新应用（不会沿用上一次通话的输出）：

```objectivec
JitsiSDK.shared.preferredAudioOutput = JitsiAudioOutputRouteReceiver;  // 默认 Speaker
[JitsiSDK.shared bootstrapWithConferenceHost:@"meet.example.org" …
                                  completion:^(NSError *error) {}];
```

屏幕共享还需要宿主工程提供 **Broadcast Upload Extension** 和 app/extension 共用的
**App Group**，并弹出系统广播选择器。这两个配置走 Swift 的 `ScreenShareConfiguration`
（`appGroupIdentifier`、`extensionBundleIdentifier`），模板见
`Templates/JitsiBroadcastExtension/`；只有 ObjC 门面时请通过 bridging 或小段 Swift 配置。

---

## 7. 参会者、音量与说话状态

### 7.1 参会者行

`participants` **只含远端**，本端请自行插入一行。每行字段：

| 键 | 类型 | 说明 |
| --- | --- | --- |
| `id` | NSString | MUC participant id |
| `displayName` | NSString | 显示名 |
| `role` | NSString | `owner` / `moderator` / `participant` / `visitor` / `none` |
| `raisedHand` | NSNumber(BOOL) | 举手 |
| `isAudioMuted` / `isVideoMuted` | NSNumber(BOOL) | 当前静音状态 |
| `audioLevel` | NSNumber(0…1) | 实时麦克风电平 |
| `isSpeaking` | NSNumber(BOOL) | 电平 ≥ 阈值且未静音 |
| `tracks` | NSArray | 每项含 `id/mediaType/videoType/muted/isLocal/label` |
| `properties` | NSDictionary | 参会者 presence 属性 |
| `jid/status/statsID` | NSString | 连接信息 |
| `isSilent/isReplacing/isReplaced/isHidden` | NSNumber(BOOL) | 与会/静音入会/换设备等状态 |
| `avatarURL/email/connectionJID/botType` | 可选 | 有才返回 |

### 7.2 逐人电平

- `audioLevels()`：`{ participantID: 0…1 }`，本端键是 `"local"`。
- `jitsiDidUpdateAudioLevels:`：约每 200 ms 一次，主队列；**不会**触发
  `jitsiDidChangeState:`，适合直接刷新电平条。
- 状态快照另有 `localAudioLevel` / `localIsSpeaking` 可直接驱动控制栏。

### 7.3 精确的媒体变化

| 回调 | 语义 |
| --- | --- |
| `jitsiRemoteParticipant:didChangeMicrophoneMuted:` | 逐人麦克风：首次出现回调一次当前状态（含入会时已在房里的人），之后只报变化 |
| `jitsiRemoteParticipant:didChangeCameraMuted:` | 逐人摄像头：同上，首次回调一次，然后只报变化；只看摄像头源，共享期间关摄像头也会立刻报（`participants` 行的 `isVideoMuted` 折叠全部视频源） |
| `jitsiDidMuteAllRemotes:participantIDs:` | “主持人静音所有人”的合并启发式（800 ms 内 ≥2 人） |
| `jitsiDidChangeAVModeration:enabled:actorID:` | 房间级 AV moderation 开关（权威信号） |

---

## 8. 会议计时

| 用法 | 说明 |
| --- | --- |
| `meetingTimeLimit = 3600` | 宿主展示用的时限（秒），0 表示只显示已用时间 |
| `jitsiDidJoinMeetingTiming:` | 入会后回调一次 `JitsiMeetingTiming` |
| `meetingElapsedSeconds` | 自会议开始（服务端创建时间优先）起的秒数 |
| `meetingRemainingSeconds` | 剩余秒数，`NSNumber`；无时限为 nil |
| `meetingElapsedSecondsAt:` / `meetingRemainingSecondsAt:` | 按指定时间计算，适合每秒 tick |

`JitsiMeetingTiming` 字段：`startedAt`、`elapsedSecondsAtJoin`、`timeLimitSeconds`（可空）、
`startSource`（`serverCreated` / `serverRestricted` / `localJoin`）、`limitSource`
（`serverEnforced` / `hostConfigured` / nil）。服务端时限优先于宿主配置的展示值。

语义与 jitsi-meet 一致：计时基准是**会议本身的持续时间**，不是个人入会时长。

---

## 9. 密码、等候室与重连

| 场景 | 判断 | 处理 |
| --- | --- | --- |
| 房间有密码 | `requiresPassword == YES` + 状态回调 | 输入密码后调 `joinPreparedRoomWithPassword:`（无需重连） |
| 已在等候室 | `isWaitingInLobby == YES` | 停留在等待页；主持人放行后自动进入 |
| 等主持人开房 | `isWaitingForHost == YES` | 该房间没有审批步骤，主持人开房即放行 |
| 主持人侧审批 | `lobbyUsers()` 行（`id/displayName/email/avatarURL`） | `approveLobbyUser:` / `denyLobbyUser:` |
| 主动敲门 | — | 通常由入会失败自动触发；也可 `joinLobbyWithDisplayName:email:` |
| 媒体中断 | `isMediaInterrupted == YES` | SDK 自动 ICE 重启，界面保持“重连中”即可 |
| 需要手动重试 | `canRetryConnection == YES` | `retryConnection`（复用带抖动的退避与刷新 token 流程） |
| 前后台 | — | 场景激活/失活时调用 `setAppActive:`，交给 SDK 判断是否需要重入 |

**不要**在 `requiresPassword` 时自动循环重入；密码只能由用户提供。等候室与密码都由 SDK
在入会失败时自动判定，宿主只按 `isWaitingInLobby` / `isWaitingForHost` / `requiresPassword`
渲染对应页面即可。

---

## 10. 状态、事件与扩展 API

### 10.1 必选回调与状态字典

`jitsiDidChangeState:` 是 `JitsiSDKDelegate` 的**必选**方法，连接、参会者、轨道、静音、
锁定、录制等变化后都会回调一次完整快照：

`isConnected`、`isJoined`、`isPreviewing`、`isSwitchingRoom`、`isMediaInterrupted`、
`isWaitingInLobby`、`isWaitingForHost`、`requiresPassword`、`isNetworkOnline`、
`isAudioMuted`、`isVideoMuted`、`isScreenSharing`、`isLocked`、`e2eeEnabled`、
`visitorsSupported`、`participants`、`localTracks`、`remoteTracks`、
`localAudioLevel`、`localIsSpeaking`、`localConnectionQuality`、`breakoutRooms`、`breakoutRoomsState`；
以及可选的 `lastError`、`serverRegion`、`serverShard`、`audioOutputRoute`。

房间能力走 `conferenceState()`：`isModerator`、`lobbySupported`、`lobbyEnabled`、
`authRequired`、`passwordRequired`、`isLocked`、`canEndConference`、`e2eeEnabled`、
`visitorsSupported`、`myUserId`、`startMutedPolicy`、`localParticipantProperties`、
`conferenceProperties`、`lobbyUsers`、`avModeration`、`breakoutRooms`、
`breakoutRoomsState`。

### 10.2 专用回调

| 回调 | 时机 |
| --- | --- |
| `jitsiDidUpdateAudioLevels:` | 逐人电平刷新（~5 次/秒） |
| `jitsiDidChangeAudioOutputRoute:` | 系统输出路由变化 |
| `jitsiDidChangeConnectionQuality:displayName:level:summary:` | 本机（id 为 nil）或某个参会者的 good/fair/poor 档位变化；只在档位变化时回调 |
| `jitsiDidJoinRemoteCanvas:participantID:displayName:` | 远端可渲染 |
| `jitsiDidLeaveRemoteParticipant:` | 远端离开 / 挂断清理 |
| `jitsiRemoteParticipant:didChangeMicrophoneMuted:` | 远端麦克风：首次出现一次 + 之后每次开关 |
| `jitsiRemoteParticipant:didChangeCameraMuted:` | 远端摄像头：首次出现一次 + 之后每次开关 |
| `jitsiDidChangeAVModeration:enabled:actorID:` | AV moderation 开关 |
| `jitsiDidMuteAllRemotes:participantIDs:` | 主持人“静音所有人”启发式 |
| `jitsiDidJoinMeetingTiming:` | 入会后一次，交付会议锚点与时限 |

### 10.3 透传事件

其余事件通过 `jitsiDidReceiveEvent:payload:` 下发，`name` 是稳定的字符串，`payload` 是
lib-jitsi-meet 原始载荷。常用名称：

```
connectionStatus        connectionInterrupted   connectionRestored   networkChanged
conferenceJoined        conferenceLeft          conferenceFailed     tokenExpired
participantJoined       participantLeft         participantMuted     raisedHandChanged
participantDisplayNameChanged  participantAvatarChanged  participantEmailChanged
participantRoleChanged  participantPropertyChanged  lockStateChanged
dominantSpeakerChanged  localTrackAdded         localTrackRemoved    remoteTrackAdded
remoteTrackRemoved      trackMuteChanged        connectionQuality
chatMessage             endpointMessage         commandReceived      reactionReceived
recordingStateChanged   e2eeStateChanged        participantKicked    kicked
localMutedByFocus       lobbyWaitingForHost     lobbyUserJoined      lobbyUserLeft
breakoutRoomsUpdated    breakoutRoomsMoveToRoom avModerationChanged  conferenceCreatedTimestamp
```

高频统计类事件（`audioLevels`、各类 `*StatsReceived`）不建议直接打日志。

### 10.4 主持人 / 信令 / 扩展 API 速查

| 分组 | 方法 |
| --- | --- |
| 主持人 | `kickParticipant:`、`muteParticipant:audio:mute:`、`endConferenceWithCompletion:`、`lockRoomWithPassword:`、`unlockRoomWithCompletion:`、`grantModerator:`、`revokeModerator:`、`setSubject:`、`setStartMutedPolicyWithAudio:video:` |
| 等候室 | `enableLobbyWithCompletion:`、`disableLobbyWithCompletion:`、`lobbyUsers()`、`approveLobbyUser:`、`denyLobbyUser:`、`sendLobbyMessage:to:`、`myLobbyUserIDWithCompletion:` |
| AV moderation | `isAVModerationSupportedWithCompletion:`、`enableAVModeration:`、`disableAVModeration:`、`approveAVModeration:mediaType:`、`rejectAVModeration:mediaType:`（mediaType：`audio`/`video`/`desktop`） |
| 分组讨论 | `breakoutRooms()`、`breakoutRoomsState()`、`createBreakoutRoom:`、`renameBreakoutRoom:subject:`、`removeBreakoutRoom:`、`sendParticipant:toBreakoutRoom:`、`switchToBreakoutRoom:`、`returnToMainRoomWithCompletion:` |
| 聊天/信令 | `sendChat:`、`sendJSONChat:to:`、`sendEndpointMessage:to:`、`sendCommand:values:`、`addCommandListener:`、`sendReaction:messageID:to:`、`setDisplayName:`、`raiseHand:` |
| 通话扩展 | `sendTones:duration:pause:`、`isSIPCallingSupportedWithCompletion:`、`dial:`、`authenticateAndUpgradeRoleWithId:password:` |
| 媒体增强 | `replaceLocalTrack:with:`、`setReceiverConstraintsWithLastN:…`、`setDesktopSharingFrameRate:`、`videoCapabilitiesWithCompletion:`、`runPreCallTestWithIceServers:` |
| 统计 | `speakerStatsWithCompletion:`、`connectionTimesWithCompletion:`、`connectionLogsWithCompletion:`（仅 `debugSignaling == YES`） |
| 参会者属性 | `setLocalParticipantProperty:value:`、`removeLocalParticipantProperty:`、`localParticipantProperty:` |
| 轮询/录制 | `pollsSupportedWithCompletion:`、`createPollWithQuestion:answers:`、`answerPoll:answers:`、`startRecordingWithCompletion:`、`stopRecordingWithCompletion:` |
| 收端静音 | `setRemoteAudioMuted:`（只影响本机播放） |
| JWT | `tokenProvider`（主队列取新 token）、`refreshToken:completion:` |

---

## 11. 生命周期与清理

```text
bootstrap ──> connect ──> preparePreview ──> joinPreparedRoom ──> isJoined
                                    │                                  │
                              stopPreview                        leave / disconnect
                                    │                                  │
                                 isPreviewing = NO            isJoined = NO
```

- `leave`：离会并断开 XMPP；再次入会要重新 `connect`。
- `disconnect`：只断连接，保留引擎。
- `shutdown`：释放 JavaScriptCore 引擎；要切换 host（另一个部署）必须先 `shutdown`
  再重新 `bootstrap`，SDK 不会偷偷连到别的服务。
- 每个 `jitsiDidLeaveRemoteParticipant:` 都要把对应的画布视图从宿主上移除，
  否则挂断后旧画面和旧视图会残留。
- App 进入后台/回前台时调用 `setAppActive:`，由 SDK 判断是否需要重入。

---

## 12. 线程与内存规则

1. **所有回调、completion 都在主队列**；可以直接更新 UI。
2. `delegate` 是 `weak`；持有方负责在销毁前置 nil。
3. 画布是普通 `UIView`，直接 `addSubview:` 并给约束即可，不需要 child view controller。
4. `localCanvasView` 每次预览创建一次，跨页面移动 **同一个 view**，不要重新创建。
5. `canvasViewForParticipant:` 返回的视图与 delegate 下发的是同一个；适合刷新列表后重新取。
6. 逐画布样式对象由门面持有引用；改属性即可实时刷新，不需要重新取画布。
7. 高频事件（电平、统计）不要写进无上限日志。

---

## 13. 安全约束

- `debugSignaling` 在 Release 必须为 `NO`：它会把 Jingle/XMPP 原文（含 JWT、TURN 凭据）
  写进日志。
- `connectionLogs` 只在 `debugSignaling == YES` 时返回内容，不要打包进用户反馈附件。
- host / service URL / domain / MUC 必须由宿主显式配置；SDK 没有公共服务回退。
- `p2pSTUNServers` 默认空，不会回退到 lib-jitsi-meet 的公共 STUN 服务器。
- E2EE 未实现：调用 `enableE2EE` 会返回 `unimplemented`，不会“看起来加密”。
- 二进制分发保留 `dist/WebRTC-LICENSE.txt`。

---

## 14. 排错

| 现象 | 原因 / 处理 |
| --- | --- |
| 启动停在 `main` 的 `EXC_BREAKPOINT` | 未采用 UIScene 生命周期；补 `UIApplicationSceneManifest` + `SceneDelegate` |
| 启动 `fatalError`，提示找不到 bundle | `JitsiMeetSDK_JitsiMeetSDK.bundle` 未加入 Copy Bundle Resources |
| 链接报 `swiftCompatibility56` | 纯 ObjC target；设 `ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES` 并加一个空 `.swift` |
| `connect failed` | 检查 scheme（`wss`/`https`）、端口、匿名登录域；自建部署通常要求 `hosts.domain` / `hosts.muc` 与 `config.js` 一致 |
| `requiresPassword` | 用 `joinPreparedRoomWithPassword:` 补密码，不要重连 |
| `isWaitingInLobby` | 已敲门，等主持人；`isWaitingForHost` 表示等主持人开房 |
| 模拟器没有画面 | 模拟器无摄像头，本机/远端显示黑底 + 名字/电平/头像；真机才有画面 |
| 远端一直黑屏 | 确认 `canRetryConnection` 未为 YES、媒体未中断；检查画布视图是否已 `addSubview:` 到可见宿主 |
| 画面被拉伸/裁切 | 用 16:9 容器 + `defaultCanvasStyle.fillMode = @"fit"` |
| 头像/名称位置不合适 | 调 `avatarPosition` / `namePosition` / `avatarSize` / `nameFontSize`，可按人覆盖 |

---

## 15. 验收清单

- [ ] `bootstrap` / `connect` 成功，`isConnected == YES`
- [ ] 预览页出现自拍（真机），静音/关摄像头按钮实时生效
- [ ] `joinPreparedRoom` 后摄像头不重启、`isPreviewing == NO`
- [ ] 两名参会者时网格为 16:9 单元格，`fit` 模式无拉伸/裁切
- [ ] `defaultCanvasStyle` 与 `setCanvasStyle:forParticipant:` 生效，已显示的画布实时刷新
- [ ] 远端静音/关摄像头/说话状态与会话一致
- [ ] 密码房间与等候室流程可完成
- [ ] 断网后 `isMediaInterrupted` 出现并自动恢复；必要时 `retryConnection`
- [ ] `leave` 后回到配置页，再次入会不残留旧 tile 与旧会话
- [ ] Release 构建 `debugSignaling == NO`

---

**参考实现**：`DemoObjC/Sources/ViewController.m`（配置 → 预览 → 会议三段式 UIKit 界面）、
`DemoObjC/README.md`（工程配置与自动化启动参数）。
