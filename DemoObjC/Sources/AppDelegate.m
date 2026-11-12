#import "AppDelegate.h"

@implementation AppDelegate

// iOS 26+ traps at launch when an app built with the current SDK has no scene lifecycle
// (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption). The window is owned by
// SceneDelegate; this class only handles app-level callbacks.
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}

@end
