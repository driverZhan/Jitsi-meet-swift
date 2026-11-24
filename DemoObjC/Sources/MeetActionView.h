//
//  MeetActionView.h
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MeetAction) {
    MeetActionMic,
    MeetActionCamera,
    MeetActionFlip,
    MeetActionRoute,
    MeetActionRecord,
    MeetActionLeave,
};


@interface MeetActionView : UIView

@property (nonatomic, strong) NSString *text;
@property (nonatomic, assign, readonly) MeetAction style;


- (instancetype)initWithAction:(MeetAction)action;

- (void)setImage:(nullable UIImage *)image forState:(UIControlState)state;
- (void)addTarget:(nullable id)target action:(SEL)action forControlEvents:(UIControlEvents)controlEvents;

@end

NS_ASSUME_NONNULL_END
