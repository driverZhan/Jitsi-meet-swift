//
//  PeopleSheetViewController.h
//  JitsiObjCDemo
//
//  Created by .77 on 2026/11/23.
//
/// Read-only roster: one row per endpoint, green while that endpoint speaks. Mute state comes
/// from presence, so a remote row reflects what the room sees, not just local intent.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class JitsiSDK;
@interface PeopleSheetViewController : UIViewController

- (void)reloadWithSDK:(JitsiSDK *)sdk localName:(NSString *)localName;
- (void)updateLevels:(NSDictionary<NSString *, NSNumber *> *)levels;

@end

NS_ASSUME_NONNULL_END
