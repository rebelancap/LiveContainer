//
//  AppSceneView.m
//  LiveContainer
//
//  Created by s s on 2025/5/17.
//
#import "AppSceneViewController.h"
#import "DecoratedAppSceneViewController.h"
#import "LiveContainerSwiftUI-Swift.h"
#import "../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "PiPManager.h"
#import "Localization.h"
#import "LCSharedUtils.h"
#import "utils.h"

#if TARGET_OS_VISION
#import <objc/runtime.h>
#import <objc/message.h>
// ===== MRUI STATE DUMP, host side (Track A of Fable/ORNAMENTS-NEXT-STEPS.md; temporary) =====
// Identical dump to the guest-side one in TweakLoader/UIKit+GuestHooks.m, but run in
// LiveContainer's OWN UI process — the WORKING baseline (full native chrome). Diff
// lc-mrui-host.log against lc-mrui-guest.log to find what entity-backing state guests lack.
//
// RETIRED 2026-07-31 (flip to 1 to re-enable): lc-mrui-host.log has 4 complete baseline
// dumps, whose key fact is that even the host's own working SwiftUI ornaments never register
// with MRUIPlatterOrnamentManager (count stays 0) — SwiftUI bypasses the UIKit ornament
// manager entirely. After writing COMPLETE, the dump then crashed the host five times
// overnight (LiveContainer-2026-07-31-0141*..0146*.ips: LCMRUIDumpAll+1816, msgSend to a
// dangling id at scope teardown — suspect valueForKey:@"ornaments" returning a non-object
// that ARC then releases). If re-enabling, port the type-checked ornaments accessor from
// the TweakLoader copy first.
#define LC_MRUI_HOST_DUMP 0
#if LC_MRUI_HOST_DUMP
static BOOL LCMRUIInteresting(NSString *s) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"mrui|ornament|entity|realit|platter|spatial|stage"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] != nil;
}

// Writes incrementally with fflush so a crash mid-dump still leaves a log pinpointing the
// fatal line. Ivar VALUES are peeked only for name/type-matched (MRUI-ish) ivars, and without
// an ARC retain — blindly retaining every '@' ivar crashed on dangling weak/unretained slots.
static void LCMRUIDumpObjectState(id obj, FILE *f) {
    for(Class c = object_getClass(obj); c && c != NSObject.class; c = class_getSuperclass(c)) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(c, &ivarCount);
        for(unsigned int i = 0; i < ivarCount; i++) {
            const char *nameC = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            NSString *ivarName = @(nameC ?: "?");
            NSString *typeStr = @(type ?: "");
            if(!LCMRUIInteresting(ivarName) && !LCMRUIInteresting(typeStr)) continue;
            if(type && type[0] == '@') {
                fprintf(f, "    ivar %s.%s (%s) = ", class_getName(c), nameC ?: "?", type);
                fflush(f);
                void *raw = *(void **)((char *)(__bridge void *)obj + ivar_getOffset(ivars[i]));
                Class valueClass = raw ? object_getClass((__bridge id)raw) : Nil;
                fprintf(f, "%s\n", raw ? (valueClass ? class_getName(valueClass) : "?") : "nil");
            } else {
                fprintf(f, "    ivar %s.%s (%s) [non-object]\n", class_getName(c), nameC ?: "?", type ?: "?");
            }
        }
        free(ivars);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(c, &methodCount);
        NSMutableArray *hits = [NSMutableArray array];
        for(unsigned int i = 0; i < methodCount; i++) {
            NSString *sel = NSStringFromSelector(method_getName(methods[i]));
            if(LCMRUIInteresting(sel)) [hits addObject:sel];
        }
        free(methods);
        if(hits.count) {
            [hits sortUsingSelector:@selector(caseInsensitiveCompare:)];
            fprintf(f, "    methods %s: %s\n", class_getName(c), [hits componentsJoinedByString:@" "].UTF8String);
        }
        fflush(f);
    }
}

static void LCMRUIDumpAll(NSString *tag, NSString *logPath) {
    FILE *f = fopen(logPath.fileSystemRepresentation, "a");
    if(!f) {
        NSLog(@"[LCMRUIDump/%@] cannot open %@", tag, logPath);
        return;
    }
    fprintf(f, "===== MRUI dump [%s] t=%.3f pid=%d lcHome=%s =====\n", tag.UTF8String,
            CFAbsoluteTimeGetCurrent(), getpid(), getenv("LC_HOME_PATH") ?: "(unset)");
    fflush(f);
    NSBundle *mb = NSBundle.mainBundle;
    fprintf(f, "mainBundle: id=%s path=%s sceneManifest=%s\n",
            mb.bundleIdentifier.UTF8String ?: "?", mb.bundlePath.UTF8String ?: "?",
            [mb objectForInfoDictionaryKey:@"UIApplicationSceneManifest"] ? "present" : "ABSENT");
    fflush(f);
    // API map for the planned manual-ornament-injection experiment: full (unfiltered) method
    // lists of the ornament classes, instance + class side.
    static const char *lcOrnClasses[] = {"MRUIPlatterOrnament", "MRUIOrnamentsItem", "UIOrnament",
                                         "_MRUIOrnamentClientConfigurationUpdater", "_MRUIOrnamentHostWindowObserver", NULL};
    for(int ci = 0; lcOrnClasses[ci]; ci++) {
        Class oc = objc_getClass(lcOrnClasses[ci]);
        if(!oc) {
            fprintf(f, "ORNCLASS %s: not present\n", lcOrnClasses[ci]);
            continue;
        }
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(oc, &mc);
        NSMutableArray *sels = [NSMutableArray array];
        for(unsigned int i = 0; i < mc; i++) [sels addObject:NSStringFromSelector(method_getName(ms[i]))];
        free(ms);
        [sels sortUsingSelector:@selector(caseInsensitiveCompare:)];
        fprintf(f, "ORNCLASS %s (%u): %s\n", lcOrnClasses[ci], mc, [sels componentsJoinedByString:@" "].UTF8String);
        unsigned int cmc = 0;
        Method *cms = class_copyMethodList(object_getClass(oc), &cmc);
        NSMutableArray *csels = [NSMutableArray array];
        for(unsigned int i = 0; i < cmc; i++) [csels addObject:NSStringFromSelector(method_getName(cms[i]))];
        free(cms);
        if(csels.count) {
            [csels sortUsingSelector:@selector(caseInsensitiveCompare:)];
            fprintf(f, "ORNCLASS +%s (%u): %s\n", lcOrnClasses[ci], cmc, [csels componentsJoinedByString:@" "].UTF8String);
        }
        fflush(f);
    }
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        fprintf(f, "SCENE %s role=%s session=%s\n", class_getName(scene.class),
                scene.session.role.UTF8String ?: "?", scene.session.persistentIdentifier.UTF8String ?: "?");
        fflush(f);
        LCMRUIDumpObjectState(scene, f);
        SEL supportsOrnSel = NSSelectorFromString(@"_mrui_supportsPlatterOrnamentManager");
        if([scene respondsToSelector:supportsOrnSel]) {
            fprintf(f, "  calling _mrui_supportsPlatterOrnamentManager...\n");
            fflush(f);
            BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(scene, supportsOrnSel);
            fprintf(f, "  _mrui_supportsPlatterOrnamentManager = %d\n", v);
        }
        SEL ornMgrSel = NSSelectorFromString(@"_mrui_platterOrnamentManagerIfExists");
        if([scene respondsToSelector:ornMgrSel]) {
            fprintf(f, "  calling _mrui_platterOrnamentManagerIfExists...\n");
            fflush(f);
            id ornMgr = ((id (*)(id, SEL))objc_msgSend)(scene, ornMgrSel);
            fprintf(f, "  _mrui_platterOrnamentManagerIfExists = %s\n", ornMgr ? class_getName(object_getClass(ornMgr)) : "nil");
            if(ornMgr) {
                // Entity backing turned out fine everywhere; the ornament question moved into
                // this manager. Dump its full state and its registered ornaments.
                LCMRUIDumpObjectState(ornMgr, f);
                fprintf(f, "  reading ornament manager description...\n");
                fflush(f);
                NSString *mgrDesc = [ornMgr description] ?: @"?";
                if(mgrDesc.length > 500) mgrDesc = [mgrDesc substringToIndex:500];
                fprintf(f, "  manager: %s\n", mgrDesc.UTF8String);
                fflush(f);
                id ornaments = nil;
                @try {
                    ornaments = [ornMgr valueForKey:@"ornaments"];
                } @catch(NSException *e) {
                    fprintf(f, "  ornaments KVC threw: %s\n", e.name.UTF8String ?: "?");
                }
                if([ornaments respondsToSelector:@selector(count)]) {
                    fprintf(f, "  ornaments count = %lu\n", (unsigned long)[ornaments count]);
                    for(id orn in ornaments) {
                        fprintf(f, "  ORNAMENT %s\n", class_getName(object_getClass(orn)));
                        fflush(f);
                        NSString *desc = [orn description] ?: @"?";
                        if(desc.length > 400) desc = [desc substringToIndex:400];
                        fprintf(f, "    %s\n", desc.UTF8String);
                        LCMRUIDumpObjectState(orn, f);
                    }
                } else {
                    fprintf(f, "  ornaments = %s (no count)\n", ornaments ? class_getName(object_getClass(ornaments)) : "nil");
                }
                fflush(f);
            }
        }
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        for(UIWindow *w in ((UIWindowScene *)scene).windows) {
            fprintf(f, "  WINDOW %s frame=%s key=%d\n", class_getName(w.class),
                    NSStringFromCGRect(w.frame).UTF8String, w.isKeyWindow);
            fflush(f);
            LCMRUIDumpObjectState(w, f);
            fprintf(f, "    reading traits...\n");
            fflush(f);
            fprintf(f, "    traits: %s\n", w.traitCollection.description.UTF8String);
            SEL sebSel = NSSelectorFromString(@"mrui_supportsEntityBacking");
            if([w respondsToSelector:sebSel]) {
                fprintf(f, "    calling mrui_supportsEntityBacking...\n");
                fflush(f);
                BOOL v = ((BOOL (*)(id, SEL))objc_msgSend)(w, sebSel);
                fprintf(f, "    mrui_supportsEntityBacking = %d\n", v);
            }
            // _contentsEntity returns a raw CoreRE C++ entity pointer, NOT an ObjC object —
            // treating it as id (ARC retain) crashed the previous dump builds. Probe entity
            // state via BOOL accessors and log the entity only as an opaque pointer.
            SEL hasEntitySel = NSSelectorFromString(@"mrui_hasEntity");
            if([w respondsToSelector:hasEntitySel]) {
                fprintf(f, "    calling mrui_hasEntity...\n");
                fflush(f);
                BOOL hasEntity = ((BOOL (*)(id, SEL))objc_msgSend)(w, hasEntitySel);
                fprintf(f, "    mrui_hasEntity = %d\n", hasEntity);
            }
            SEL boundCtxSel = NSSelectorFromString(@"_mrui_hasBoundContext");
            if([w respondsToSelector:boundCtxSel]) {
                fprintf(f, "    calling _mrui_hasBoundContext...\n");
                fflush(f);
                BOOL hasCtx = ((BOOL (*)(id, SEL))objc_msgSend)(w, boundCtxSel);
                fprintf(f, "    _mrui_hasBoundContext = %d\n", hasCtx);
            }
            SEL ceSel = NSSelectorFromString(@"_contentsEntity");
            if([w respondsToSelector:ceSel]) {
                fprintf(f, "    calling _contentsEntity (raw pointer)...\n");
                fflush(f);
                void *entityPtr = ((void *(*)(id, SEL))objc_msgSend)(w, ceSel);
                fprintf(f, "    _contentsEntity = %p\n", entityPtr);
            }
            fflush(f);
        }
    }
    fprintf(f, "===== MRUI dump [%s] COMPLETE =====\n", tag.UTF8String);
    fclose(f);
    NSLog(@"[LCMRUIDump/%@] complete -> %@", tag, logPath);
}

__attribute__((constructor))
static void LCMRUIHostDumpInit(void) {
    if(NSUserDefaults.lcGuestAppId) {
        // Single-app guest — the TweakLoader copy of this dump covers it.
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        LCMRUIDumpAll(@"host", [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-mrui-host.log"]);
    });
}
#endif // LC_MRUI_HOST_DUMP

// ===== HOST SPACER ORNAMENT (see +lcAddSpacerOrnamentForScene: in the header) =====
// Same private-API recipe proven guest-side in TweakLoader/UIKit+GuestHooks.m
// (Fable/ORNAMENTS-NEXT-STEPS.md ★ SOLVED): this beta's _UIRootPresentationController lacks
// the transition-callback family the builtin animator consults during the ornament backing
// window's root-VC attach, and a beta-only NSAssert fires on the nil-toView presentation.
@interface LCHostAssertionHandler : NSAssertionHandler
@end
@implementation LCHostAssertionHandler
static BOOL LCHostShouldSwallowAssertion(NSString *fileName, NSString *desc) {
    return [desc containsString:@"compatibility flow"] ||
           [fileName containsString:@"UIViewControllerBuiltinTransitionViewAnimator"];
}
- (void)handleFailureInMethod:(SEL)selector object:(id)object file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ... {
    va_list args; va_start(args, format);
    NSString *desc = format ? [[NSString alloc] initWithFormat:format arguments:args] : @"";
    va_end(args);
    if(LCHostShouldSwallowAssertion(fileName, desc)) {
        NSLog(@"[LC] swallowed host UIKit assertion (%@:%ld): %@", fileName, (long)line, desc);
        return;
    }
    [NSException raise:NSInternalInconsistencyException format:@"%@ (%@:%ld)", desc, fileName, (long)line];
}
- (void)handleFailureInFunction:(NSString *)functionName file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ... {
    va_list args; va_start(args, format);
    NSString *desc = format ? [[NSString alloc] initWithFormat:format arguments:args] : @"";
    va_end(args);
    if(LCHostShouldSwallowAssertion(fileName, desc)) {
        NSLog(@"[LC] swallowed host UIKit assertion (%@:%ld): %@", fileName, (long)line, desc);
        return;
    }
    [NSException raise:NSInternalInconsistencyException format:@"%@ (%@:%ld)", desc, fileName, (long)line];
}
@end

static void LCHostInstallOrnamentShims(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSThread.mainThread.threadDictionary[NSAssertionHandlerKey] = [LCHostAssertionHandler new];
        Class rootPC = NSClassFromString(@"_UIRootPresentationController");
        if(!rootPC) return;
        SEL durSel = NSSelectorFromString(@"durationForTransition:");
        if(![rootPC instancesRespondToSelector:durSel]) {
            class_addMethod(rootPC, durSel,
                            imp_implementationWithBlock(^double(id pc, long t) { return 0.0; }), "d@:q");
        }
        for(NSString *selName in @[@"transitionViewDidStart:", @"transitionViewDidComplete:", @"transitionViewDidCancel:"]) {
            SEL s = NSSelectorFromString(selName);
            if(![rootPC instancesRespondToSelector:s]) {
                class_addMethod(rootPC, s, imp_implementationWithBlock(^(id pc, id tv) {}), "v@:@");
            }
        }
        SEL didEndSel = NSSelectorFromString(@"transitionView:didEndTransition:");
        if(![rootPC instancesRespondToSelector:didEndSel]) {
            class_addMethod(rootPC, didEndSel,
                            imp_implementationWithBlock(^(id pc, id tv, long t) {}), "v@:@q");
        }
    });
}
#endif

@interface AppSceneViewController()
@property int resizeDebounceToken;
@property CGSize lcLastPushedSize;
@property CFTimeInterval lastResizeRequestTime;
@property CGPoint normalizedOrigin;
@property bool isNativeWindow;
@property NSUUID* identifier;
@end

@interface AppSceneViewController()
@property(nonatomic) UIWindowScene *hostScene;
@property(nonatomic) NSString *sceneID;
@property(nonatomic) NSExtension* extension;
@property(nonatomic) bool isAppTerminationCleanUpCalled;
@end

@implementation AppSceneViewController

#if TARGET_OS_VISION
+ (void)lcAddSpacerOrnamentForScene:(UIWindowScene *)scene width:(CGFloat)width height:(CGFloat)height gap:(CGFloat)gap {
    // Multitask-bar forensics (pull Documents/lc-spacer.log from LC's container).
    NSString *lcSpacerLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-spacer.log"];
    FILE *slog = fopen(lcSpacerLogPath.fileSystemRepresentation, "a");
    if(slog) {
        fprintf(slog, "spacer request t=%.3f scene=%p w=%.0f h=%.0f gap=%.0f\n",
                CFAbsoluteTimeGetCurrent(), scene, width, height, gap);
    }
    if(!scene) {
        if(slog) { fprintf(slog, "  abort: nil scene\n"); fclose(slog); }
        return;
    }
    static NSMapTable *lcSpacers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lcSpacers = [NSMapTable weakToStrongObjectsMapTable]; });
    if([lcSpacers objectForKey:scene]) {
        if(slog) { fprintf(slog, "  skip: spacer already present\n"); fclose(slog); }
        return;
    }
    LCHostInstallOrnamentShims();
    Class ornClass = NSClassFromString(@"MRUIPlatterOrnament");
    if(!ornClass) {
        if(slog) { fprintf(slog, "  abort: no MRUIPlatterOrnament class\n"); fclose(slog); }
        return;
    }
    id mgr = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"mrui_platterOrnamentManager"));
    if(!mgr) {
        if(slog) { fprintf(slog, "  abort: no ornament manager\n"); fclose(slog); }
        return;
    }
    // Deliberately empty content: the spacer only exists so the shell's chrome-displacement
    // math accounts for the guest's ornament footprint. The backing window staying empty
    // (the nil-toView presentation quirk) is a feature here.
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    // height + gap: the spacer's bottom edge sets where the shell parks the grab bar, and the
    // guest pill's bottom lands at gap+height — the extra gap keeps the bar clear below it
    // instead of touching/overlapping (seen in multitask testing).
    CGSize spacerSize = CGSizeMake(width, height + gap);
    vc.preferredContentSize = spacerSize;
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    @try {
        id orn = ((id (*)(id, SEL, id))objc_msgSend)([ornClass alloc], NSSelectorFromString(@"initWithViewController:"), vc);
        if(!orn) return;
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setSceneAnchorPoint:"), CGPointMake(0.5, 1.0));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setContentAnchorPoint:"), CGPointMake(0.5, 0.0));
        ((void (*)(id, SEL, CGSize))objc_msgSend)(orn, NSSelectorFromString(@"setPreferredContentSize:"), spacerSize);
        if([orn respondsToSelector:NSSelectorFromString(@"_setZOffset:")]) {
            ((void (*)(id, SEL, double))objc_msgSend)(orn, NSSelectorFromString(@"_setZOffset:"), 0.0);
        }
        if([orn respondsToSelector:NSSelectorFromString(@"setOffset2D:")]) {
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setOffset2D:"), CGPointMake(0, gap));
        }
        // The spacer occupies the same spot as the guest's REAL ornament — never let it
        // capture gaze/pinch away from it.
        if([orn respondsToSelector:NSSelectorFromString(@"_setCanCaptureUI:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(orn, NSSelectorFromString(@"_setCanCaptureUI:"), NO);
        }
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"addOrnament:"), orn);
        UIWindow *hostWin = scene.keyWindow ?: scene.windows.firstObject;
        SEL ppmSel = NSSelectorFromString(@"mrui_pointsPerMeter");
        if(hostWin && [hostWin respondsToSelector:ppmSel]) {
            double ppm = ((double (*)(id, SEL))objc_msgSend)(hostWin, ppmSel);
            if(ppm > 0 && [orn respondsToSelector:NSSelectorFromString(@"_setPointsPerMeter:")]) {
                ((void (*)(id, SEL, double))objc_msgSend)(orn, NSSelectorFromString(@"_setPointsPerMeter:"), ppm);
            }
        }
        for(NSString *fixup in @[@"_updateWindowPointsPerMeter", @"_updateForCurrentKeyWindow", @"_setNeedsUpdate"]) {
            SEL s = NSSelectorFromString(fixup);
            if([orn respondsToSelector:s]) {
                ((void (*)(id, SEL))objc_msgSend)(orn, s);
            }
        }
        // The empty backing window paints itself dark, showing up as a phantom capsule
        // behind the guest's real ornament — force every layer of it clear.
        UIWindow *sbw = ((UIWindow *(*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_window"));
        sbw.backgroundColor = UIColor.clearColor;
        for(UIView *sv in sbw.subviews) sv.backgroundColor = UIColor.clearColor;
        [lcSpacers setObject:orn forKey:scene];
        NSLog(@"[LC] host spacer ornament added for scene %@", scene.session.persistentIdentifier);
        if(slog) {
            UIWindow *hw = scene.keyWindow ?: scene.windows.firstObject;
            double hppm = 0;
            SEL hppmSel = NSSelectorFromString(@"mrui_pointsPerMeter");
            if(hw && [hw respondsToSelector:hppmSel]) {
                hppm = ((double (*)(id, SEL))objc_msgSend)(hw, hppmSel);
            }
            fprintf(slog, "  added ok; host window ppm=%.1f\n", hppm);
            fclose(slog);
        }
        // What did the shell actually receive? Log the committed config once it lands.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FILE *slog2 = fopen(lcSpacerLogPath.fileSystemRepresentation, "a");
            if(!slog2) return;
            @try {
                id cfg = ((id (*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_committedConfiguration"));
                fprintf(slog2, "  committed after 3s: %s\n", cfg ? [cfg description].UTF8String : "nil");
            } @catch(NSException *e) {
                fprintf(slog2, "  committed dump threw: %s\n", e.name.UTF8String ?: "?");
            }
            fclose(slog2);
        });
        return;
    } @catch(NSException *e) {
        NSLog(@"[LC] host spacer ornament failed: %@ %@", e.name, e.reason);
        if(slog) { fprintf(slog, "  THREW: %s %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?"); fclose(slog); }
        return;
    }
    if(slog) { fprintf(slog, "  fell through (orn init nil?)\n"); fclose(slog); }
}
#endif

- (instancetype)initWithBundleId:(NSString*)bundleId dataUUID:(NSString*)dataUUID delegate:(id<AppSceneViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    self.delegate = delegate;
    self.dataUUID = dataUUID;
    self.bundleId = bundleId;
    self.scaleRatio = 1.0;
    self.isAppTerminationCleanUpCalled = false;
    self.isNativeWindow = [NSUserDefaults.lcSharedDefaults integerForKey:@"LCMultitaskMode" ] == 1;
#if TARGET_OS_VISION
    // visionOS always hosts a guest in its own spatial WindowGroup (see launchMultitaskGuestApp).
    self.isNativeWindow = YES;
#endif
    
    // init extension
    NSError* error = nil;
    _extension = [NSExtension extensionWithIdentifier:LCUtils.liveProcessBundleIdentifier error:&error];
    if(error) {
        [delegate appSceneVC:self didInitializeWithError:error];
        return nil;
    }
    _extension.preferredLanguages = @[];
    
    NSExtensionItem *item = [NSExtensionItem new];
    NSMutableArray* bookmarks = [NSMutableArray array];
    NSMutableDictionary *userInfo = @{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme,
        @"selected": _bundleId,
        @"selectedContainer": _dataUUID,
        @"bookmarks": bookmarks,
        @"lcHomePath": NSHomeDirectory(),
    }.mutableCopy;

    // Hand the JIT-Less signing cert to LiveProcess. It normally reads this from the shared
    // app-group defaults, but a guest launched into the extension must still get it when app
    // groups aren't available (e.g. a development/hand-signed install), so pass it directly.
    NSData *certData = LCUtils.certificateData;
    if(certData) {
        userInfo[@"LCCertificateData"] = certData;
    }
    NSString *certPassword = LCSharedUtils.certificatePassword;
    if(certPassword) {
        userInfo[@"LCCertificatePassword"] = certPassword;
    }
    
    NSString* launchAppUrlScheme = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    [NSUserDefaults.lcUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
    if(launchAppUrlScheme) {
        [userInfo setValue:launchAppUrlScheme forKey:@"launchAppUrlScheme"];
    }
    
    NSURL *docURL = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"LCSharePrivateDataWithLiveProcess"]) {
        NSData* bookmarkData = [docURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
        [bookmarks addObject:bookmarkData];
    } else {
        bool isSharedApp = false;
        NSBundle* bundle = [LCSharedUtils findBundleWithBundleId:bundleId isSharedAppOut:&isSharedApp];
        // when mutlitask with private app, we can restrict its sandbox to only its own container
        if (!isSharedApp) {
            NSURL *dataURL = [docURL URLByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", dataUUID]];
            NSURL *tweaksURL = [docURL URLByAppendingPathComponent:@"Tweaks"];
            [bookmarks addObject:[bundle.bundleURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
            NSData* containerBookmark = [dataURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0];
            if(containerBookmark) {
                [bookmarks addObject:containerBookmark];
            }
            [bookmarks addObject:[tweaksURL bookmarkDataWithOptions:(1<<11) includingResourceValuesForKeys:0 relativeToURL:0 error:0]];
        }
    }
    item.userInfo = userInfo;
    
    __weak typeof(self) weakSelf = self;
    [_extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *error) {
        [weakSelf appTerminationCleanUp];
        [weakSelf.delegate appSceneVC:weakSelf didInitializeWithError:error];
    }];
    [_extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    [_extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *identifier) {
        if(identifier) {
            [MultitaskManager registerMultitaskContainerWithContainer:self.dataUUID];
            self.identifier = identifier;
            self.pid = [self.extension pidForRequestIdentifier:self.identifier];
            [delegate appSceneVC:self didInitializeWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setUpAppPresenter];
            });
        } else {
            NSError* error = [NSError errorWithDomain:@"LiveProcess" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to start app. Child process has unexpectedly crashed"}];
            [delegate appSceneVC:self didInitializeWithError:error];
        }
    }];
    
    return self;
}

- (void)setUpAppPresenter {
    RBSProcessPredicate* predicate = [PrivClass(RBSProcessPredicate) predicateMatchingIdentifier:@(self.pid)];
    FBProcessManager *manager = [PrivClass(FBProcessManager) sharedInstance];
    // At this point, the process is spawned and we're ready to create a scene to render in our app
    RBSProcessHandle* processHandle = [PrivClass(RBSProcessHandle) handleForPredicate:predicate error:nil];
    [manager registerProcessForAuditToken:processHandle.auditToken];
    UIApplicationSceneSpecification *specification = [UIApplicationSceneSpecification specification];
    
    void (^updateSceneSettings)(id) = ^void(UIMutableApplicationSceneSettings *settings) {
        settings.canShowAlerts = YES;
#if TARGET_OS_VISION
        // The guest rounds its own content at the standard ~46pt visionOS window radius, but the
        // scene's backdrop honors THIS corner config — view.layer.cornerRadius is 0 here, which
        // left a square black backdrop corner poking out from behind the guest's rounded content.
        CGFloat lcSceneCornerRadius = 46;
#else
        CGFloat lcSceneCornerRadius = self.view.layer.cornerRadius;
#endif
        settings.cornerRadiusConfiguration = [[PrivClass(BSCornerRadiusConfiguration) alloc] initWithTopLeft:lcSceneCornerRadius bottomLeft:lcSceneCornerRadius bottomRight:lcSceneCornerRadius topRight:lcSceneCornerRadius];
        // No `UIScreen` on visionOS to take a display configuration from; the system
        // supplies one for the spatial scene.
#if !TARGET_OS_VISION
        settings.displayConfiguration = UIScreen.mainScreen.displayConfiguration;
#endif
        settings.foreground = YES;
        //settings.interruptionPolicy = 2; // reconnect
        settings.level = 1;
        settings.persistenceIdentifier = self.dataUUID;
        settings.statusBarDisabled = !self.isNativeWindow;
        //settings.previewMaximumSize =
        //settings.deviceOrientationEventsEnabled = YES;
        if(!self.usesHostingControllerAPI) {
            settings.safeAreaInsetsPortrait = self.view.safeAreaInsets;
        }
    };
    void (^updateSceneClientSettings)(id) = ^void(UIMutableApplicationSceneClientSettings *clientSettings) {
        clientSettings.interfaceOrientation = UIInterfaceOrientationPortrait;
        clientSettings.statusBarStyle = 0;
    };

    if (@available(iOS 17.4, *)) {
        // Use new API for iOS 17+. While some of these APIs are available since 17.0, we're only interested in fixing event deferring issue
        _UISceneHostingControllerAdvancedConfiguration *config = [[_UISceneHostingControllerAdvancedConfiguration alloc] initWithProcessIdentity:processHandle.identity];
        config.sceneSpecification = specification;
        if (@available(iOS 27.0, *)) {} else {
            // on 27 manually adding this is not need, also setAdditionalExtensions: doesn't exist for some reason
            config.additionalExtensions = [NSOrderedSet orderedSetWithArray:@[
                PrivClass(_UISceneHostingEventDeferringExtension),
            ]];
        }
        self.hostingController = [[_UISceneHostingController alloc] initWithAdvancedConfiguration:config];
        /// !! do NOT use self.hostingController.sceneView here as it breaks keyboard focus on iOS 26 below. I have no idea why this happens even though both return the same object. Maybe sceneView didn't initialize its ViewController properly?
        self.contentView = self.hostingController.sceneViewController.view;
        self.contentView.clipsToBounds = NO;
        // _scenePresenter was a property in 26, but made only ivar in 27
        self.presenter = [self.contentView valueForKey:@"_scenePresenter"];
        self.sceneID = self.presenter.identifier;
        FBScene *scene = self.presenter.scene;
        [scene configureParameters:^(FBSMutableSceneParameters *parameters) {
            [parameters updateSettingsWithBlock:updateSceneSettings];
            [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        }];
        
        /// Fix keyboard focus by setting up event deferring extension. Previously we worked around it by changing identifier, but that broke other things
        _UISceneEventDeferringHostComponent *deferringComponent = self.hostingController._eventDeferringComponent;
        NSAssert(deferringComponent, @"Unexpectedly nil _UISceneEventDeferringHostComponent");
        if (@available(iOS 27.0, *)) { // _UIKeyboardArbiterUsesDeferringGraph()
            /// UIKitCore`__85-[_UIRemoteViewControllerSceneHostingImpl _viewServiceHostSessionDidConnectToClient:]_block_invoke
            /// iOS 27 requires setting up _UISceneEventDeferringHostComponent for keyboard focus to work
            
            /// Replicate these methods since they are made private
            /// -[_UISceneEventDeferringHostComponent setFirstResponderTrackingSelectionPath:]:
            [deferringComponent setValue:self forKey:@"_firstResponderTrackingSelectionPath"];
            // if (!deferringComponent->_flags.clientIsInChain) return;
            /// -[_UISceneEventDeferringHostComponent becomeFirstResponderIfNecessary]:
            // if (deferringComponent->_flags.maintainHostFirstResponderWhenClientWantsKeyboard)
            
            deferringComponent.grantBehavior = 2;
            deferringComponent.selectionRequestBehavior = 2;
        }
        /// UIKitCore`-[_UISceneHostingController createSceneWithConfiguration:]
        /// Lower iOS uses _UISceneHostingEventDeferringExtension, no further setup needed
        
        // Now it's time to get the initial settings from decorated VC
        [self.delegate appSceneVCWillActivateScene:self];
        [self addChildViewController:self.hostingController.sceneViewController];
    } else {
        self.sceneID = [NSString stringWithFormat:@"sceneID:%@-%@", @"LiveProcess", self.dataUUID];
        FBSMutableSceneDefinition *definition = [PrivClass(FBSMutableSceneDefinition) definition];
        definition.identity = [PrivClass(FBSSceneIdentity) identityForIdentifier:self.sceneID];
        definition.clientIdentity = [PrivClass(FBSSceneClientIdentity) identityForProcessIdentity:processHandle.identity];
        definition.specification = specification;
        
        FBSMutableSceneParameters *parameters = [PrivClass(FBSMutableSceneParameters) parametersForSpecification:specification];
        [parameters updateSettingsWithBlock:updateSceneSettings];
        [parameters updateClientSettingsWithBlock:updateSceneClientSettings];
        FBScene *scene = [[PrivClass(FBSceneManager) sharedInstance] createSceneWithDefinition:definition initialParameters:parameters];
        self.presenter = [scene.uiPresentationManager createPresenterWithIdentifier:self.sceneID];
        [self.presenter modifyPresentationContext:^(UIMutableScenePresentationContext *context) {
            context.appearanceStyle = 2;
        }];
        [self.presenter activate];
        
        self.contentView = [[UIView alloc] init];
        [self.contentView addSubview:self.presenter.presentationView];
    }
    [self.view addSubview:_contentView];
    
    // If we have a staging URL scheme, pass it now
    NSString *launchUrl = [NSUserDefaults.standardUserDefaults stringForKey:@"launchAppUrlScheme"];
    if(launchUrl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"launchAppUrlScheme"];
        [self openURLScheme:launchUrl];
    }
    
    __weak typeof(self) weakSelf = self;
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        [weakSelf appTerminationCleanUp];
    }];
    self.contentView.layer.anchorPoint = CGPointMake(0, 0);
    self.contentView.layer.position = CGPointMake(0, 0);
    
    [self.view.window.windowScene _registerSettingsDiffActionArray:@[self] forKey:self.sceneID];
}

- (void)terminate {
    if(self.isAppRunning) {
        [self.extension _kill:SIGTERM];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.extension _kill:SIGKILL];
        });
    }
}

- (void)_performActionsForUIScene:(UIScene *)scene withUpdatedFBSScene:(id)fbsScene settingsDiff:(FBSSceneSettingsDiff *)diff fromSettings:(UIApplicationSceneSettings *)settings transitionContext:(id)context lifecycleActionType:(uint32_t)actionType {
    if(!self.isAppRunning) {
        [self appTerminationCleanUp];
    }
    if(!diff) return;
    
    UIMutableApplicationSceneSettings *baseSettings = [diff settingsByApplyingToMutableCopyOfSettings:settings];
    UIApplicationSceneTransitionContext *newContext = [context copy];
    newContext.actions = nil;
    [self.delegate appSceneVC:self didUpdateFromSettings:baseSettings transitionContext:newContext lifecycleActionType:actionType];
}

- (void)viewWillLayoutSubviews {
#if TARGET_OS_VISION
    // visionOS: autoresizing the host (scene-hosting) view does NOT resize the guest's remote
    // scene — the guest keeps rendering at its original size and gets clipped/letterboxed as
    // the window grows. Push the new size straight into the guest scene on every size change.
    // The existing debounce swallows every update during a live resize, so bypass it and push
    // synchronously; a size guard keeps setting contentView.frame from looping back here.
    CGSize newSize = self.view.bounds.size;
    // Tolerance, not equality: SwiftUI's layout jitters by ±1pt between passes; pushing every
    // jitter made the guest scene oscillate (and the guest-side window enforcer chase it) at 60Hz.
    if((fabs(newSize.width - _lcLastPushedSize.width) >= 1.5 || fabs(newSize.height - _lcLastPushedSize.height) >= 1.5)
       && newSize.width > 0 && newSize.height > 0) {
        _lcLastPushedSize = newSize;
        // Make the hosting view fill the window so its geometry reflects the new size.
        self.contentView.frame = CGRectMake(0, 0, newSize.width, newSize.height);
        UIMutableApplicationSceneSettings *settings = [self.presenter.scene.settings mutableCopy];
        // Prefer UIKit's hosting-view geometry bridge if it exists on this OS; otherwise stuff
        // the frame manually. (applyViewGeometryToSettings: is declared for iOS 19 but is NOT
        // present on this visionOS build — calling it unconditionally crashes.)
        _UISceneHostingView *sceneView = self.hostingController.sceneView;
        SEL applyGeo = NSSelectorFromString(@"applyViewGeometryToSettings:");
        if(sceneView && [sceneView respondsToSelector:applyGeo]) {
            sceneView.frame = CGRectMake(0, 0, newSize.width, newSize.height);
            void (*applyGeoImp)(id, SEL, id) = (void (*)(id, SEL, id))[sceneView methodForSelector:applyGeo];
            applyGeoImp(sceneView, applyGeo, settings);
        } else {
            [settings setFrame:CGRectMake(0, 0, newSize.width, newSize.height)];
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
        }
        UIApplicationSceneTransitionContext *ctx = [UIApplicationSceneTransitionContext new];
        [self.presenter.scene updateSettings:settings withTransitionContext:ctx completion:nil];
    }
#else
    /// For native window we let iPadOS handle it however it wants, which is usually live resize (autoresizingMask set in appSceneVCWillActivateScene)
    if(_contentView.autoresizingMask != (UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight)) {
        [self updateFrameWithSettingsBlock:nil];
    }
#endif
}
- (void)updateFrameWithSettingsBlock:(void (^)(UIMutableApplicationSceneSettings *settings))block {
    __block int currentDebounceToken = ++_resizeDebounceToken;
    dispatch_block_t queueBlock = ^{
        if(currentDebounceToken != self.resizeDebounceToken) {
            return;
        }
        [self updateSettingsWithBlock:^(UIMutableApplicationSceneSettings *settings) {
            // visionOS has no device orientation.
#if !TARGET_OS_VISION
            settings.deviceOrientation = UIDevice.currentDevice.orientation;
#endif
            settings.interfaceOrientation = self.view.window.windowScene.interfaceOrientation;
            CGRect frame = self.view.frame;
            if(!self.usesHostingControllerAPI) {
                frame.size.width /= self.scaleRatio;
                frame.size.height /= self.scaleRatio;
            }
            if(UIInterfaceOrientationIsLandscape(settings.interfaceOrientation)) {
                CGSize size = frame.size;
                frame.size.width = size.height;
                frame.size.height = size.width;
            }
            settings.frame = frame;
            if(block) {
                block(settings);
            }
        }];
    };
    if(_shouldSkipDebounceOnce) {
        _shouldSkipDebounceOnce = NO;
        queueBlock();
    } else {
        dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC));
        dispatch_after(delay, dispatch_get_main_queue(), queueBlock);
    }
}
- (void)updateSettingsWithBlock:(void(^)(UIMutableApplicationSceneSettings *settings))updateSettingsBlock {
    if(_shouldIgnoreSceneUpdates) {
        // Ignore all updates when in PiP mode
        return;
    }
    
    if(!_hostingController && self.contentView) {
        // Legacy path
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
        return;
    }
    
    /// iOS 17.4 path, most are automatically handled by setting values to _UISceneHostingViewController
    /// This is also reachable on legacy path when contentView is nil during early setup
    UIMutableApplicationSceneSettings *tempSettings = [self.presenter.scene.settings mutableCopy];
    if(!tempSettings) {
        tempSettings = [UIMutableApplicationSceneSettings new];
    }
    updateSettingsBlock(tempSettings);
    CGRect frame = tempSettings.frame;
    if(UIInterfaceOrientationIsLandscape(tempSettings.interfaceOrientation)) {
        frame = CGRectMake(frame.origin.x, frame.origin.y, frame.size.height, frame.size.width);
    }
#if TARGET_OS_VISION
    // On visionOS, resizing the hosting view alone does NOT resize the remote guest scene — the
    // guest keeps rendering at its original size and is clipped/letterboxed as the window grows.
    // Push the geometry straight into the guest scene's settings so it re-lays-out to fill the
    // window. (On iPad the hosting controller handles this from the view size, so this is
    // visionOS-only.)
    if(self.presenter.scene) {
        [self.presenter.scene updateSettingsWithBlock:updateSettingsBlock];
    }
#endif
    
    if (self.contentView) {
        BOOL isiOS26 = NO;
        if(@available(iOS 19.0, *)) { if(@available(iOS 27.0, *)) {} else isiOS26 = YES; }
        // Discard position
        frame.origin = CGPointZero;
        self.contentView.frame = frame;
    } else {
        // This method can be called while contentView is nil to set up initial frame
        self.view.frame = frame;
    }
}

- (BOOL)isAppRunning {
    return _pid > 0 && getpgid(_pid) > 0;
}

- (void)appTerminationCleanUp {
    if(_isAppTerminationCleanUpCalled) {
        return;
    }
    _isAppTerminationCleanUpCalled = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        if(self.sceneID) {
            [[PrivClass(FBSceneManager) sharedInstance] destroyScene:self.sceneID withTransitionContext:nil];
        }
        if(self.usesHostingControllerAPI) {
            if(@available(iOS 17.0, *)) {
                [self.hostingController invalidate];
                [self.hostingController.sceneViewController removeFromParentViewController];
                self.hostingController = nil;
            }
        } else if(self.presenter){
            [self.presenter deactivate];
            [self.presenter invalidate];
        }
        self.presenter = nil;
        
        [self.delegate appSceneVCAppDidExit:self];
        [MultitaskManager unregisterMultitaskContainerWithContainer:self.dataUUID];
    });
}

- (void)setBackgroundNotificationEnabled:(bool)enabled {
    if(enabled) {
        // Re-add UIApplicationDidEnterBackgroundNotification
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostDidEnterBackgroundNote:) name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter addObserver:self.extension selector:@selector(_hostWillResignActiveNote:) name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    } else {
        // Remove UIApplicationDidEnterBackgroundNotification so apps like YouTube can continue playing video
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationDidEnterBackgroundNotification object:UIApplication.sharedApplication];
        [NSNotificationCenter.defaultCenter removeObserver:self.extension name:UIApplicationWillResignActiveNotification object:UIApplication.sharedApplication];
    }
}

- (void)viewDidMoveToWindow:(UIWindow *)newWindow shouldAppearOrDisappear:(BOOL)appear {
    [super viewDidMoveToWindow:newWindow shouldAppearOrDisappear:appear];
    if(!newWindow) {
        if(self.sceneID) {
            [self.view.window.windowScene _unregisterSettingsDiffActionArrayForKey:self.sceneID];
        }
        self.delegate = nil;
    }
}

- (void)openURLScheme:(NSString *)urlString {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        // pull from UserDefaults.standard.setValue(launchURLStr, forKey: "launchAppUrlScheme")
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        NSURL *url = [NSURL URLWithString:urlString];
        context.payload = @{UIApplicationLaunchOptionsURLKey: urlString};
        context.actions = [NSSet setWithObject:[[UIOpenURLAction alloc] initWithURL:url]];
        return context;
    }];
}

- (void)handleStatusBarTapAction:(UIAction *)action {
    [self.presenter.scene updateSettingsWithTransitionBlock:^(id settings) {
        UIApplicationSceneTransitionContext *context = [UIApplicationSceneTransitionContext new];
        context.actions = [NSSet setWithObject:action];
        return context;
    }];
}

- (BOOL)usesHostingControllerAPI {
    return _hostingController != nil;
}

@end
 
