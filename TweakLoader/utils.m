#import "utils.h"

void swizzle(Class class, SEL originalAction, SEL swizzledAction) {
    method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
}

void swizzleClassMethod(Class class, SEL originalAction, SEL swizzledAction) {
    method_exchangeImplementations(class_getClassMethod(class, originalAction), class_getClassMethod(class, swizzledAction));
}

UIWindow *LCCreateAlertWindow(void) {
    // Prefer the scene the user is actually looking at: an alert has to join an
    // existing scene rather than invent a screen-sized one.
    UIWindowScene *scene = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        scene = (UIWindowScene *)candidate;
        if (candidate.activationState == UISceneActivationStateForegroundActive) break;
    }
    if (scene) {
        return [[UIWindow alloc] initWithWindowScene:scene];
    }
    // No scene yet (very early in guest startup). A zero-rect window still presents;
    // UIKit sizes the alert to its own content.
    return [[UIWindow alloc] initWithFrame:CGRectZero];
}
