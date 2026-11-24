//
//  LogSheetViewController.m
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//

#import "LogSheetViewController.h"

@interface LogSheetViewController ()

@end

@implementation LogSheetViewController{
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
