#import "ViewController.h"

#import <JitsiMeetSDK/JitsiMeetSDK.h>

// Self-hosted deployment used by this workspace. Every field is editable, and nothing falls
// back to a public service: clearing the URL simply refuses to connect. The public endpoints
// live on :8443 while Prosody answers as `meet.jitsi` and hosts MUC at `muc.meet.jitsi`
// (see the deployment's config.js).
static NSString *const kDefaultServiceURL = @"wss://tmeeting.maesgroup.com:8443/xmpp-websocket";
static NSString *const kDefaultDomain = @"meet.jitsi";
static NSString *const kDefaultMuc = @"muc.meet.jitsi";
static NSString *const kDefaultRoom = @"objc-demo";
static NSString *const kDefaultDisplayName = @"ObjC Guest";

static NSUInteger const kMaxLogLines = 200;

@interface ViewController () <JitsiSDKDelegate, UITextFieldDelegate, UITextViewDelegate>

@property (nonatomic, strong) UITextField *serviceURLField;
@property (nonatomic, strong) UITextField *domainField;
@property (nonatomic, strong) UITextField *mucField;
@property (nonatomic, strong) UITextField *tokenField;
@property (nonatomic, strong) UITextField *roomField;
@property (nonatomic, strong) UITextField *displayNameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UISwitch *audioSwitch;
@property (nonatomic, strong) UISwitch *videoSwitch;
@property (nonatomic, strong) UISwitch *autoJoinSwitch;

@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIButton *joinButton;
@property (nonatomic, strong) UIButton *skipButton;
@property (nonatomic, strong) UIButton *leaveButton;
@property (nonatomic, strong) UIButton *disconnectButton;
@property (nonatomic, strong) UIButton *muteAudioButton;
@property (nonatomic, strong) UIButton *muteVideoButton;
@property (nonatomic, strong) UIButton *switchCameraButton;

@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIStackView *joinSection;
@property (nonatomic, strong) UIStackView *roomSection;
/// One label per participant, keyed by MUC id with `"local"` for this endpoint. Updated in
/// place by the audio level callback, rebuilt on presence changes.
@property (nonatomic, strong) UIStackView *participantsList;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UILabel *> *participantLabels;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *participantInfo;

@property (nonatomic, assign) BOOL bootstrapped;
/// Launch environment (`JITSI_DEMO_*`) drives the same buttons, so the connect → join path
/// can be exercised from `simctl launch` without tapping.
@property (nonatomic, assign) BOOL autoJoinRequested;
@property (nonatomic, assign) BOOL didAutoJoin;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"JitsiMeetSDK · ObjC";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [JitsiSDK shared].delegate = self;

    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scrollView];

    UIStackView *root = [[UIStackView alloc] init];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    root.axis = UILayoutConstraintAxisVertical;
    root.spacing = 12;
    root.alignment = UIStackViewAlignmentFill;
    [scrollView addSubview:root];

    [NSLayoutConstraint activateConstraints:@[
        [scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [root.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor constant:16],
        [root.leadingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.trailingAnchor constant:-16],
        [root.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor constant:-24],
    ]];

    [root addArrangedSubview:[self sectionLabel:@"1. Connection"]];
    self.serviceURLField = [self fieldRowIn:root
                                        title:@"Service URL (wss/bosh)"
                                  placeholder:kDefaultServiceURL
                                         text:kDefaultServiceURL];
    self.serviceURLField.keyboardType = UIKeyboardTypeURL;
    self.serviceURLField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serviceURLField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.domainField = [self fieldRowIn:root
                                  title:@"XMPP domain"
                            placeholder:kDefaultDomain
                                   text:kDefaultDomain];
    self.domainField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.domainField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.mucField = [self fieldRowIn:root
                               title:@"MUC"
                         placeholder:kDefaultMuc
                                text:kDefaultMuc];
    self.mucField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.mucField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.tokenField = [self fieldRowIn:root
                                 title:@"JWT (optional)"
                           placeholder:@"required only by authenticated deployments"
                                  text:@""];
    self.tokenField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.tokenField.autocorrectionType = UITextAutocorrectionTypeNo;

    self.autoJoinSwitch = [self switchRowIn:root
                                      title:@"Auto-join after connect (skip prejoin step)"
                                   isOn:NO];

    self.connectButton = [self buttonRowIn:root
                                     title:@"Connect"
                                    action:@selector(connectTapped:)
                                 prominent:YES];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"Disconnected";
    [root addArrangedSubview:self.statusLabel];

    self.joinSection = [[UIStackView alloc] init];
    self.joinSection.axis = UILayoutConstraintAxisVertical;
    self.joinSection.spacing = 10;
    [root addArrangedSubview:self.joinSection];

    [self.joinSection addArrangedSubview:[self sectionLabel:@"2. Join the room"]];
    self.roomField = [self fieldRowIn:self.joinSection
                                title:@"Room"
                          placeholder:kDefaultRoom
                                 text:kDefaultRoom];
    self.roomField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.roomField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.displayNameField = [self fieldRowIn:self.joinSection
                                       title:@"Display name"
                                 placeholder:kDefaultDisplayName
                                        text:kDefaultDisplayName];
    self.passwordField = [self fieldRowIn:self.joinSection
                                    title:@"Room password (optional)"
                              placeholder:@"leave empty for open rooms"
                                     text:@""];
    self.passwordField.secureTextEntry = YES;

    UIStackView *mediaRow = [[UIStackView alloc] init];
    mediaRow.axis = UILayoutConstraintAxisHorizontal;
    mediaRow.spacing = 18;
    mediaRow.distribution = UIStackViewDistributionFillEqually;
    [self.joinSection addArrangedSubview:mediaRow];
    self.audioSwitch = [self switchIn:mediaRow title:@"Audio" isOn:YES];
    self.videoSwitch = [self switchIn:mediaRow title:@"Video" isOn:YES];

    UIStackView *joinButtons = [[UIStackView alloc] init];
    joinButtons.axis = UILayoutConstraintAxisHorizontal;
    joinButtons.spacing = 12;
    joinButtons.distribution = UIStackViewDistributionFillEqually;
    [self.joinSection addArrangedSubview:joinButtons];
    self.joinButton = [self buttonIn:joinButtons
                               title:@"Join"
                              action:@selector(joinTapped:)
                           prominent:YES];
    self.skipButton = [self buttonIn:joinButtons
                                title:@"Skip"
                               action:@selector(skipTapped:)
                            prominent:NO];

    self.roomSection = [[UIStackView alloc] init];
    self.roomSection.axis = UILayoutConstraintAxisVertical;
    self.roomSection.spacing = 10;
    [root addArrangedSubview:self.roomSection];

    [self.roomSection addArrangedSubview:[self sectionLabel:@"3. In the room"]];

    UIStackView *mediaButtons = [[UIStackView alloc] init];
    mediaButtons.axis = UILayoutConstraintAxisHorizontal;
    mediaButtons.spacing = 10;
    mediaButtons.distribution = UIStackViewDistributionFillEqually;
    [self.roomSection addArrangedSubview:mediaButtons];
    self.muteAudioButton = [self buttonIn:mediaButtons
                                    title:@"Mute mic"
                                   action:@selector(toggleAudioTapped:)
                                prominent:NO];
    self.muteVideoButton = [self buttonIn:mediaButtons
                                    title:@"Mute camera"
                                   action:@selector(toggleVideoTapped:)
                                prominent:NO];
    self.switchCameraButton = [self buttonIn:mediaButtons
                                       title:@"Flip camera"
                                      action:@selector(switchCameraTapped:)
                                   prominent:NO];

    UIStackView *roomButtons = [[UIStackView alloc] init];
    roomButtons.axis = UILayoutConstraintAxisHorizontal;
    roomButtons.spacing = 12;
    roomButtons.distribution = UIStackViewDistributionFillEqually;
    [self.roomSection addArrangedSubview:roomButtons];
    self.leaveButton = [self buttonIn:roomButtons
                                title:@"Leave"
                               action:@selector(leaveTapped:)
                            prominent:NO];
    self.disconnectButton = [self buttonIn:roomButtons
                                     title:@"Disconnect"
                                    action:@selector(disconnectTapped:)
                                 prominent:NO];

    [self.roomSection addArrangedSubview:[self sectionLabel:@"Participants"]];

    self.participantsList = [[UIStackView alloc] init];
    self.participantsList.axis = UILayoutConstraintAxisVertical;
    self.participantsList.spacing = 4;
    [self.roomSection addArrangedSubview:self.participantsList];
    self.participantLabels = [NSMutableDictionary dictionary];
    self.participantInfo = [NSMutableDictionary dictionary];

    [root addArrangedSubview:[self sectionLabel:@"Log"]];

    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.logView.heightAnchor constraintEqualToConstant:260].active = YES;
    [root addArrangedSubview:self.logView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];

    [self refreshUI];
    [self appendLog:@"Ready. Edit the server fields and tap Connect."];
    [self applyLaunchEnvironment];
}

- (void)applyLaunchEnvironment {
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    if (env[@"JITSI_DEMO_URL"].length > 0) { self.serviceURLField.text = env[@"JITSI_DEMO_URL"]; }
    if (env[@"JITSI_DEMO_DOMAIN"].length > 0) { self.domainField.text = env[@"JITSI_DEMO_DOMAIN"]; }
    if (env[@"JITSI_DEMO_MUC"].length > 0) { self.mucField.text = env[@"JITSI_DEMO_MUC"]; }
    if (env[@"JITSI_DEMO_TOKEN"].length > 0) { self.tokenField.text = env[@"JITSI_DEMO_TOKEN"]; }
    if (env[@"JITSI_DEMO_ROOM"].length > 0) { self.roomField.text = env[@"JITSI_DEMO_ROOM"]; }
    if (env[@"JITSI_DEMO_NAME"].length > 0) { self.displayNameField.text = env[@"JITSI_DEMO_NAME"]; }
    self.autoJoinRequested = [env[@"JITSI_DEMO_AUTO_JOIN"] isEqualToString:@"1"];
    if ([env[@"JITSI_DEMO_AUTO_CONNECT"] isEqualToString:@"1"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self connectTapped:nil]; });
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if ([JitsiSDK shared].delegate == self) {
        [JitsiSDK shared].delegate = nil;
    }
}

#pragma mark - Actions

- (void)connectTapped:(id)sender {
    [self.view endEditing:YES];

    NSString *serviceURL = [self normalizedServiceURL:[self trimmed:self.serviceURLField.text]];
    NSString *domain = [self trimmed:self.domainField.text];
    NSString *muc = [self trimmed:self.mucField.text];
    NSString *token = [self trimmed:self.tokenField.text];

    if (serviceURL.length == 0 || domain.length == 0 || muc.length == 0) {
        [self alert:@"Service URL, XMPP domain and MUC are required."];
        return;
    }

    self.connectButton.enabled = NO;
    self.statusLabel.text = @"Bootstrapping…";
    [self appendLog:[NSString stringWithFormat:@"bootstrap conferenceHost=%@", [self hostFromServiceURL:serviceURL]]];

    __weak typeof(self) weakSelf = self;
    [[JitsiSDK shared] bootstrapWithConferenceHost:[self hostFromServiceURL:serviceURL]
                                          logLevel:@"info"
                                    debugSignaling:NO
                                            region:@"chinaMainland"
                                        completion:^(NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (error) {
            [self reportFailure:@"bootstrap" error:error];
            return;
        }
        self.bootstrapped = YES;
        self.statusLabel.text = @"Connecting…";
        [self appendLog:[NSString stringWithFormat:@"connect serviceUrl=%@ domain=%@ muc=%@",
                         serviceURL, domain, muc]];

        [[JitsiSDK shared] connectWithServiceURL:serviceURL
                                          domain:domain
                                             muc:muc
                                           token:token.length > 0 ? token : nil
                                        username:nil
                                        password:nil
                                      completion:^(NSError *connectError) {
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) {
                return;
            }
            if (connectError) {
                [innerSelf reportFailure:@"connect" error:connectError];
                return;
            }
            [innerSelf appendLog:@"CONNECTED — cross-signaling is up"];
            [innerSelf refreshUI];
            if (innerSelf.autoJoinSwitch.isOn) {
                [innerSelf appendLog:@"Auto-join is on; joining without the prejoin step."];
                [innerSelf joinTapped:nil];
            }
        }];
    }];
}

- (void)joinTapped:(id)sender {
    [self.view endEditing:YES];

    JitsiSDK *sdk = [JitsiSDK shared];
    if (!sdk.isConnected) {
        [self alert:@"Connect to the server first."];
        return;
    }
    NSString *room = [self trimmed:self.roomField.text];
    NSString *name = [self trimmed:self.displayNameField.text];
    if (room.length == 0 || name.length == 0) {
        [self alert:@"Room and display name are required."];
        return;
    }
    NSString *password = [self trimmed:self.passwordField.text];

    self.joinButton.enabled = NO;
    self.statusLabel.text = @"Joining…";
    [self appendLog:[NSString stringWithFormat:@"joinRoom=%@ name=%@ audio=%@ video=%@",
                     room, name,
                     self.audioSwitch.isOn ? @"YES" : @"NO",
                     self.videoSwitch.isOn ? @"YES" : @"NO"]];

    __weak typeof(self) weakSelf = self;
    [sdk joinRoom:room
        displayName:name
              email:nil
          avatarURL:nil
           password:password.length > 0 ? password : nil
              audio:self.audioSwitch.isOn
              video:self.videoSwitch.isOn
         completion:^(NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        if (error) {
            [self reportFailure:@"joinRoom" error:error];
            if ([JitsiSDK shared].requiresPassword) {
                [self appendLog:@"This room needs a password; fill it in and tap Join again."];
            }
            return;
        }
        [self appendLog:@"JOINED — room is live"];
        [self refreshUI];
    }];
}

- (void)skipTapped:(id)sender {
    // Skipping keeps the XMPP connection open: the user can sit on this screen, check the
    // deployment, and join whenever they want (or never).
    [self appendLog:@"Join skipped — the connection stays open. Tap Join when ready."];
    self.statusLabel.text = @"Connected. Prejoin skipped; the room is not joined.";
    [self refreshUI];
}

- (void)toggleAudioTapped:(id)sender {
    JitsiSDK *sdk = [JitsiSDK shared];
    __weak typeof(self) weakSelf = self;
    [sdk setAudioMuted:!sdk.isAudioMuted completion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"setAudioMuted" error:error];
        } else {
            [weakSelf appendLog:[JitsiSDK shared].isAudioMuted ? @"Microphone muted" : @"Microphone live"];
            [weakSelf refreshUI];
        }
    }];
}

- (void)toggleVideoTapped:(id)sender {
    JitsiSDK *sdk = [JitsiSDK shared];
    __weak typeof(self) weakSelf = self;
    [sdk setVideoMuted:!sdk.isVideoMuted completion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"setVideoMuted" error:error];
        } else {
            [weakSelf appendLog:[JitsiSDK shared].isVideoMuted ? @"Camera muted" : @"Camera live"];
            [weakSelf refreshUI];
        }
    }];
}

- (void)switchCameraTapped:(id)sender {
    __weak typeof(self) weakSelf = self;
    [[JitsiSDK shared] switchCameraWithCompletion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"switchCamera" error:error];
        } else {
            [weakSelf appendLog:@"Camera flipped"];
        }
    }];
}

- (void)leaveTapped:(id)sender {
    [self appendLog:@"leave"];
    [[JitsiSDK shared] leave];
    [self refreshUI];
}

- (void)disconnectTapped:(id)sender {
    [self appendLog:@"disconnect"];
    [[JitsiSDK shared] disconnect];
    [self refreshUI];
}

#pragma mark - JitsiSDKDelegate

- (void)jitsiDidChangeState:(NSDictionary<NSString *,id> *)state {
    [self refreshUI];
    [self reloadParticipants:state];

    if (self.autoJoinRequested && !self.didAutoJoin
        && [state[@"isConnected"] boolValue]
        && ![state[@"isJoined"] boolValue]
        && ![state[@"isWaitingInLobby"] boolValue]
        && ![state[@"requiresPassword"] boolValue]) {
        self.didAutoJoin = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [self joinTapped:nil]; });
    }

    if ([state[@"isJoined"] boolValue]) {
        self.statusLabel.text = @"Joined";
    } else if ([state[@"isWaitingInLobby"] boolValue]) {
        self.statusLabel.text = [state[@"isWaitingForHost"] boolValue]
            ? @"Waiting in the lobby for the host to start the meeting…"
            : @"Waiting in the lobby for a moderator to admit you…";
    } else if ([state[@"requiresPassword"] boolValue]) {
        self.statusLabel.text = @"This room requires a password.";
    } else if ([state[@"isMediaInterrupted"] boolValue]) {
        self.statusLabel.text = @"Media path interrupted; reconnecting…";
    } else if ([state[@"isConnected"] boolValue]) {
        self.statusLabel.text = @"Connected. Ready to join.";
    } else {
        self.statusLabel.text = @"Disconnected";
    }

    NSString *lastError = state[@"lastError"];
    if (lastError.length > 0) {
        [self appendLog:[NSString stringWithFormat:@"state.lastError=%@", lastError]];
    }
}

- (void)jitsiDidReceiveEvent:(NSString *)name payload:(NSDictionary<NSString *,id> *)payload {
    // Audio levels and stats arrive at camera/audio rate; keep the log readable.
    if ([name isEqualToString:@"audioLevels"] || [name containsString:@"Stats"]) {
        return;
    }
    [self appendLog:[NSString stringWithFormat:@"event %@ %@", name, [self jsonString:payload]]];
}

/// Five updates a second per speaker. Only the affected row is touched, so the demo shows
/// jitsi-meet's speaking ring behaviour without rebuilding the list.
- (void)jitsiDidUpdateAudioLevels:(NSDictionary<NSString *,NSNumber *> *)levels {
    for (NSString *key in levels) {
        [self updateParticipant:key level:levels[key].doubleValue];
    }
}

#pragma mark - Participants

- (void)reloadParticipants:(NSDictionary<NSString *,id> *)state {
    JitsiSDK *sdk = [JitsiSDK shared];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];

    NSString *localName = self.displayNameField.text.length > 0
        ? self.displayNameField.text
        : @"You";
    [rows addObject:@{
        @"id": @"local",
        @"name": [NSString stringWithFormat:@"%@ (you)", localName],
        @"audioMuted": @(sdk.isAudioMuted),
        @"videoMuted": @(sdk.isVideoMuted)
    }];
    for (NSDictionary *participant in state[@"participants"]) {
        NSString *name = participant[@"displayName"];
        [rows addObject:@{
            @"id": participant[@"id"] ?: @"",
            @"name": name.length > 0 ? name : @"Guest",
            @"audioMuted": participant[@"isAudioMuted"] ?: @NO,
            @"videoMuted": participant[@"isVideoMuted"] ?: @NO
        }];
    }

    // Membership order is stable (the SDK sorts by id), so a full rebuild only happens on
    // joins, leaves and mute/profile changes, not on every level event.
    for (UIView *view in self.participantsList.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [self.participantLabels removeAllObjects];
    [self.participantInfo removeAllObjects];

    NSDictionary<NSString *, NSNumber *> *levels = sdk.audioLevels;
    for (NSDictionary *row in rows) {
        NSString *key = row[@"id"];
        if (key.length == 0) { continue; }
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
        label.numberOfLines = 1;
        [self.participantsList addArrangedSubview:label];
        self.participantLabels[key] = label;
        self.participantInfo[key] = row;
        [self updateParticipant:key level:levels[key].doubleValue];
    }
}

- (void)updateParticipant:(NSString *)key level:(double)level {
    NSDictionary *row = self.participantInfo[key];
    UILabel *label = self.participantLabels[key];
    if (!row || !label) { return; }

    BOOL audioMuted = [row[@"audioMuted"] boolValue];
    BOOL videoMuted = [row[@"videoMuted"] boolValue];
    BOOL speaking = !audioMuted && level >= 0.05;

    NSMutableString *meter = [NSMutableString string];
    for (int index = 0; index < 4; index++) {
        [meter appendString:level >= (index + 1) / 4.0 ? @"●" : @"○"];
    }

    label.text = [NSString stringWithFormat:@"%@   %@ %@   %@%@",
                  row[@"name"],
                  audioMuted ? @"mic off" : @"mic",
                  audioMuted ? @"" : meter,
                  videoMuted ? @"cam off" : @"cam on",
                  speaking ? @"   speaking" : @""];
    label.textColor = speaking ? [UIColor systemGreenColor] : [UIColor labelColor];
}

#pragma mark - UI

- (void)refreshUI {
    JitsiSDK *sdk = [JitsiSDK shared];

    BOOL connected = sdk.isConnected;
    BOOL joined = sdk.isJoined;

    self.connectButton.enabled = !connected;
    self.joinButton.enabled = connected && !joined;
    self.skipButton.enabled = connected && !joined;
    self.leaveButton.enabled = joined;
    self.disconnectButton.enabled = connected && !joined;

    self.muteAudioButton.enabled = joined;
    self.muteVideoButton.enabled = joined;
    self.switchCameraButton.enabled = joined;

    self.joinSection.hidden = !connected || joined;
    self.roomSection.hidden = !joined;

    [self.muteAudioButton setTitle:sdk.isAudioMuted ? @"Unmute mic" : @"Mute mic"
                          forState:UIControlStateNormal];
    [self.muteVideoButton setTitle:sdk.isVideoMuted ? @"Start camera" : @"Mute camera"
                          forState:UIControlStateNormal];

    self.serviceURLField.enabled = !connected;
    self.domainField.enabled = !connected;
    self.mucField.enabled = !connected;
    self.tokenField.enabled = !connected;
}

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    return label;
}

- (UITextField *)fieldRowIn:(UIStackView *)stack
                      title:(NSString *)title
                placeholder:(NSString *)placeholder
                       text:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    label.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:label];

    UITextField *field = [[UITextField alloc] init];
    field.text = text;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyNext;
    field.delegate = self;
    [field.heightAnchor constraintEqualToConstant:38].active = YES;
    [stack addArrangedSubview:field];
    return field;
}

- (UISwitch *)switchRowIn:(UIStackView *)stack title:(NSString *)title isOn:(BOOL)isOn {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.numberOfLines = 0;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = isOn;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 12;
    [stack addArrangedSubview:row];
    return toggle;
}

- (UISwitch *)switchIn:(UIStackView *)stack title:(NSString *)title isOn:(BOOL)isOn {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = isOn;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    [stack addArrangedSubview:row];
    return toggle;
}

- (UIButton *)buttonRowIn:(UIStackView *)stack
                    title:(NSString *)title
                   action:(SEL)action
                prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    if (prominent) {
        button.backgroundColor = [UIColor systemBlueColor];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 10;
    } else {
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor systemBlueColor].CGColor;
        button.layer.cornerRadius = 10;
    }
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [stack addArrangedSubview:button];
    return button;
}

- (UIButton *)buttonIn:(UIStackView *)stack
                 title:(NSString *)title
                action:(SEL)action
             prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    if (prominent) {
        button.backgroundColor = [UIColor systemBlueColor];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 8;
    } else {
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor systemBlueColor].CGColor;
        button.layer.cornerRadius = 8;
    }
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [stack addArrangedSubview:button];
    return button;
}

#pragma mark - Helpers

- (void)reportFailure:(NSString *)operation error:(NSError *)error {
    NSString *message = [NSString stringWithFormat:@"%@ failed: %@", operation, error.localizedDescription];
    [self appendLog:message];
    self.statusLabel.text = message;
    [self refreshUI];
}

- (void)appendLog:(NSString *)line {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];

    NSMutableArray<NSString *> *lines =
        [[self.logView.text componentsSeparatedByString:@"\n"] mutableCopy] ?: [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"%@ %@", stamp, line]];
    if (lines.count > kMaxLogLines) {
        [lines removeObjectsInRange:NSMakeRange(0, lines.count - kMaxLogLines)];
    }
    self.logView.text = [lines componentsJoinedByString:@"\n"];

    NSRange end = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:end];
}

- (void)alert:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:nil
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)trimmed:(NSString *)value {
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
}

- (NSString *)normalizedServiceURL:(NSString *)input {
    if (input.length == 0) {
        return input;
    }
    if ([input rangeOfString:@"://"].location != NSNotFound) {
        return input;
    }
    return [@"wss://" stringByAppendingString:input];
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

- (NSString *)jsonString:(NSDictionary<NSString *,id> *)payload {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload ?: @{} options:0 error:&error];
    if (!data || error) {
        return [payload description];
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{}";
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - App lifecycle

- (void)appDidBecomeActive {
    [[JitsiSDK shared] setAppActive:YES];
}

- (void)appDidEnterBackground {
    [[JitsiSDK shared] setAppActive:NO];
}

@end
