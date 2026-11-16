#import "ViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <JitsiMeetSDK/JitsiMeetSDK.h>

// Self-hosted deployment used by this workspace. Every field is editable, and nothing falls
// back to a public service: clearing the URL simply refuses to connect. The public endpoints
// live on :8443 while Prosody answers as `meet.jitsi` and hosts MUC at `muc.meet.jitsi`
// (see the deployment's config.js).
static NSString *const kDefaultServiceURL = @"wss://tmeeting.maesgroup.com:8443/xmpp-websocket";
static NSString *const kDefaultDomain = @"meet.jitsi";
static NSString *const kDefaultMuc = @"muc.meet.jitsi";
static NSString *const kDefaultRoom = @"2115362625856700417";
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

#pragma mark - Participants sheet

/// Read-only roster: one row per endpoint, green while that endpoint speaks. Mute state comes
/// from presence, so a remote row reflects what the room sees, not just local intent.
@interface PeopleSheetViewController : UIViewController
- (void)reloadWithSDK:(JitsiSDK *)sdk localName:(NSString *)localName;
- (void)updateLevels:(NSDictionary<NSString *, NSNumber *> *)levels;
@end

@implementation PeopleSheetViewController {
    UILabel *_titleLabel;
    UIStackView *_stack;
    NSMutableDictionary<NSString *, UILabel *> *_labels;
    NSArray<NSDictionary *> *_rows;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"Participants";
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_titleLabel];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [done addTarget:self action:@selector(doneTapped:) forControlEvents:UIControlEventTouchUpInside];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:done];

    UILabel *hint = [[UILabel alloc] init];
    hint.text = @"Mic and camera reflect what the room sees; a row turns green for the active speaker.";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = [UIColor secondaryLabelColor];
    hint.numberOfLines = 0;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:hint];

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    _stack = [[UIStackView alloc] init];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 12;
    _stack.alignment = UIStackViewAlignmentFill;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:_stack];

    _labels = [NSMutableDictionary dictionary];
    _rows = @[];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [done.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:8],

        [hint.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
        [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [_stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [_stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
        [_stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
    ]];
}

- (void)doneTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reloadWithSDK:(JitsiSDK *)sdk localName:(NSString *)localName {
    [self loadViewIfNeeded];
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSDictionary<NSString *, NSNumber *> *levels = sdk.audioLevels;

    [rows addObject:@{
        @"key": @"local",
        @"name": [NSString stringWithFormat:@"%@ (you)", localName],
        @"audioMuted": @(sdk.isAudioMuted),
        @"videoMuted": @(sdk.isVideoMuted),
        @"level": levels[@"local"] ?: @0
    }];
    for (NSDictionary *participant in [sdk participants]) {
        NSString *identifier = participant[@"id"];
        if (identifier.length == 0) { continue; }
        NSString *name = participant[@"displayName"];
        [rows addObject:@{
            @"key": identifier,
            @"name": name.length > 0 ? name : @"Guest",
            @"audioMuted": participant[@"isAudioMuted"] ?: @NO,
            @"videoMuted": participant[@"isVideoMuted"] ?: @NO,
            @"level": levels[identifier] ?: @0
        }];
    }

    for (UIView *view in _stack.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_labels removeAllObjects];
    _rows = rows;
    _titleLabel.text = [NSString stringWithFormat:@"Participants · %lu", (unsigned long)rows.count];

    for (NSDictionary *row in rows) {
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        label.numberOfLines = 0;
        [_stack addArrangedSubview:label];
        _labels[row[@"key"]] = label;
        [self renderRow:row level:[row[@"level"] doubleValue]];
    }
}

- (void)updateLevels:(NSDictionary<NSString *, NSNumber *> *)levels {
    if (!self.isViewLoaded) { return; }
    for (NSDictionary *row in _rows) {
        UILabel *label = _labels[row[@"key"]];
        if (!label) { continue; }
        [self renderRow:row level:levels[row[@"key"]].doubleValue];
    }
}

- (void)renderRow:(NSDictionary *)row level:(double)level {
    UILabel *label = _labels[row[@"key"]];
    if (!label) { return; }
    BOOL audioMuted = [row[@"audioMuted"] boolValue];
    BOOL videoMuted = [row[@"videoMuted"] boolValue];
    BOOL speaking = !audioMuted && level >= 0.05;
    label.text = [NSString stringWithFormat:@"%@   mic %@ · cam %@",
                  row[@"name"],
                  audioMuted ? @"off" : @"on",
                  videoMuted ? @"off" : @"on"];
    label.textColor = speaking ? [UIColor systemGreenColor] : [UIColor labelColor];
}

@end

#pragma mark - Log sheet

/// The same bounded log the configuration screen shows, readable without leaving the room.
@interface LogSheetViewController : UIViewController
- (void)setLogText:(NSString *)text;
@end

@implementation LogSheetViewController {
    UITextView *_textView;
    NSString *_pendingText;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Session log";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [done addTarget:self action:@selector(doneTapped:) forControlEvents:UIControlEventTouchUpInside];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:done];

    _textView = [[UITextView alloc] init];
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    _textView.layer.cornerRadius = 8;
    _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_textView];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [done.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [done.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],

        [_textView.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [_textView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];

    _textView.text = _pendingText ?: @"";
    [self scrollLogToEnd];
}

- (void)doneTapped:(id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)setLogText:(NSString *)text {
    _pendingText = [text copy];
    if (!self.isViewLoaded) { return; }
    _textView.text = text ?: @"";
    [self scrollLogToEnd];
}

- (void)scrollLogToEnd {
    if (_textView.text.length == 0) { return; }
    NSRange end = NSMakeRange(_textView.text.length, 0);
    [_textView scrollRangeToVisible:end];
}

@end

#pragma mark - Demo controller

@interface ViewController () <JitsiSDKDelegate, UITextFieldDelegate>

// Configuration screen
@property (nonatomic, strong) UIScrollView *configScrollView;
@property (nonatomic, strong) UITextField *serviceURLField;
@property (nonatomic, strong) UITextField *domainField;
@property (nonatomic, strong) UITextField *mucField;
@property (nonatomic, strong) UITextField *tokenField;
@property (nonatomic, strong) UITextField *roomField;
@property (nonatomic, strong) UITextField *displayNameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UISegmentedControl *transportControl;
@property (nonatomic, strong) UISwitch *autoJoinSwitch;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIButton *previewJoinButton;
@property (nonatomic, strong) UIButton *disconnectButton;
@property (nonatomic, strong) UIStackView *connectedButtonsRow;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logView;

// Prejoin screen: full-screen self-view with the join controls, no configuration chrome.
@property (nonatomic, strong) UIView *prejoinView;
@property (nonatomic, strong) UIButton *prejoinBackButton;
@property (nonatomic, strong) UILabel *prejoinRoomLabel;
@property (nonatomic, strong) UILabel *prejoinNameLabel;
@property (nonatomic, strong) UILabel *prejoinHintLabel;
@property (nonatomic, strong) UIView *prejoinCanvasHost;
@property (nonatomic, strong) UIStackView *prejoinControls;
@property (nonatomic, strong) UIButton *prejoinMicButton;
@property (nonatomic, strong) UILabel *prejoinMicCaption;
@property (nonatomic, strong) UIButton *prejoinCameraButton;
@property (nonatomic, strong) UILabel *prejoinCameraCaption;
@property (nonatomic, strong) UIButton *prejoinFlipButton;
@property (nonatomic, strong) UILabel *prejoinFlipCaption;
@property (nonatomic, strong) UIButton *prejoinJoinButton;

// Meeting screen: gallery grid between a top bar and the control bar.
@property (nonatomic, strong) UIView *meetingView;
@property (nonatomic, strong) UILabel *meetingRoomLabel;
@property (nonatomic, strong) UILabel *meetingSubtitleLabel;
@property (nonatomic, strong) UILabel *meetingTimerLabel;
@property (nonatomic, strong) UIView *gridContainer;
@property (nonatomic, strong) UIButton *meetingLogsButton;
@property (nonatomic, strong) UIButton *meetingPeopleButton;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UILabel *micCaption;
@property (nonatomic, strong) UIButton *cameraButton;
@property (nonatomic, strong) UILabel *cameraCaption;
@property (nonatomic, strong) UIButton *flipButton;
@property (nonatomic, strong) UILabel *flipCaption;
@property (nonatomic, strong) UIButton *routeButton;
@property (nonatomic, strong) UILabel *routeCaption;
@property (nonatomic, strong) UIButton *leaveButton;
@property (nonatomic, strong) NSTimer *meetingTimer;

// Gallery tiles: `tileOrder` drives placement, the local tile host is created once.
@property (nonatomic, strong) UIView *localTileHost;
@property (nonatomic, strong) NSMutableArray<NSString *> *tileOrder;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *tileHosts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIView *> *tileViews;
@property (nonatomic, strong) UIView *localCanvasView;

// Prepared-room bookkeeping.
@property (nonatomic, copy) NSString *preparedRoom;
@property (nonatomic, copy) NSString *preparedName;
@property (nonatomic, assign) BOOL isPreviewPrepared;
/// True while permissions/prepare are in flight, so Join cannot start a second preview.
@property (nonatomic, assign) BOOL previewPreparing;
/// Set when Join was tapped before the preview existed; the prepare completion joins then.
@property (nonatomic, assign) BOOL joinAfterPreview;
@property (nonatomic, assign) BOOL wantAudioOn;
@property (nonatomic, assign) BOOL wantVideoOn;

@property (nonatomic, strong) PeopleSheetViewController *peopleSheet;
@property (nonatomic, strong) LogSheetViewController *logSheet;

@property (nonatomic, assign) BOOL bootstrapped;
/// Launch environment (`JITSI_DEMO_*`) drives the same buttons, so the connect → join path
/// can be exercised from `simctl launch` without tapping.
@property (nonatomic, assign) BOOL autoJoinRequested;
@property (nonatomic, assign) BOOL didAutoJoin;
@property (nonatomic, assign) BOOL unmuteAfterJoin;
@property (nonatomic, assign) BOOL didUnmuteAfterJoin;
/// `JITSI_DEMO_AUDIO_ROUTE=receiver|speaker` requests that built-in route after joining.
@property (nonatomic, copy) NSString *audioRouteAfterJoin;
@property (nonatomic, assign) BOOL didApplyAudioRoute;
/// `JITSI_DEMO_SHEET=people|logs` opens that sheet after joining, so captures do not need taps.
@property (nonatomic, copy) NSString *sheetAfterJoin;
@property (nonatomic, assign) BOOL didOpenSheet;
/// `JITSI_DEMO_AUTO_LEAVE=1` taps Leave shortly after joining to capture the return path.
@property (nonatomic, assign) BOOL autoLeaveAfterJoin;
@property (nonatomic, assign) BOOL didAutoLeave;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"JitsiMeetSDK · ObjC";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [JitsiSDK shared].delegate = self;
    // `fit` letterboxes inside every 16:9 tile: whole frame, no crop, no stretch.
    JitsiSDK *sdk = [JitsiSDK shared];
    sdk.defaultCanvasStyle.fillMode = @"fit";
    sdk.defaultCanvasStyle.nameFontSize = 12;
    // The self-view gets its own look; remote tiles keep the default style.
    JitsiCanvasStyle *localStyle = [JitsiCanvasStyle defaultStyle];
    localStyle.fillMode = @"fit";
    localStyle.avatarSize = 72;
    localStyle.avatarPosition = @"topTrailing";
    localStyle.nameFontSize = 15;
    [sdk setCanvasStyle:localStyle forParticipant:@"local"];

    self.wantAudioOn = YES;
    self.wantVideoOn = YES;
    self.tileOrder = [NSMutableArray array];
    self.tileHosts = [NSMutableDictionary dictionary];
    self.tileViews = [NSMutableDictionary dictionary];

    [self buildConfigurationScreen];
    [self buildPrejoinScreen];
    [self buildMeetingScreen];

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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutVideoGrid];
}

- (void)applyLaunchEnvironment {
    NSDictionary<NSString *, NSString *> *env = NSProcessInfo.processInfo.environment;
    if (env[@"JITSI_DEMO_URL"].length > 0) { self.serviceURLField.text = env[@"JITSI_DEMO_URL"]; }
    if (env[@"JITSI_DEMO_DOMAIN"].length > 0) { self.domainField.text = env[@"JITSI_DEMO_DOMAIN"]; }
    if (env[@"JITSI_DEMO_MUC"].length > 0) { self.mucField.text = env[@"JITSI_DEMO_MUC"]; }
    if (env[@"JITSI_DEMO_TOKEN"].length > 0) { self.tokenField.text = env[@"JITSI_DEMO_TOKEN"]; }
    if (env[@"JITSI_DEMO_TRANSPORT"].length > 0) {
        NSInteger index = [self transportIndexForValue:env[@"JITSI_DEMO_TRANSPORT"]];
        if (index != NSNotFound) {
            self.transportControl.selectedSegmentIndex = index;
        }
    }
    if (env[@"JITSI_DEMO_ROOM"].length > 0) { self.roomField.text = env[@"JITSI_DEMO_ROOM"]; }
    if (env[@"JITSI_DEMO_NAME"].length > 0) { self.displayNameField.text = env[@"JITSI_DEMO_NAME"]; }
    if (env[@"JITSI_DEMO_AUDIO"] != nil) {
        self.wantAudioOn = [env[@"JITSI_DEMO_AUDIO"] isEqualToString:@"1"];
    }
    if (env[@"JITSI_DEMO_VIDEO"] != nil) {
        self.wantVideoOn = [env[@"JITSI_DEMO_VIDEO"] isEqualToString:@"1"];
    }
    self.autoJoinRequested = [env[@"JITSI_DEMO_AUTO_JOIN"] isEqualToString:@"1"];
    self.unmuteAfterJoin = [env[@"JITSI_DEMO_UNMUTE_AFTER_JOIN"] isEqualToString:@"1"];
    if (env[@"JITSI_DEMO_AUDIO_ROUTE"].length > 0) {
        self.audioRouteAfterJoin = env[@"JITSI_DEMO_AUDIO_ROUTE"];
    }
    if (env[@"JITSI_DEMO_SHEET"].length > 0) {
        self.sheetAfterJoin = env[@"JITSI_DEMO_SHEET"];
    }
    self.autoLeaveAfterJoin = [env[@"JITSI_DEMO_AUTO_LEAVE"] isEqualToString:@"1"];
    if ([env[@"JITSI_DEMO_AUTO_CONNECT"] isEqualToString:@"1"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self connectTapped:nil]; });
    }
}

#pragma mark - Configuration screen

- (void)buildConfigurationScreen {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scrollView];
    self.configScrollView = scrollView;

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

    self.transportControl = [self segmentedRowIn:root
                                           title:@"Transport"
                                           items:@[@"Auto (race both)", @"BOSH", @"WebSocket"]];

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

    [root addArrangedSubview:[self sectionLabel:@"2. Room"]];
    self.roomField = [self fieldRowIn:root
                                title:@"Room"
                          placeholder:kDefaultRoom
                                 text:kDefaultRoom];
    self.roomField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.roomField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.displayNameField = [self fieldRowIn:root
                                       title:@"Display name"
                                 placeholder:kDefaultDisplayName
                                        text:kDefaultDisplayName];
    self.passwordField = [self fieldRowIn:root
                                    title:@"Room password (optional)"
                              placeholder:@"leave empty for open rooms"
                                     text:@""];
    self.passwordField.secureTextEntry = YES;

    self.autoJoinSwitch = [self switchRowIn:root
                                      title:@"Auto-join after the preview is ready"
                                       isOn:NO];

    self.previewJoinButton = [self buttonRowIn:root
                                         title:@"Preview & join"
                                        action:@selector(joinTapped:)
                                     prominent:YES];

    self.connectedButtonsRow = [[UIStackView alloc] init];
    self.connectedButtonsRow.axis = UILayoutConstraintAxisHorizontal;
    self.connectedButtonsRow.spacing = 12;
    self.connectedButtonsRow.distribution = UIStackViewDistributionFillEqually;
    self.connectedButtonsRow.hidden = YES;
    [root addArrangedSubview:self.connectedButtonsRow];
    self.disconnectButton = [self buttonIn:self.connectedButtonsRow
                                     title:@"Disconnect"
                                    action:@selector(disconnectTapped:)
                                 prominent:NO];

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
}

#pragma mark - Prejoin screen

- (void)buildPrejoinScreen {
    UIView *prejoin = [[UIView alloc] init];
    prejoin.backgroundColor = [UIColor blackColor];
    prejoin.translatesAutoresizingMaskIntoConstraints = NO;
    prejoin.hidden = YES;
    [self.view addSubview:prejoin];
    self.prejoinView = prejoin;

    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    [back setImage:SymbolImage(@"chevron.left") forState:UIControlStateNormal];
    back.tintColor = [UIColor whiteColor];
    back.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    back.layer.cornerRadius = 20;
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back addTarget:self action:@selector(prejoinBackTapped:) forControlEvents:UIControlEventTouchUpInside];
    [prejoin addSubview:back];
    self.prejoinBackButton = back;

    UILabel *room = [[UILabel alloc] init];
    room.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    room.textColor = [UIColor whiteColor];
    room.textAlignment = NSTextAlignmentCenter;
    room.lineBreakMode = NSLineBreakByTruncatingTail;
    room.translatesAutoresizingMaskIntoConstraints = NO;
    [prejoin addSubview:room];
    self.prejoinRoomLabel = room;

    UILabel *name = [[UILabel alloc] init];
    name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    name.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    name.textAlignment = NSTextAlignmentCenter;
    name.translatesAutoresizingMaskIntoConstraints = NO;
    [prejoin addSubview:name];
    self.prejoinNameLabel = name;

    UIView *canvasHost = [self canvasHostView];
    // The self-view is black on a camera-less simulator, so outline the 16:9 box.
    canvasHost.layer.borderWidth = 1;
    canvasHost.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    [prejoin addSubview:canvasHost];
    self.prejoinCanvasHost = canvasHost;

    UILabel *hint = [[UILabel alloc] init];
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    hint.numberOfLines = 0;
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [prejoin addSubview:hint];
    self.prejoinHintLabel = hint;

    self.prejoinMicButton = [self circularButtonWithImage:@"mic.fill"
                                                   action:@selector(toggleAudioTapped:)];
    UILabel *micCaption = [self captionLabel:@"Mute"];
    self.prejoinMicCaption = micCaption;
    self.prejoinCameraButton = [self circularButtonWithImage:@"video.fill"
                                                      action:@selector(toggleVideoTapped:)];
    UILabel *cameraCaption = [self captionLabel:@"Camera"];
    self.prejoinCameraCaption = cameraCaption;
    self.prejoinFlipButton = [self circularButtonWithImage:@"arrow.triangle.2.circlepath"
                                                    action:@selector(switchCameraTapped:)];
    UILabel *flipCaption = [self captionLabel:@"Flip"];
    self.prejoinFlipCaption = flipCaption;

    self.prejoinControls = [self controlRowWithItems:@[
        [self controlItemWithButton:self.prejoinMicButton caption:micCaption],
        [self controlItemWithButton:self.prejoinCameraButton caption:cameraCaption],
        [self controlItemWithButton:self.prejoinFlipButton caption:flipCaption],
    ]];
    [prejoin addSubview:self.prejoinControls];

    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    [join setTitle:@"Join now" forState:UIControlStateNormal];
    join.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [join setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    join.backgroundColor = [UIColor systemGreenColor];
    join.layer.cornerRadius = 26;
    join.translatesAutoresizingMaskIntoConstraints = NO;
    [join addTarget:self action:@selector(joinTapped:) forControlEvents:UIControlEventTouchUpInside];
    [prejoin addSubview:join];
    self.prejoinJoinButton = join;

    UILayoutGuide *safe = prejoin.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [prejoin.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [prejoin.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [prejoin.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [prejoin.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [back.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [back.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [back.widthAnchor constraintEqualToConstant:40],
        [back.heightAnchor constraintEqualToConstant:40],

        [room.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [room.centerXAnchor constraintEqualToAnchor:prejoin.centerXAnchor],
        [room.leadingAnchor constraintGreaterThanOrEqualToAnchor:back.trailingAnchor constant:8],
        [room.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],

        [name.topAnchor constraintEqualToAnchor:room.bottomAnchor constant:4],
        [name.centerXAnchor constraintEqualToAnchor:prejoin.centerXAnchor],
        [name.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-16],

        [canvasHost.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:22],
        [canvasHost.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [canvasHost.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [hint.topAnchor constraintEqualToAnchor:canvasHost.bottomAnchor constant:14],
        [hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [self.prejoinControls.centerXAnchor constraintEqualToAnchor:prejoin.centerXAnchor],
        [self.prejoinControls.topAnchor constraintGreaterThanOrEqualToAnchor:hint.bottomAnchor constant:12],
        [self.prejoinControls.bottomAnchor constraintEqualToAnchor:join.topAnchor constant:-20],

        [join.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [join.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [join.heightAnchor constraintEqualToConstant:52],
        [join.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Meeting screen

- (void)buildMeetingScreen {
    UIView *meeting = [[UIView alloc] init];
    meeting.backgroundColor = [UIColor blackColor];
    meeting.translatesAutoresizingMaskIntoConstraints = NO;
    meeting.hidden = YES;
    [self.view addSubview:meeting];
    self.meetingView = meeting;

    UILabel *roomLabel = [[UILabel alloc] init];
    roomLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    roomLabel.textColor = [UIColor whiteColor];
    roomLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.meetingRoomLabel = roomLabel;

    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.meetingSubtitleLabel = subtitle;

    UIStackView *leading = [[UIStackView alloc] initWithArrangedSubviews:@[roomLabel, subtitle]];
    leading.axis = UILayoutConstraintAxisVertical;
    leading.spacing = 2;
    leading.alignment = UIStackViewAlignmentLeading;

    UILabel *timer = [[UILabel alloc] init];
    timer.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    timer.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    timer.textAlignment = NSTextAlignmentRight;
    [timer setContentCompressionResistancePriority:UILayoutPriorityRequired
                                           forAxis:UILayoutConstraintAxisHorizontal];
    self.meetingTimerLabel = timer;

    UIButton *logs = [self chromeButtonWithImage:@"doc.text.fill" action:@selector(logsTapped:)];
    self.meetingLogsButton = logs;
    UIButton *people = [self chromeButtonWithImage:@"person.2.fill" action:@selector(peopleTapped:)];
    self.meetingPeopleButton = people;

    UIStackView *trailing = [[UIStackView alloc] initWithArrangedSubviews:@[timer, logs, people]];
    trailing.axis = UILayoutConstraintAxisHorizontal;
    trailing.spacing = 8;
    trailing.alignment = UIStackViewAlignmentCenter;

    UIStackView *topBar = [[UIStackView alloc] initWithArrangedSubviews:@[leading, trailing]];
    topBar.axis = UILayoutConstraintAxisHorizontal;
    topBar.alignment = UIStackViewAlignmentCenter;
    topBar.spacing = 12;
    topBar.translatesAutoresizingMaskIntoConstraints = NO;
    [meeting addSubview:topBar];

    UIView *grid = [[UIView alloc] init];
    grid.backgroundColor = [UIColor blackColor];
    grid.clipsToBounds = YES;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [meeting addSubview:grid];
    self.gridContainer = grid;

    UIView *localTile = [[UIView alloc] init];
    localTile.backgroundColor = [UIColor blackColor];
    localTile.layer.cornerRadius = 10;
    localTile.layer.borderWidth = 1;
    localTile.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    localTile.clipsToBounds = YES;
    [grid addSubview:localTile];
    self.localTileHost = localTile;

    self.micButton = [self circularButtonWithImage:@"mic.fill" action:@selector(toggleAudioTapped:)];
    self.micCaption = [self captionLabel:@"Mute"];
    self.cameraButton = [self circularButtonWithImage:@"video.fill" action:@selector(toggleVideoTapped:)];
    self.cameraCaption = [self captionLabel:@"Camera"];
    self.flipButton = [self circularButtonWithImage:@"arrow.triangle.2.circlepath"
                                             action:@selector(switchCameraTapped:)];
    self.flipCaption = [self captionLabel:@"Flip"];
    self.routeButton = [self circularButtonWithImage:@"speaker.wave.2.fill"
                                              action:@selector(toggleAudioRouteTapped:)];
    self.routeCaption = [self captionLabel:@"Audio"];
    self.leaveButton = [self circularButtonWithImage:@"phone.down.fill" action:@selector(leaveTapped:)];
    self.leaveButton.backgroundColor = [UIColor systemRedColor];
    self.leaveButton.tintColor = [UIColor whiteColor];
    UILabel *leaveCaption = [self captionLabel:@"Leave"];

    UIStackView *controls = [self controlRowWithItems:@[
        [self controlItemWithButton:self.micButton caption:self.micCaption],
        [self controlItemWithButton:self.cameraButton caption:self.cameraCaption],
        [self controlItemWithButton:self.flipButton caption:self.flipCaption],
        [self controlItemWithButton:self.routeButton caption:self.routeCaption],
        [self controlItemWithButton:self.leaveButton caption:leaveCaption],
    ]];
    controls.distribution = UIStackViewDistributionFillEqually;
    [meeting addSubview:controls];

    UILayoutGuide *safe = meeting.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [meeting.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [meeting.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [meeting.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [meeting.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [topBar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [topBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [topBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [topBar.heightAnchor constraintEqualToConstant:52],

        [grid.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:4],
        [grid.leadingAnchor constraintEqualToAnchor:meeting.leadingAnchor constant:8],
        [grid.trailingAnchor constraintEqualToAnchor:meeting.trailingAnchor constant:-8],
        [grid.bottomAnchor constraintEqualToAnchor:controls.topAnchor constant:-8],

        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6],
        [controls.heightAnchor constraintEqualToConstant:76],
    ]];
}

#pragma mark - UI building blocks

- (UIView *)canvasHostView {
    UIView *host = [[UIView alloc] init];
    host.backgroundColor = [UIColor blackColor];
    host.clipsToBounds = YES;
    host.layer.cornerRadius = 12;
    host.translatesAutoresizingMaskIntoConstraints = NO;
    [[host.heightAnchor constraintEqualToAnchor:host.widthAnchor multiplier:9.0 / 16.0] setActive:YES];
    return host;
}

- (UIButton *)circularButtonWithImage:(NSString *)image action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:SymbolImage(image) forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    button.layer.cornerRadius = 26;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:52].active = YES;
    [button.heightAnchor constraintEqualToConstant:52].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIButton *)chromeButtonWithImage:(NSString *)image action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:SymbolImage(image) forState:UIControlStateNormal];
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    button.layer.cornerRadius = 18;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:36].active = YES;
    [button.heightAnchor constraintEqualToConstant:36].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UILabel *)captionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    label.textAlignment = NSTextAlignmentCenter;
    return label;
}

- (UIStackView *)controlItemWithButton:(UIButton *)button caption:(UILabel *)caption {
    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[button, caption]];
    item.axis = UILayoutConstraintAxisVertical;
    item.alignment = UIStackViewAlignmentCenter;
    item.spacing = 6;
    return item;
}

- (UIStackView *)controlRowWithItems:(NSArray<UIView *> *)items {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:items];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentTop;
    row.spacing = 24;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

#pragma mark - Gallery

/// Pins a canvas view to a tile. Removing the view later releases these constraints with
/// it, so the local canvas moves between the prejoin and meeting hosts as one view.
- (void)attachCanvasView:(UIView *)canvasView toHost:(UIView *)host {
    if (!canvasView || !host) { return; }
    if (canvasView.superview == host) { return; }
    [canvasView removeFromSuperview];
    canvasView.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:canvasView];
    [NSLayoutConstraint activateConstraints:@[
        [canvasView.topAnchor constraintEqualToAnchor:host.topAnchor],
        [canvasView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [canvasView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [canvasView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
}

- (void)attachLocalCanvasToHost:(UIView *)host {
    UIView *canvasView = [JitsiSDK shared].localCanvasView;
    if (!canvasView || !host) { return; }
    self.localCanvasView = canvasView;
    [self attachCanvasView:canvasView toHost:host];
}

- (void)detachLocalCanvas {
    [self.localCanvasView removeFromSuperview];
    self.localCanvasView = nil;
}

- (void)addRemoteTile:(UIView *)canvasView participantID:(NSString *)participantID {
    if (!canvasView || participantID.length == 0) { return; }
    // A rejoin redelivers a canvas without a matching leave; drop the stale tile first.
    [self removeRemoteTile:participantID];

    UIView *host = [[UIView alloc] init];
    host.backgroundColor = [UIColor blackColor];
    host.layer.cornerRadius = 10;
    host.layer.borderWidth = 1;
    host.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    host.clipsToBounds = YES;
    [self.gridContainer addSubview:host];
    [self attachCanvasView:canvasView toHost:host];

    self.tileHosts[participantID] = host;
    self.tileViews[participantID] = canvasView;
    if (![self.tileOrder containsObject:participantID]) {
        [self.tileOrder addObject:participantID];
    }
    [self layoutVideoGrid];
}

- (void)removeRemoteTile:(NSString *)participantID {
    UIView *host = self.tileHosts[participantID];
    if (!host) { return; }
    [self.tileViews[participantID] removeFromSuperview];
    [host removeFromSuperview];
    [self.tileHosts removeObjectForKey:participantID];
    [self.tileViews removeObjectForKey:participantID];
    [self.tileOrder removeObject:participantID];
    [self layoutVideoGrid];
}

- (void)resetTiles {
    for (NSString *participantID in [self.tileHosts.allKeys copy]) {
        [self removeRemoteTile:participantID];
    }
    [self.tileOrder removeAllObjects];
    [self detachLocalCanvas];
}

/// Fewest columns of 16:9 tiles that fit, rows centred. The tile is 16:9 and the canvas
/// renders with `.fit`, so the picture is never stretched or cropped.
- (void)layoutVideoGrid {
    if (self.meetingView.hidden) { return; }
    NSArray<NSString *> *identifiers = [self.tileOrder copy];
    NSUInteger count = identifiers.count;
    CGRect bounds = self.gridContainer.bounds;
    if (count == 0 || bounds.size.width <= 0 || bounds.size.height <= 0) { return; }

    CGFloat inset = 2;
    CGFloat availableWidth = bounds.size.width - 2 * inset;
    CGFloat availableHeight = bounds.size.height - 2 * inset;

    NSUInteger columns = count;
    CGFloat tileWidth = 0;
    for (NSUInteger candidate = 1; candidate <= count; candidate++) {
        CGFloat width = (availableWidth - (candidate - 1) * kTileGap) / candidate;
        if (width <= 0) { continue; }
        CGFloat height = width * 9.0 / 16.0;
        NSUInteger rows = (count + candidate - 1) / candidate;
        CGFloat totalHeight = rows * height + (rows - 1) * kTileGap;
        if (totalHeight <= availableHeight) {
            columns = candidate;
            tileWidth = width;
            break;
        }
    }
    if (tileWidth <= 0) {
        columns = count;
        tileWidth = (availableWidth - (count - 1) * kTileGap) / count;
    }

    CGFloat tileHeight = tileWidth * 9.0 / 16.0;
    NSUInteger rows = (count + columns - 1) / columns;
    CGFloat totalHeight = rows * tileHeight + (rows - 1) * kTileGap;
    CGFloat originY = inset + MAX(0, (availableHeight - totalHeight) / 2);

    for (NSUInteger index = 0; index < count; index++) {
        NSUInteger row = index / columns;
        NSUInteger column = index % columns;
        NSUInteger itemsInRow = MIN(columns, count - row * columns);
        CGFloat rowWidth = itemsInRow * tileWidth + (itemsInRow - 1) * kTileGap;
        CGFloat originX = (bounds.size.width - rowWidth) / 2;

        UIView *host = [identifiers[index] isEqualToString:@"local"]
            ? self.localTileHost
            : self.tileHosts[identifiers[index]];
        if (!host) { continue; }
        host.frame = CGRectMake(originX + column * (tileWidth + kTileGap),
                                originY + row * (tileHeight + kTileGap),
                                tileWidth,
                                tileHeight);
    }
}

#pragma mark - Preview and join

/// Opens the camera/microphone and parks the room at "prepared": capture runs, nothing is
/// published. Permissions are requested here, before the SDK reaches capture, so the system
/// prompts belong to the preview step the user asked for.
- (void)beginPreview {
    JitsiSDK *sdk = [JitsiSDK shared];
    NSString *room = [self trimmed:self.roomField.text];
    NSString *name = [self trimmed:self.displayNameField.text];
    if (!sdk.isConnected || room.length == 0 || name.length == 0) {
        self.joinAfterPreview = NO;
        return;
    }
    if (self.previewPreparing) {
        return;
    }
    if (sdk.isPreviewing
        && [room isEqualToString:self.preparedRoom]
        && [name isEqualToString:self.preparedName]) {
        return;
    }
    self.previewPreparing = YES;
    if (sdk.isPreviewing) {
        [sdk stopPreview];
        [self detachLocalCanvas];
    }
    self.isPreviewPrepared = NO;
    self.preparedRoom = nil;
    self.preparedName = nil;
    self.statusLabel.text = @"Requesting camera and microphone…";
    [self refreshUI];

    __weak typeof(self) weakSelf = self;
    [self requestCapturePermissions:^(BOOL cameraGranted, BOOL microphoneGranted) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (!cameraGranted) { self.wantVideoOn = NO; }
        if (!microphoneGranted) { self.wantAudioOn = NO; }
        [self appendLog:[NSString stringWithFormat:@"permissions camera=%@ microphone=%@",
                         cameraGranted ? @"granted" : @"denied",
                         microphoneGranted ? @"granted" : @"denied"]];
        if (!cameraGranted || !microphoneGranted) {
            [self showCapturePermissionAlertCamera:cameraGranted microphone:microphoneGranted];
        }
        if (!cameraGranted && !microphoneGranted) {
            self.previewPreparing = NO;
            self.statusLabel.text = @"Camera and microphone are blocked. Enable them in Settings, then tap Preview & join.";
            self.joinAfterPreview = NO;
            [self refreshUI];
            return;
        }

        [sdk preparePreview:room
                displayName:name
                      email:nil
                  avatarURL:nil
                      audio:self.wantAudioOn
                      video:self.wantVideoOn
                 completion:^(NSError *error) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) { return; }
            self.previewPreparing = NO;
            if (error) {
                [self reportFailure:@"preparePreview" error:error];
                self.isPreviewPrepared = NO;
                self.joinAfterPreview = NO;
                [self refreshUI];
                return;
            }
            self.isPreviewPrepared = YES;
            self.preparedRoom = room;
            self.preparedName = name;
            self.statusLabel.text = @"Preview ready — check your microphone and camera, then tap Join now.";
            [self appendLog:@"Preview ready; the room is not published yet."];
            [self refreshUI];
            if (self.autoJoinRequested && !self.didAutoJoin) {
                self.didAutoJoin = YES;
                [self joinTapped:nil];
            } else if (self.joinAfterPreview) {
                self.joinAfterPreview = NO;
                [self joinTapped:nil];
            }
        }];
    }];
}

- (void)requestCapturePermissions:(void (^)(BOOL cameraGranted, BOOL microphoneGranted))completion {
    dispatch_group_t group = dispatch_group_create();
    __block BOOL cameraGranted = NO;
    __block BOOL microphoneGranted = NO;

    dispatch_group_enter(group);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) {
        cameraGranted = granted;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL granted) {
        microphoneGranted = granted;
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        completion(cameraGranted, microphoneGranted);
    });
}

- (void)showCapturePermissionAlertCamera:(BOOL)cameraGranted microphone:(BOOL)microphoneGranted {
    NSMutableArray<NSString *> *blocked = [NSMutableArray array];
    if (!cameraGranted) { [blocked addObject:@"Camera"]; }
    if (!microphoneGranted) { [blocked addObject:@"Microphone"]; }
    if (blocked.count == 0) { return; }

    NSString *message = [NSString stringWithFormat:
        @"%@ access is denied. The preview continues with what is allowed; enable %@ in Settings to use %@.",
        [blocked componentsJoinedByString:@" and "],
        blocked.count > 1 ? @"them" : @"it",
        blocked.count > 1 ? @"them" : @"it"];
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Permission needed"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Open Settings"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not now"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
    [self appendLog:[NSString stringWithFormat:@"bootstrap conferenceHost=%@",
                     [self hostFromServiceURL:serviceURL]]];

    __weak typeof(self) weakSelf = self;
    [[JitsiSDK shared] bootstrapWithConferenceHost:[self hostFromServiceURL:serviceURL]
                                          logLevel:@"info"
                                    debugSignaling:NO
                                            region:@"chinaMainland"
                                        completion:^(NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (error) {
            [self reportFailure:@"bootstrap" error:error];
            return;
        }
        self.bootstrapped = YES;
        self.statusLabel.text = @"Connecting…";
        NSString *transport = [self selectedTransport];
        [self appendLog:[NSString stringWithFormat:@"connect serviceUrl=%@ domain=%@ muc=%@ transport=%@",
                         serviceURL, domain, muc, transport]];

        [[JitsiSDK shared] connectWithServiceURL:serviceURL
                                          domain:domain
                                             muc:muc
                                           token:token.length > 0 ? token : nil
                                        username:nil
                                        password:nil
                                       transport:transport
                                      completion:^(NSError *connectError) {
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) { return; }
            if (connectError) {
                [innerSelf reportFailure:@"connect" error:connectError];
                return;
            }
            [innerSelf appendLog:@"CONNECTED — cross-signaling is up"];
            [innerSelf refreshUI];
            if (innerSelf.autoJoinSwitch.isOn) {
                [innerSelf appendLog:@"Auto-join is on; the preview opens first, then the room."];
                innerSelf.joinAfterPreview = YES;
            }
            [innerSelf beginPreview];
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
    if (self.previewPreparing) {
        self.joinAfterPreview = YES;
        [self appendLog:@"Join queued until the preview is ready."];
        return;
    }
    // Preview first, publish second: the camera is already open, so joining reuses the
    // capture instead of flashing it off and on again.
    if (!sdk.isPreviewing
        || !self.isPreviewPrepared
        || ![room isEqualToString:self.preparedRoom]
        || ![name isEqualToString:self.preparedName]) {
        self.joinAfterPreview = YES;
        [self beginPreview];
        return;
    }

    NSString *password = [self trimmed:self.passwordField.text];
    self.prejoinJoinButton.enabled = NO;
    self.statusLabel.text = @"Joining…";
    [self appendLog:[NSString stringWithFormat:@"joinPrepared room=%@ name=%@ mic=%@ camera=%@",
                     room, name,
                     sdk.isAudioMuted ? @"muted" : @"live",
                     sdk.isVideoMuted ? @"muted" : @"live"]];

    __weak typeof(self) weakSelf = self;
    [sdk joinPreparedRoomWithPassword:(password.length > 0 ? password : nil)
                           completion:^(NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { return; }
        if (error) {
            [self reportFailure:@"joinPreparedRoom" error:error];
            if ([JitsiSDK shared].requiresPassword) {
                [self appendLog:@"This room needs a password; fill it in and tap Join now again."];
            }
            [self refreshUI];
            return;
        }
        [self appendLog:@"JOINED — room is live"];
        [self refreshUI];
    }];
}

- (void)prejoinBackTapped:(id)sender {
    // Releasing capture keeps the XMPP connection; tapping Preview & join later reopens it
    // first, so nothing is published unseen.
    [[JitsiSDK shared] stopPreview];
    [self detachLocalCanvas];
    self.previewPreparing = NO;
    self.isPreviewPrepared = NO;
    self.preparedRoom = nil;
    self.preparedName = nil;
    self.joinAfterPreview = NO;
    [self appendLog:@"Preview closed — the connection stays open."];
    self.statusLabel.text = @"Connected. Tap Preview & join when ready.";
    [self refreshUI];
}

- (void)toggleAudioTapped:(id)sender {
    JitsiSDK *sdk = [JitsiSDK shared];
    if (!sdk.isPreviewing && !sdk.isJoined) {
        self.wantAudioOn = !self.wantAudioOn;
        [self appendLog:self.wantAudioOn
            ? @"Microphone will be live on join."
            : @"Microphone will enter muted; the track is still created."];
        [self updatePrejoinControls];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [sdk setAudioMuted:!sdk.isAudioMuted completion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"setAudioMuted" error:error];
            return;
        }
        [weakSelf appendLog:[JitsiSDK shared].isAudioMuted ? @"Microphone muted" : @"Microphone live"];
        [weakSelf refreshUI];
    }];
}

- (void)toggleVideoTapped:(id)sender {
    JitsiSDK *sdk = [JitsiSDK shared];
    if (!sdk.isPreviewing && !sdk.isJoined) {
        self.wantVideoOn = !self.wantVideoOn;
        [self appendLog:self.wantVideoOn
            ? @"Camera will be live on join."
            : @"Camera will enter muted; the track is still created."];
        [self updatePrejoinControls];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [sdk setVideoMuted:!sdk.isVideoMuted completion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"setVideoMuted" error:error];
            return;
        }
        [weakSelf appendLog:[JitsiSDK shared].isVideoMuted ? @"Camera muted" : @"Camera live"];
        [weakSelf refreshUI];
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

- (void)toggleAudioRouteTapped:(id)sender {
    JitsiSDK *sdk = [JitsiSDK shared];
    NSString *next = [sdk.audioOutputRoute isEqualToString:@"speaker"] ? @"receiver" : @"speaker";
    [self requestAudioRoute:next];
}

- (void)requestAudioRoute:(NSString *)route {
    JitsiSDK *sdk = [JitsiSDK shared];
    __weak typeof(self) weakSelf = self;
    [sdk setAudioOutputRoute:route completion:^(NSError *error) {
        if (error) {
            [weakSelf reportFailure:@"setAudioOutputRoute" error:error];
            return;
        }
        [sdk audioOutputRouteWithCompletion:^(NSString *current, NSError *routeError) {
            if (routeError) {
                [weakSelf reportFailure:@"audioOutputRoute" error:routeError];
            } else {
                [weakSelf appendLog:[NSString stringWithFormat:@"Requested %@ → audio on %@",
                                     route, current ?: @"?"]];
            }
            [weakSelf refreshUI];
        }];
    }];
}

- (void)leaveTapped:(id)sender {
    [self appendLog:@"leave"];
    [[JitsiSDK shared] leave];
    [self resetAfterCall];
    [self refreshUI];
}

- (void)disconnectTapped:(id)sender {
    [self appendLog:@"disconnect"];
    [[JitsiSDK shared] disconnect];
    [self resetAfterCall];
    [self refreshUI];
}

- (void)resetAfterCall {
    [self resetTiles];
    [self stopMeetingTimer];
    self.previewPreparing = NO;
    self.isPreviewPrepared = NO;
    self.preparedRoom = nil;
    self.preparedName = nil;
    self.joinAfterPreview = NO;
}

#pragma mark - Sheets

- (void)peopleTapped:(id)sender {
    PeopleSheetViewController *sheet = [[PeopleSheetViewController alloc] init];
    [sheet reloadWithSDK:[JitsiSDK shared] localName:[self localName]];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                 UISheetPresentationControllerDetent.largeDetent];
        presentation.prefersGrabberVisible = YES;
    }
    self.peopleSheet = sheet;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)logsTapped:(id)sender {
    LogSheetViewController *sheet = [[LogSheetViewController alloc] init];
    [sheet setLogText:self.logView.text];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *presentation = sheet.sheetPresentationController;
        presentation.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                                 UISheetPresentationControllerDetent.largeDetent];
        presentation.prefersGrabberVisible = YES;
    }
    self.logSheet = sheet;
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - JitsiSDKDelegate

- (void)jitsiDidChangeState:(NSDictionary<NSString *,id> *)state {
    JitsiSDK *sdk = [JitsiSDK shared];

    if (!sdk.isConnected) {
        // Leave/disconnect already tear the view down; this also covers a remote shutdown.
        [self resetAfterCall];
    }

    [self refreshUI];

    if (sdk.isJoined) {
        if (self.audioRouteAfterJoin.length > 0 && !self.didApplyAudioRoute) {
            self.didApplyAudioRoute = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf requestAudioRoute:weakSelf.audioRouteAfterJoin];
            });
        }
        if (self.unmuteAfterJoin && !self.didUnmuteAfterJoin) {
            self.didUnmuteAfterJoin = YES;
            // Proves the join-muted path created the tracks: both controls must be able to
            // switch them back on without re-entering the room.
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf toggleAudioTapped:nil];
                [weakSelf toggleVideoTapped:nil];
            });
        }
        if (self.sheetAfterJoin.length > 0 && !self.didOpenSheet) {
            self.didOpenSheet = YES;
            BOOL logs = [self.sheetAfterJoin isEqualToString:@"logs"];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (logs) {
                    [weakSelf logsTapped:nil];
                } else {
                    [weakSelf peopleTapped:nil];
                }
            });
        }
        if (self.autoLeaveAfterJoin && !self.didAutoLeave) {
            self.didAutoLeave = YES;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [weakSelf leaveTapped:nil]; });
        }
    } else if ([state[@"isWaitingInLobby"] boolValue]) {
        self.statusLabel.text = [state[@"isWaitingForHost"] boolValue]
            ? @"Waiting in the lobby for the host to start the meeting…"
            : @"Waiting in the lobby for a moderator to admit you…";
    } else if ([state[@"requiresPassword"] boolValue]) {
        self.statusLabel.text = @"This room requires a password.";
    } else if ([state[@"isMediaInterrupted"] boolValue]) {
        self.statusLabel.text = @"Media path interrupted; reconnecting…";
    } else if (sdk.isConnected) {
        // prepare/join emit state updates; do not overwrite the preview or join status.
        if (!self.previewPreparing && !sdk.isPreviewing && !sdk.isJoined) {
            self.statusLabel.text = @"Connected. Ready to preview and join.";
        }
    } else {
        self.statusLabel.text = @"Disconnected";
    }

    NSString *lastError = state[@"lastError"];
    if (lastError.length > 0) {
        [self appendLog:[NSString stringWithFormat:@"state.lastError=%@", lastError]];
    }
}

- (void)jitsiDidReceiveEvent:(NSString *)name payload:(NSDictionary<NSString *,id> *)payload {
    // Audio levels and stats arrive at camera/audio rate; keep the log readable. The route
    // has its own callback below, so the generic event line would just duplicate it.
    if ([name isEqualToString:@"audioLevels"] || [name containsString:@"Stats"]
        || [name isEqualToString:@"audioOutputRouteChanged"]) {
        return;
    }
    [self appendLog:[NSString stringWithFormat:@"event %@ %@", name, [self jsonString:payload]]];
}

- (void)jitsiDidChangeAudioOutputRoute:(NSString *)route {
    [self appendLog:[NSString stringWithFormat:@"System audio route → %@", route]];
    [self refreshUI];
}

- (void)jitsiDidJoinRemoteCanvas:(UIView *)canvasView
                   participantID:(NSString *)participantID
                     displayName:(NSString *)displayName {
    [self addRemoteTile:canvasView participantID:participantID];
    [self appendLog:[NSString stringWithFormat:@"canvas joined: %@",
                     displayName.length > 0 ? displayName : participantID]];
}

- (void)jitsiDidLeaveRemoteParticipant:(NSString *)participantID {
    [self removeRemoteTile:participantID];
    [self appendLog:[NSString stringWithFormat:@"canvas left: %@", participantID]];
}

/// Five updates a second per speaker. Only the sheet colours change; the gallery's speaking
/// rings are drawn by the SDK's canvas controllers.
- (void)jitsiDidUpdateAudioLevels:(NSDictionary<NSString *,NSNumber *> *)levels {
    if (self.peopleSheet.presentingViewController) {
        [self.peopleSheet updateLevels:levels];
    }
}

#pragma mark - Screen state

- (void)refreshUI {
    JitsiSDK *sdk = [JitsiSDK shared];
    BOOL connected = sdk.isConnected;
    BOOL joined = sdk.isJoined;
    BOOL previewing = sdk.isPreviewing;
    BOOL prejoin = !joined && (previewing || self.previewPreparing);

    self.configScrollView.hidden = joined || prejoin;
    self.prejoinView.hidden = !prejoin;
    self.meetingView.hidden = !joined;
    [self.navigationController setNavigationBarHidden:(joined || prejoin) animated:NO];

    self.connectButton.enabled = !connected;
    self.serviceURLField.enabled = !connected;
    self.domainField.enabled = !connected;
    self.mucField.enabled = !connected;
    self.tokenField.enabled = !connected;
    self.connectedButtonsRow.hidden = !(connected && !joined && !previewing && !self.previewPreparing);
    self.disconnectButton.enabled = connected;

    if (joined) {
        [self showMeetingContent];
        [self startMeetingTimer];
        [self updateMeetingChrome];
        [self updateMeetingTimerLabel];
    } else if (prejoin) {
        [self stopMeetingTimer];
        [self attachLocalCanvasToHost:self.prejoinCanvasHost];
        [self updatePrejoinContent];
        [self updatePrejoinControls];
    } else {
        [self stopMeetingTimer];
        [self detachLocalCanvas];
        [self resetTiles];
        self.prejoinJoinButton.enabled = NO;
    }

    if (self.peopleSheet.presentingViewController) {
        [self.peopleSheet reloadWithSDK:sdk localName:[self localName]];
    }
}

- (void)showMeetingContent {
    if (![self.tileOrder containsObject:@"local"]) {
        [self.tileOrder insertObject:@"local" atIndex:0];
    }
    self.meetingRoomLabel.text = [self currentRoom];
    [self attachLocalCanvasToHost:self.localTileHost];
    // The meeting screen was hidden, so the grid still has zero bounds until this pass;
    // tile frames are computed from those bounds.
    [self.view layoutIfNeeded];
    [self layoutVideoGrid];
}

- (void)updatePrejoinContent {
    JitsiSDK *sdk = [JitsiSDK shared];
    self.prejoinRoomLabel.text = [self currentRoom];
    self.prejoinNameLabel.text = [NSString stringWithFormat:@"Joining as %@", [self localName]];
    if (!sdk.isPreviewing) {
        self.prejoinHintLabel.text = @"Starting your camera…";
    } else {
        self.prejoinHintLabel.text =
            @"Nothing is sent until you join. Adjust your microphone and camera, then tap Join now.";
    }
    self.prejoinJoinButton.enabled = sdk.isConnected && sdk.isPreviewing && self.isPreviewPrepared;
}

- (void)updatePrejoinControls {
    JitsiSDK *sdk = [JitsiSDK shared];
    BOOL audioOn = sdk.isPreviewing ? !sdk.isAudioMuted : self.wantAudioOn;
    BOOL videoOn = sdk.isPreviewing ? !sdk.isVideoMuted : self.wantVideoOn;

    [self.prejoinMicButton setImage:SymbolImage(audioOn ? @"mic.fill" : @"mic.slash.fill")
                           forState:UIControlStateNormal];
    self.prejoinMicButton.backgroundColor = audioOn
        ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor systemRedColor];
    self.prejoinMicCaption.text = audioOn ? @"Mute" : @"Unmute";

    [self.prejoinCameraButton setImage:SymbolImage(videoOn ? @"video.fill" : @"video.slash.fill")
                              forState:UIControlStateNormal];
    self.prejoinCameraButton.backgroundColor = videoOn
        ? [UIColor colorWithWhite:1 alpha:0.16] : [UIColor systemRedColor];
    self.prejoinCameraCaption.text = videoOn ? @"Camera" : @"Camera off";

    self.prejoinFlipButton.enabled = sdk.isPreviewing;
    self.prejoinFlipButton.alpha = sdk.isPreviewing ? 1 : 0.4;
}

- (void)updateMeetingChrome {
    JitsiSDK *sdk = [JitsiSDK shared];
    NSUInteger count = sdk.participants.count + 1;
    self.meetingRoomLabel.text = [self currentRoom];
    self.meetingSubtitleLabel.text = [NSString stringWithFormat:@"%@ · %lu in the room",
                                      [self localName], (unsigned long)count];

    [self.micButton setImage:SymbolImage(sdk.isAudioMuted ? @"mic.slash.fill" : @"mic.fill")
                    forState:UIControlStateNormal];
    self.micButton.backgroundColor = sdk.isAudioMuted
        ? [UIColor systemRedColor] : [UIColor colorWithWhite:1 alpha:0.16];
    self.micCaption.text = sdk.isAudioMuted ? @"Unmute" : @"Mute";

    [self.cameraButton setImage:SymbolImage(sdk.isVideoMuted ? @"video.slash.fill" : @"video.fill")
                       forState:UIControlStateNormal];
    self.cameraButton.backgroundColor = sdk.isVideoMuted
        ? [UIColor systemRedColor] : [UIColor colorWithWhite:1 alpha:0.16];
    self.cameraCaption.text = sdk.isVideoMuted ? @"Start camera" : @"Camera";

    BOOL speaker = [sdk.audioOutputRoute isEqualToString:@"speaker"];
    [self.routeButton setImage:SymbolImage(speaker ? @"speaker.wave.2.fill" : @"ear.fill")
                      forState:UIControlStateNormal];
    self.routeCaption.text = sdk.audioOutputRoute.length > 0
        ? [sdk.audioOutputRoute capitalizedString] : @"Audio";

    self.leaveButton.enabled = sdk.isJoined;
}

- (void)startMeetingTimer {
    if (self.meetingTimer) { return; }
    __weak typeof(self) weakSelf = self;
    self.meetingTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateMeetingTimerLabel];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.meetingTimer forMode:NSRunLoopCommonModes];
    [self updateMeetingTimerLabel];
}

- (void)stopMeetingTimer {
    [self.meetingTimer invalidate];
    self.meetingTimer = nil;
    self.meetingTimerLabel.text = @"";
}

- (void)updateMeetingTimerLabel {
    JitsiSDK *sdk = [JitsiSDK shared];
    if (!sdk.isJoined) {
        self.meetingTimerLabel.text = @"";
        return;
    }
    NSNumber *remaining = sdk.meetingRemainingSeconds;
    if (remaining) {
        self.meetingTimerLabel.text =
            [NSString stringWithFormat:@"%@ left", FormatClock(remaining.doubleValue)];
        self.meetingTimerLabel.textColor = remaining.doubleValue <= 60
            ? [UIColor systemRedColor] : [UIColor colorWithWhite:1 alpha:0.85];
    } else if (sdk.meetingElapsedSeconds > 0) {
        self.meetingTimerLabel.text = FormatClock(sdk.meetingElapsedSeconds);
        self.meetingTimerLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    } else {
        self.meetingTimerLabel.text = @"";
    }
}

#pragma mark - UI helpers

- (UILabel *)sectionLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    return label;
}

/// Segment order matches `selectedTransport` and `transportIndexForValue`: auto, bosh,
/// websocket — the same raw values the SDK takes.
- (NSString *)selectedTransport {
    switch (self.transportControl.selectedSegmentIndex) {
        case 1: return @"bosh";
        case 2: return @"websocket";
        default: return @"auto";
    }
}

- (NSInteger)transportIndexForValue:(NSString *)value {
    NSString *normalized = value.lowercaseString;
    if ([normalized isEqualToString:@"bosh"]) { return 1; }
    if ([normalized isEqualToString:@"websocket"]) { return 2; }
    if ([normalized isEqualToString:@"auto"]) { return 0; }
    return NSNotFound;
}

- (UISegmentedControl *)segmentedRowIn:(UIStackView *)stack
                                 title:(NSString *)title
                                 items:(NSArray<NSString *> *)items {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    label.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:label];

    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:items];
    control.selectedSegmentIndex = 0;
    [stack addArrangedSubview:control];
    return control;
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
    } else {
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor systemBlueColor].CGColor;
    }
    button.layer.cornerRadius = 10;
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
    } else {
        button.layer.borderWidth = 1;
        button.layer.borderColor = [UIColor systemBlueColor].CGColor;
    }
    button.layer.cornerRadius = 8;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:40].active = YES;
    [stack addArrangedSubview:button];
    return button;
}

#pragma mark - Helpers

- (NSString *)localName {
    NSString *name = [self trimmed:self.displayNameField.text];
    return name.length > 0 ? name : @"You";
}

- (NSString *)currentRoom {
    NSString *room = [self trimmed:self.roomField.text];
    return room.length > 0 ? room : kDefaultRoom;
}

- (void)reportFailure:(NSString *)operation error:(NSError *)error {
    NSString *message = [NSString stringWithFormat:@"%@ failed: %@", operation, error.localizedDescription];
    [self appendLog:message];
    self.statusLabel.text = message;
    [self refreshUI];
    if (!self.meetingView.hidden) {
        [self alert:message];
    }
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
    // Mirrored to the console so `simctl launch --console-pty` can check a scripted run.
    NSLog(@"[demo] %@", line);

    NSRange end = NSMakeRange(self.logView.text.length, 0);
    [self.logView scrollRangeToVisible:end];
    if (self.logSheet.presentingViewController) {
        [self.logSheet setLogText:self.logView.text];
    }
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

- (void)dealloc {
    [_meetingTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if ([JitsiSDK shared].delegate == self) {
        [JitsiSDK shared].delegate = nil;
    }
}

@end
