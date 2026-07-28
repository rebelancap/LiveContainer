@import Foundation;
@import ObjectiveC;
@import UIKit;

void swizzle(Class class, SEL originalAction, SEL swizzledAction);
void swizzleClassMethod(Class class, SEL originalAction, SEL swizzledAction);

/// A window to present a LiveContainer alert from, built without `UIScreen`.
///
/// The previous idiom — `[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]`
/// — does not compile against the visionOS SDK: `UIScreen` is marked unavailable
/// there (a spatial OS has no single main screen) and `initWithFrame:` is deprecated
/// in favour of scene-based construction. Attaching to the foreground window scene is
/// the correct modern form on iOS as well, so this is one implementation for both.
UIWindow *LCCreateAlertWindow(void);

// Exported from the main executable
@interface NSUserDefaults(LiveContainer)
+ (instancetype)lcUserDefaults;
+ (instancetype)lcSharedDefaults;
+ (NSString *)lcAppGroupPath;
+ (NSString *)lcAppUrlScheme;
+ (NSBundle *)lcMainBundle;
+ (NSDictionary *)guestAppInfo;
+ (NSDictionary *)guestContainerInfo;
+ (bool)isLiveProcess;
+ (bool)isSharedApp;
+ (NSString*)lcGuestAppId;
+ (bool)isSideStore;
+ (bool)sideStoreExist;
+ (NSString*)lcLaunchURL;
@end
