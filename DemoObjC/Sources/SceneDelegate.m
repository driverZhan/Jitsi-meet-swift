#import "SceneDelegate.h"
#import "ViewController.h"
#import "MeetViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    UINavigationController *root =
        [[UINavigationController alloc] initWithRootViewController:[ViewController new]];
    root.navigationBar.translucent = NO;
    // Pinned opaque appearance: the new SDK renders the bar transparent over the black
    // window otherwise, which hides the title and makes the status bar go light.
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor systemBackgroundColor];
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: [UIColor labelColor]};
    root.navigationBar.standardAppearance = appearance;
    root.navigationBar.scrollEdgeAppearance = appearance;
    root.navigationBar.compactAppearance = appearance;
    root.navigationBar.tintColor = [UIColor systemBlueColor];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
}

@end
