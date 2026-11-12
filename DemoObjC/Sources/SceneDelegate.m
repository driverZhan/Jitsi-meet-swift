#import "SceneDelegate.h"
#import "ViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    UINavigationController *root =
        [[UINavigationController alloc] initWithRootViewController:[ViewController new]];
    root.navigationBar.translucent = NO;
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
}

@end
