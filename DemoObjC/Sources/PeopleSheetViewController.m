//
//  PeopleSheetViewController.m
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//

#import "PeopleSheetViewController.h"
#import <LJMeet/LJMeet.h>

@interface PeopleSheetViewController ()

@end

@implementation PeopleSheetViewController{
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
