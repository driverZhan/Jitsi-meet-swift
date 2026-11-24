//
//  MeetActionView.m
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//

#import "MeetActionView.h"

@interface MeetActionView()

@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UILabel *caption;
@property (nonatomic, strong) UIStackView *stack;

@property (nonatomic, assign) MeetAction style;
@end

@implementation MeetActionView

- (instancetype)initWithAction:(MeetAction)action {
    if ([super init]) {
        self.style = action;
        [self setupUI];
    }
    return self;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setupUI];
    }
    return self;
}


- (void)setupUI {
    self.clipsToBounds = YES;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
       [self.stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
       [self.stack.topAnchor constraintEqualToAnchor:self.topAnchor],
       [self.stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
       [self.stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
}



- (void)addTarget:(id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents {
    [self.button addTarget:target action:action forControlEvents:controlEvents];
}

- (void)setImage:(UIImage *)image forState:(UIControlState)state {
    [self.button setImage:image forState:state];
}


- (void)setText:(NSString *)text {
    _text = text;
    self.caption.text = text;
}

- (void)setStyle:(MeetAction)style {
    self.button.tag = style;
    
    if (style == MeetActionLeave) {
        self.button.backgroundColor = [UIColor systemRedColor];
    }
    
}


#pragma mark- getter
- (UIStackView *)stack {
    if (!_stack) {
        _stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.button,self.caption]];
        _stack.spacing = 6;
        _stack.axis = UILayoutConstraintAxisVertical;
    }
    return _stack;
}


- (UIButton *)button {
    if (!_button) {
        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        _button.tintColor = [UIColor whiteColor];
        _button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        _button.layer.cornerRadius = 26;
        _button.translatesAutoresizingMaskIntoConstraints = NO;
        [_button.widthAnchor constraintEqualToConstant:52].active = YES;
        [_button.heightAnchor constraintEqualToConstant:52].active = YES;
    }
    return _button;
}

- (UILabel *)caption {
    if (!_caption) {
        _caption = [[UILabel alloc] init];
        _caption.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _caption.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        _caption.textAlignment = NSTextAlignmentCenter;
    }
    return _caption;
}

@end
