//
//  AppSceneView.h
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "UIKitPrivate+MultitaskSupport.h"
#import "FoundationPrivate.h"
@import UIKit;
@import Foundation;


@class AppSceneViewController;

API_AVAILABLE(ios(16.0))
@protocol AppSceneViewControllerDelegate <NSObject>
- (void)appSceneVCAppDidExit:(AppSceneViewController*)vc;
- (void)appSceneVC:(AppSceneViewController*)vc didInitializeWithError:(NSError*)error;
@optional
- (void)appSceneVC:(AppSceneViewController*)vc didUpdateFromSettings:(UIMutableApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType;
- (void)appSceneVCWillActivateScene:(AppSceneViewController *)vc;
@end

API_AVAILABLE(ios(16.0))
@interface AppSceneViewController : UIViewController<_UISceneSettingsDiffAction>
@property(nonatomic) NSString* bundleId;
@property(nonatomic) NSString* dataUUID;
@property(nonatomic) int pid;
@property(nonatomic) id<AppSceneViewControllerDelegate> delegate;
@property(nonatomic) BOOL isAppRunning;
@property(nonatomic) BOOL shouldIgnoreSceneUpdates, shouldSkipDebounceOnce;
@property(nonatomic) CGFloat scaleRatio;
@property(nonatomic) UIView* contentView;
@property(nonatomic) _UIScenePresenter *presenter;
@property(nonatomic) _UISceneHostingController *hostingController API_AVAILABLE(ios(17.0));
- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block;
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))block;
- (void)appTerminationCleanUp;
- (void)terminate;
- (void)openURLScheme:(NSString *)urlString;
- (void)handleStatusBarTapAction:(UIAction *)action;
- (BOOL)usesHostingControllerAPI;
#if TARGET_OS_VISION
// Adds an invisible, depth-correct spacer ornament to the HOST scene so the shell moves the
// window chrome (grab bar) below the guest's shell-composited ornament. Geometry comes from
// the guest's registration (LCOrnamentFootprint-<appId> in app-group defaults). UIKit path
// instead of SwiftUI .ornament because only it exposes _setZOffset: (SwiftUI's default floats
// the bar ~14pt toward the viewer). Idempotent per scene.
+ (void)lcAddSpacerOrnamentForScene:(UIWindowScene *)scene width:(CGFloat)width height:(CGFloat)height gap:(CGFloat)gap;
#endif
@end

