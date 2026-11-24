//
//  MeetViewController.m
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//

#import "MeetViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <LJMeet/LJMeet.h>
#import <Photos/Photos.h>
#import "MeetActionView.h"

static NSString *const kDefaultServiceURL = @"wss://memeeting.melinked.com:8443/xmpp-websocket";
static NSString *const kDefaultDomain = @"meet.jitsi";
static NSString *const kDefaultMuc = @"muc.meet.jitsi";
//static NSString *const kDefaultRoom = @"2115362625856700417";
static NSString *const kDefaultRoom = @"adm-test";
static NSString *const kDefaultDisplayName = @"ObjC Guest";

static NSUInteger const kMaxLogLines = 200;
static CGFloat const kTileGap = 8;

/// Meeting clock: `MM:SS`, widening to `HH:MM:SS` only when the room runs past an hour.
static NSString *FormatClock(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)floor(MAX(0, seconds));
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

static UIImage *SymbolImage(NSString *name) {
    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:name withConfiguration:config];
}

#define kJMeetSDK [JitsiSDK shared]

@interface MeetViewController ()<JitsiSDKDelegate>
@property (nonatomic, strong) UIView *meetBgView;

@property (nonatomic, strong) UIStackView *bottomView;


@property (nonatomic, strong) UIView *preJoinBar;
@property (nonatomic, strong) UIButton *connectButton;

@property (nonatomic, strong) UIView *controlBar;
@property (nonatomic, strong) MeetActionView *micButton;
@property (nonatomic, strong) MeetActionView *cameraButton;
@property (nonatomic, strong) MeetActionView *flipButton;
@property (nonatomic, strong) MeetActionView *routeButton;
@property (nonatomic, strong) MeetActionView *recordButton;
@property (nonatomic, strong) MeetActionView *leaveButton;


@property (nonatomic, strong) UIView *preJoinView;
@property (nonatomic, strong) UIView *preHostView;
@property (nonatomic, strong) MeetActionView *preMicButton;
@property (nonatomic, strong) MeetActionView *preCameraButton;
@property (nonatomic, strong) MeetActionView *preLeaveButton;

@property (nonatomic, assign) BOOL bootstraped;



@end

@implementation MeetViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LJMeet · ObjC";
    self.view.backgroundColor = [UIColor blackColor];
//    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self configSDK];
    
    [self.view addSubview:self.meetBgView];
    [self.view addSubview:self.bottomView];
    
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.meetBgView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.meetBgView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.meetBgView.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [self.meetBgView.bottomAnchor constraintEqualToAnchor:self.bottomView.topAnchor],
        
        [self.bottomView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.bottomView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.bottomView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
    ]];
    
}

- (void)configSDK {
    kJMeetSDK.delegate = self;
    
    kJMeetSDK.defaultCanvasStyle.fillMode = JitsiCanvasFillModeFit;
    kJMeetSDK.defaultCanvasStyle.nameFontSize = 12;
    
    JitsiCanvasStyle *localStyle = [JitsiCanvasStyle defaultStyle];
    localStyle.fillMode = JitsiCanvasFillModeFill;
    localStyle.avatarSize = 72;
    localStyle.nameFontSize = 12;
    [kJMeetSDK setCanvasStyle:localStyle forParticipant:@"local"];
    __weak typeof(self) weakSelf = self;
    //开启自定义ADM(Audio Device Manager) 如果需要本地录制合成，必须开启ADM
    
    
    kJMeetSDK.useCustomAudioDevice = YES;
    [kJMeetSDK bootstrapWithConferenceHost:[self hostFromServiceURL:kDefaultServiceURL]
                                  logLevel:JitsiLogLevelInfo
                            debugSignaling:NO
                                    region:@"chinaMainland"
                                completion:^(NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (error) {
            NSLog(@"[JMeet SDK] bootstrap error: %@", error);
            return;
        }
        self.bootstraped = YES;
        self.connectButton.userInteractionEnabled = YES;
    }];
}

- (void)connectServer:(UIButton *)sender {
    
    if (sender.selected) {
        [kJMeetSDK disconnect];
        self.preJoinView.hidden = YES;
        self.preJoinBar.hidden = NO;
        self.controlBar.hidden = YES;
        return;
    }
    __weak typeof(self) weakSelf = self;
    [kJMeetSDK connectWithServiceURL:kDefaultServiceURL
                              domain:kDefaultDomain
                                 muc:kDefaultMuc
                               token:nil
                            username:nil
                            password:nil
                           transport:@"auto"
                          completion:^(NSError * _Nullable connectError) {
        __strong typeof(weakSelf) innerSelf = weakSelf;
        if (!innerSelf) { return; }
        if (connectError) {
            NSLog(@"[JMeet SDK] connect error: %@", connectError);
            return;
        }
        innerSelf.preJoinBar.hidden = YES;
        innerSelf.controlBar.hidden = YES;
        innerSelf.preJoinView.hidden = NO;
    }];
    
}

- (NSString *)hostFromServiceURL:(NSString *)serviceURL {
    NSURLComponents *components = [NSURLComponents componentsWithString:serviceURL];
    if (components.host.length == 0) {
        return serviceURL;
    }
    if (components.port != nil) {
        return [NSString stringWithFormat:@"%@:%@", components.host, components.port];
    }
    return components.host;
}


- (void)actionButtonClick:(UIButton *)sender {
    
}

#pragma mark- JitsiSDKDelegate

- (void)jitsiDidChangeState:(NSDictionary<NSString *,id> * _Nonnull)state { 
    
}

- (void)jitsiDidReceiveEvent:(NSString *)name payload:(NSDictionary<NSString *,id> *)payload {
    
}

- (void)jitsiDidChangeAudioOutputRoute:(NSString *)route {
    
}

- (void)jitsiDidFinishLocalRecording:(NSURL *)fileURL error:(NSError *)error {
    
}

- (void)jitsiDidJoinRemoteCanvas:(UIView *)canvasView participantID:(NSString *)participantID displayName:(NSString *)displayName {
    
}

- (void)jitsiDidLeaveRemoteParticipant:(NSString *)participantID {
    
}

- (void)jitsiDidUpdateAudioLevels:(NSDictionary<NSString *,NSNumber *> *)levels {
    
}

- (void)jitsiDidJoinMeetingTiming:(JitsiMeetingTiming *)timing {
    
}


#pragma mark- getter
- (UIView *)meetBgView {
    if (!_meetBgView) {
        _meetBgView = [[UIView alloc] init];
        _meetBgView.translatesAutoresizingMaskIntoConstraints = NO;
    }
    return _meetBgView;
}


- (UIStackView *)bottomView {
    if (!_bottomView) {
        _bottomView = [[UIStackView alloc] initWithArrangedSubviews:@[self.preJoinBar,self.controlBar]];
        _bottomView.distribution = UIStackViewDistributionFill;
        _bottomView.alignment = UIStackViewAlignmentCenter;
        _bottomView.axis = UILayoutConstraintAxisVertical;
        _bottomView.spacing = 0;
        _bottomView.translatesAutoresizingMaskIntoConstraints = NO;
        
        self.controlBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.preJoinBar.translatesAutoresizingMaskIntoConstraints = NO;
        [self.preJoinBar.widthAnchor constraintEqualToAnchor:_bottomView.widthAnchor].active = YES;
        [self.controlBar.widthAnchor constraintEqualToAnchor:_bottomView.widthAnchor].active = YES;
    }
    return _bottomView;
}

- (UIView *)preJoinBar {
    if (!_preJoinBar) {
        _preJoinBar = [[UIView alloc] init];
        [_preJoinBar addSubview:self.connectButton];
        self.connectButton.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [self.connectButton.leadingAnchor constraintEqualToAnchor:_preJoinBar.leadingAnchor constant:10],
            [self.connectButton.topAnchor constraintEqualToAnchor:_preJoinBar.topAnchor constant:5],
            [self.connectButton.trailingAnchor constraintEqualToAnchor:_preJoinBar.trailingAnchor constant:-10],
            [self.connectButton.bottomAnchor constraintEqualToAnchor:_preJoinBar.bottomAnchor constant:-5],
            [self.connectButton.widthAnchor constraintEqualToConstant:45],
        ]];
    }
    return _preJoinBar;
}

- (UIButton *)connectButton {
    if (!_connectButton) {
        _connectButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _connectButton.userInteractionEnabled = NO;
        _connectButton.backgroundColor = [UIColor systemBlueColor];
        [_connectButton setTitle:@"Connect" forState:UIControlStateNormal];
        [_connectButton setTitle:@"Disconnect" forState:UIControlStateSelected];
        [_connectButton addTarget:self action:@selector(connectServer:) forControlEvents:UIControlEventTouchUpInside];
    }
    return _connectButton;
}

- (UIView *)controlBar {
    if (!_controlBar) {
        _controlBar = [[UIView alloc] init];
        _controlBar.hidden = YES;
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
            self.micButton,
            self.cameraButton,
            self.flipButton,
            self.routeButton,
            self.recordButton,
            self.leaveButton
        ]];
        
        content.axis = UILayoutConstraintAxisHorizontal;
        content.distribution = UIStackViewDistributionEqualCentering;
        content.alignment = UIStackViewAlignmentCenter;
        [_controlBar addSubview:content];
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [content.leadingAnchor constraintEqualToAnchor:_controlBar.leadingAnchor constant:10],
            [content.trailingAnchor constraintEqualToAnchor:_controlBar.trailingAnchor constant:-10],
            [content.topAnchor constraintEqualToAnchor:_controlBar.topAnchor constant:5],
            [content.bottomAnchor constraintEqualToAnchor:_controlBar.bottomAnchor constant:-5],
        ]];
    }
    return _controlBar;
}

- (MeetActionView *)micButton {
    if (!_micButton) {
        _micButton = [[MeetActionView alloc] initWithAction:MeetActionMic];
        _micButton.text = @"Mute";
        [_micButton setImage:SymbolImage(@"mic.fill") forState:UIControlStateNormal];
        [_micButton setImage:SymbolImage(@"mic.slash.fill") forState:UIControlStateSelected];
        [_micButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
    }
    return _micButton;
}

- (MeetActionView *)cameraButton {
    if (!_cameraButton) {
        _cameraButton = [[MeetActionView alloc] initWithAction:MeetActionCamera];
        _cameraButton.text = @"Camera";
        [_cameraButton setImage:SymbolImage(@"video.fill") forState:UIControlStateNormal];
        [_cameraButton setImage:SymbolImage(@"video.slash.fill") forState:UIControlStateSelected];
        [_cameraButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
        
    }
    return _cameraButton;
}

- (MeetActionView *)flipButton {
    if (!_flipButton) {
        _flipButton = [[MeetActionView alloc] initWithAction:MeetActionFlip];
        _flipButton.text = @"Flip";
        [_flipButton setImage:SymbolImage(@"arrow.triangle.2.circlepath") forState:UIControlStateNormal];
        [_flipButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
        
    }
    return _flipButton;
}

- (MeetActionView *)routeButton {
    if (!_routeButton) {
        _routeButton = [[MeetActionView alloc] initWithAction:MeetActionRoute];
        _routeButton.text = @"Audio";
        [_routeButton setImage:SymbolImage(@"speaker.wave.2.fill") forState:UIControlStateNormal];
        [_routeButton setImage:SymbolImage(@"ear.fill") forState:UIControlStateSelected];
        [_routeButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
        
    }
    return _routeButton;
}

- (MeetActionView *)recordButton {
    if (!_recordButton) {
        _recordButton = [[MeetActionView alloc] initWithAction:MeetActionRecord];
        _recordButton.text = @"Record";
        [_recordButton setImage:SymbolImage(@"record.circle") forState:UIControlStateNormal];
        [_recordButton setImage:SymbolImage(@"record.circle") forState:UIControlStateSelected];
        [_recordButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
        
    }
    return _recordButton;
}

- (MeetActionView *)leaveButton {
    if (!_leaveButton) {
        _leaveButton = [[MeetActionView alloc] initWithAction:MeetActionLeave];
        _leaveButton.text = @"Hang up";
        [_leaveButton setImage:SymbolImage(@"phone.down.fill") forState:UIControlStateNormal];
        [_leaveButton addTarget:self action:@selector(actionButtonClick:) forControlEvents:UIControlEventTouchUpInside];
    }
    return _leaveButton;
}

- (UIView *)preJoinView {
    if (!_preJoinView) {
        _preJoinView = [[UIView alloc] init];
    }
    return _preJoinView;
}


@end
