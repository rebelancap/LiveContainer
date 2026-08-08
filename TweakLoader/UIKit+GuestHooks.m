@import UIKit;
#import "LCSharedUtils.h"
#import "UIKitPrivate.h"
#import "utils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import "Localization.h"

UIInterfaceOrientation LCOrientationLock = UIInterfaceOrientationUnknown;
NSMutableArray<NSString*>* LCSupportedUrlSchemes = nil;
BOOL launchURLProcessed = NO;

#if TARGET_OS_VISION
// visionOS 27 (beta) raises an NSAssert while laying out the keyboard's UITextEffectsWindow /
// input-hosting guides in a guest's hosted scene (NSLayoutConstraint_UIKitAdditions.m,
// "Error in compatibility flow", -[UIView _nsis_center:bounds:inEngine:forLayoutGuide:]). It is
// a debug-only assertion — compiled out of release UIKit — that the keyboard arbiter trips
// automatically at startup, killing every guest. Swallow that one assertion (re-raise
// everything else) so guests run; on a release visionOS this assertion isn't present.
@interface LCGuestAssertionHandler : NSAssertionHandler
@end
@implementation LCGuestAssertionHandler
static BOOL LCShouldSwallowAssertion(NSString *fileName, NSString *desc) {
    return ([desc containsString:@"compatibility flow"]) ||
           ([fileName containsString:@"NSLayoutConstraint"] && [desc length] == 0) ||
           // "toView or fromView should be set..." — beta-only assert tripped during the
           // ornament backing window's root-VC attach (MRUIPlatterOrnament
           // _readyForWindowHostingScene:); release UIKit runs this path with nil views and
           // completes the transition trivially. Swallow anything from this file: an NSAssert
           // in it is by definition absent from release UIKit.
           ([fileName containsString:@"UIViewControllerBuiltinTransitionViewAnimator"]);
}
- (void)handleFailureInMethod:(SEL)selector object:(id)object file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ... {
    va_list args; va_start(args, format);
    NSString *desc = format ? [[NSString alloc] initWithFormat:format arguments:args] : @"";
    va_end(args);
    if(LCShouldSwallowAssertion(fileName, desc)) {
        NSLog(@"[LC] swallowed guest UIKit assertion (%@:%ld): %@", fileName, (long)line, desc);
        return;
    }
    [NSException raise:NSInternalInconsistencyException format:@"%@ (%@:%ld)", desc, fileName, (long)line];
}
- (void)handleFailureInFunction:(NSString *)functionName file:(NSString *)fileName lineNumber:(NSInteger)line description:(NSString *)format, ... {
    va_list args; va_start(args, format);
    NSString *desc = format ? [[NSString alloc] initWithFormat:format arguments:args] : @"";
    va_end(args);
    if(LCShouldSwallowAssertion(fileName, desc)) {
        NSLog(@"[LC] swallowed guest UIKit assertion (%@:%ld): %@", fileName, (long)line, desc);
        return;
    }
    [NSException raise:NSInternalInconsistencyException format:@"%@ (%@:%ld)", desc, fileName, (long)line];
}
@end

// visionOS live-resize FIX (see Fable/WINDOW-PARITY-QUESTIONS.md for the investigation):
// the host's settings/frame pushes DO arrive in a hosted guest, and guest UIKit applies them to
// the UIWindowScene — coordinateSpace.bounds follows the new size — but the guest's UIWindows
// never track the scene's new bounds. On visionOS that window-sizing step belongs to the
// shell/MRUI machinery, which a LiveContainer-hosted scene doesn't have. So enforce it
// ourselves: keep every window of every connected scene sized to its scene's coordinate-space
// bounds. The frame set cascades through normal layout, so SwiftUI/SDL/Metal content resizes
// exactly as it would for a native window resize. Steady-state the tick is two CGRect compares.
static void LCVisionWindowResizeEnforcerTick(void) {
    for(UIScene *uiScene in UIApplication.sharedApplication.connectedScenes) {
        if(![uiScene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)uiScene;
        CGRect target = ws.coordinateSpace.bounds;
        if(target.size.width < 1 || target.size.height < 1) continue;
        for(UIWindow *window in ws.windows) {
            // Ornament backing windows are intentionally small and self-managed — never
            // resize, reround, or otherwise touch them. (They never actually appear in
            // ws.windows on this beta, but keep the guard in case that changes.) Their
            // content is clamped by LCOrnamentStartClampTimer instead.
            SEL backingSel = NSSelectorFromString(@"_isBackingOrnament");
            if([window respondsToSelector:backingSel] && ((BOOL (*)(id, SEL))objc_msgSend)(window, backingSel)) continue;
            // Round every guest window like a native visionOS window. The scene-level corner
            // radius config isn't applied client-side in a hosted scene, so square window
            // backdrops (e.g. SwiftUI's black hosting-view background) poke out from behind
            // content that rounds itself. 46pt continuous matches the system window chrome.
            if(window.layer.cornerRadius < 45) {
                window.layer.cornerRadius = 46;
                window.layer.cornerCurve = @"continuous";
                window.layer.masksToBounds = YES;
            }
            // Tolerance, not equality: the host's SwiftUI layout jitters by ±1pt between passes,
            // and exact comparison made this tick chase the jitter at 60 Hz forever.
            if(fabs(window.frame.size.width - target.size.width) >= 1.5 ||
               fabs(window.frame.size.height - target.size.height) >= 1.5) {
                NSLog(@"[LC] resize enforcer: %@ %@ -> %@", NSStringFromClass(window.class),
                                NSStringFromCGRect(window.frame), NSStringFromCGRect(target));
                window.frame = target;
            }
            // SwiftUI's root _UIHostingView sizes itself from scene geometry it observes via its
            // own (MRUI) path — which never updates in a hosted scene — so it stays at launch
            // size even when the window resizes. Force it to track the window.
            UIView *rootView = window.rootViewController.viewIfLoaded;
            if(rootView && rootView.window == window &&
               (fabs(rootView.frame.size.width - target.size.width) >= 1.5 ||
                fabs(rootView.frame.size.height - target.size.height) >= 1.5)) {
                NSLog(@"[LC] resize enforcer(rootView): %@ %@ -> %@", NSStringFromClass(rootView.class),
                                NSStringFromCGRect(rootView.frame), NSStringFromCGRect(target));
                rootView.frame = target;
            }
            // Views sized from the hosted scene's meaningless display configuration (e.g. the
            // settings nav UI at 1366x1024 "Main"): shrink any direct window subview LARGER than
            // the window in either dimension. Smaller subviews (buttons, overlays) are left alone.
            for(UIView *sub in window.subviews) {
                if(sub == rootView) continue;
                if(sub.frame.size.width - target.size.width >= 1.5 ||
                   sub.frame.size.height - target.size.height >= 1.5) {
                    NSLog(@"[LC] resize enforcer(oversized): %@ %@ -> %@", NSStringFromClass(sub.class),
                                    NSStringFromCGRect(sub.frame), NSStringFromCGRect(target));
                    sub.frame = target;
                }
            }
        }
    }
}

static void LCVisionWindowResizeEnforcerStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *t) {
                LCVisionWindowResizeEnforcerTick();
            }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        });
    });
}

// ===== MRUI DIAGNOSTICS + INJECTION TEST RIG (retired 2026-07-31) =====
// This rig cracked the ornament problem (Fable/ORNAMENTS-NEXT-STEPS.md ★ SOLVED); the
// production path is LCGuestAddOrnament below. Flip to 1 to re-enable the dumps and the 12s
// red-panel test ornament.
#define LC_MRUI_GUEST_DIAG 0
#if LC_MRUI_GUEST_DIAG
// ===== MRUI STATE DUMP (Track A of Fable/ORNAMENTS-NEXT-STEPS.md; temporary diagnostics) =====
// The confirmed recursion (crash 2026-07-31-012220.ips) is a chicken-and-egg:
//   traitCollection → _mrui_traitCollectionForSize: → _contentsEntity
//   → mrui_makeEntityBackedIfPossible → mrui_supportsEntityBacking → traitCollection …
// computing traits wants the contents entity; creating the entity wants the traits. This dump
// compares MRUI state between a WORKING process (LC's own UI — same code in
// AppSceneViewController.m writes lc-mrui-host.log) and a guest (this file, lc-mrui-guest.log):
// which windows have a _contentsEntity, what supportsEntityBacking answers, and what the trait
// sets contain.
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
                // Direct, return-type-checked accessor — NOT valueForKey:. KVC on "ornaments"
                // is the suspect in the retired host dump's teardown crashes (a non-object
                // return treated as id, then released by ARC at scope exit).
                id ornaments = nil;
                SEL ornsSel = NSSelectorFromString(@"ornaments");
                Method ornsMethod = class_getInstanceMethod(object_getClass(ornMgr), ornsSel);
                if(ornsMethod) {
                    char retType[8] = {0};
                    method_getReturnType(ornsMethod, retType, sizeof retType);
                    if(retType[0] == '@') {
                        ornaments = ((id (*)(id, SEL))objc_msgSend)(ornMgr, ornsSel);
                    } else {
                        fprintf(f, "  ornaments accessor returns '%s' (non-object) — skipped\n", retType);
                    }
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

// INJECTION EXPERIMENT: SwiftUI never registers the guest's ornaments (count stays 0 in both
// modes), so bypass SwiftUI entirely — hand-build an MRUIPlatterOrnament and addOrnament: it.
// If it RENDERS (single-app especially, where the real shell composites), the whole pipeline
// works and only SwiftUI's registration step is broken — opening a UIKit-level ornament path
// for guests. Either way the post-inject dump records what registration changed.
static id lcInjectedOrnament = nil;
static UIViewController *lcInjectedVC = nil;

// Focused status of the injected ornament: the committed configuration (the exact geometry
// the shell received — decisive for the oversized chrome displacement), the backing window,
// and the host-view state (nil host view = no composited content surface).
static void LCMRUIOrnamentStatus(NSString *logPath) {
    FILE *f = fopen(logPath.fileSystemRepresentation, "a");
    if(!f) return;
    fprintf(f, "===== ORNAMENT STATUS t=%.3f =====\n", CFAbsoluteTimeGetCurrent());
    fflush(f);
    id orn = lcInjectedOrnament;
    if(!orn) {
        fprintf(f, "no injected ornament\n");
        fclose(f);
        return;
    }
    @try {
        id cfg = ((id (*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_committedConfiguration"));
        fprintf(f, "committedConfiguration: %s\n", cfg ? [cfg description].UTF8String : "nil");
        double ppm = ((double (*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_pointsPerMeter"));
        fprintf(f, "_pointsPerMeter = %f\n", ppm);
        Ivar hvIvar = class_getInstanceVariable(object_getClass(orn), "_hostView");
        void *hvRaw = hvIvar ? *(void **)((char *)(__bridge void *)orn + ivar_getOffset(hvIvar)) : NULL;
        fprintf(f, "_hostView = %s\n", hvRaw ? class_getName(object_getClass((__bridge id)hvRaw)) : "nil");
        UIWindow *bw = ((UIWindow *(*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_window"));
        if(bw) {
            fprintf(f, "backing window %s frame=%s hidden=%d alpha=%.2f scene=%s rootVC=%s viewLoaded=%d\n",
                    class_getName(bw.class), NSStringFromCGRect(bw.frame).UTF8String, bw.isHidden,
                    (double)bw.alpha, bw.windowScene ? class_getName(bw.windowScene.class) : "nil",
                    bw.rootViewController ? class_getName(bw.rootViewController.class) : "nil",
                    bw.rootViewController.viewIfLoaded != nil);
            SEL bppmSel = NSSelectorFromString(@"mrui_pointsPerMeter");
            if([bw respondsToSelector:bppmSel]) {
                fprintf(f, "backing mrui_pointsPerMeter = %f\n", ((double (*)(id, SEL))objc_msgSend)(bw, bppmSel));
            }
            SEL hasEntitySel = NSSelectorFromString(@"mrui_hasEntity");
            if([bw respondsToSelector:hasEntitySel]) {
                fprintf(f, "backing mrui_hasEntity = %d\n", ((BOOL (*)(id, SEL))objc_msgSend)(bw, hasEntitySel));
            }
            SEL boundCtxSel = NSSelectorFromString(@"_mrui_hasBoundContext");
            if([bw respondsToSelector:boundCtxSel]) {
                fprintf(f, "backing _mrui_hasBoundContext = %d\n", ((BOOL (*)(id, SEL))objc_msgSend)(bw, boundCtxSel));
            }
            // Is the content actually IN the backing window? (The swallowed beta assert ran
            // the root-VC presentation with a nil toView, so the view may never have landed.)
            fprintf(f, "backing window subviews (%lu):\n", (unsigned long)bw.subviews.count);
            for(UIView *sv in bw.subviews) {
                fprintf(f, "  %s frame=%s\n", class_getName(sv.class), NSStringFromCGRect(sv.frame).UTF8String);
                for(UIView *sv2 in sv.subviews) {
                    fprintf(f, "    %s frame=%s hidden=%d alpha=%.2f\n", class_getName(sv2.class),
                            NSStringFromCGRect(sv2.frame).UTF8String, sv2.isHidden, (double)sv2.alpha);
                }
            }
            fprintf(f, "injected VC: view.window==backing:%d superview=%s presentingVC=%s\n",
                    lcInjectedVC.viewIfLoaded.window == bw,
                    lcInjectedVC.viewIfLoaded.superview ? class_getName(lcInjectedVC.viewIfLoaded.superview.class) : "nil",
                    lcInjectedVC.presentingViewController ? class_getName(lcInjectedVC.presentingViewController.class) : "nil");
        } else {
            fprintf(f, "backing window: nil\n");
        }
        // Does the advertised render context exist client-side? Compare against the
        // committedConfiguration contextID above.
        Class ctxClass = NSClassFromString(@"CAContext");
        SEL allCtxSel = NSSelectorFromString(@"allContexts");
        if(ctxClass && [ctxClass respondsToSelector:allCtxSel]) {
            NSArray *ctxs = ((NSArray *(*)(id, SEL))objc_msgSend)(ctxClass, allCtxSel);
            for(id ctx in ctxs) {
                unsigned cid = ((unsigned (*)(id, SEL))objc_msgSend)(ctx, NSSelectorFromString(@"contextId"));
                id layer = ((id (*)(id, SEL))objc_msgSend)(ctx, NSSelectorFromString(@"layer"));
                fprintf(f, "CAContext %x layer=%s\n", cid, layer ? class_getName(object_getClass(layer)) : "nil");
            }
        }
    } @catch(NSException *e) {
        fprintf(f, "STATUS THREW: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
    }
    fclose(f);
}

static void LCMRUIInjectTestOrnament(NSString *logPath) {
    FILE *f = fopen(logPath.fileSystemRepresentation, "a");
    if(!f) return;
    fprintf(f, "===== ORNAMENT INJECTION t=%.3f =====\n", CFAbsoluteTimeGetCurrent());
    fflush(f);
    Class ornClass = NSClassFromString(@"MRUIPlatterOrnament");
    UIWindowScene *ws = nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if([scene isKindOfClass:UIWindowScene.class]) { ws = (UIWindowScene *)scene; break; }
    }
    if(!ornClass || !ws) {
        fprintf(f, "abort: ornClass=%p windowScene=%p\n", ornClass, ws);
        fclose(f);
        return;
    }
    fprintf(f, "getting mrui_platterOrnamentManager (creating accessor)...\n");
    fflush(f);
    id mgr = ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"mrui_platterOrnamentManager"));
    if(!mgr) {
        fprintf(f, "abort: manager nil\n");
        fclose(f);
        return;
    }
    // addOrnament: got as far as MRUIKit creating the ornament's hosting window and attaching
    // our root VC, then aborted the guest on an uncaught NSException: -[_UIRootPresentationController
    // durationForTransition:] unrecognized selector (crash 2026-07-31-085846.ips, thrown from
    // -[UIViewControllerBuiltinTransitionViewAnimator durationForTransition:] during
    // -[MRUIPlatterOrnament _readyForWindowHostingScene:]). Shim the missing method with a
    // zero duration ("no animation" — MRUI already wraps the attach in performWithoutAnimation).
    Class rootPC = NSClassFromString(@"_UIRootPresentationController");
    SEL durSel = NSSelectorFromString(@"durationForTransition:");
    if(rootPC && ![rootPC instancesRespondToSelector:durSel]) {
        IMP durImp = imp_implementationWithBlock(^double(id pc, long transition) { return 0.0; });
        BOOL added = class_addMethod(rootPC, durSel, durImp, "d@:q");
        fprintf(f, "shimmed durationForTransition: on _UIRootPresentationController -> %d\n", added);
    } else {
        fprintf(f, "durationForTransition: shim not needed (rootPC=%p responds=%d)\n",
                rootPC, rootPC ? [rootPC instancesRespondToSelector:durSel] : 0);
    }
    // The rest of the UITransitionView delegate family _UIRootPresentationController also
    // lacks (transitionViewDidStart: was the second unrecognized-selector throw). These are
    // notifications; a class that never implemented them has no bookkeeping depending on
    // them, so no-ops are faithful.
    static const char *lcTVSels[] = {"transitionViewDidStart:", "transitionViewDidComplete:",
                                     "transitionViewDidCancel:", NULL};
    for(int si = 0; rootPC && lcTVSels[si]; si++) {
        SEL s = NSSelectorFromString(@(lcTVSels[si]));
        if(![rootPC instancesRespondToSelector:s]) {
            class_addMethod(rootPC, s, imp_implementationWithBlock(^(id pc, id tv) {}), "v@:@");
            fprintf(f, "shimmed %s (no-op)\n", lcTVSels[si]);
        }
    }
    SEL didEndSel = NSSelectorFromString(@"transitionView:didEndTransition:");
    if(rootPC && ![rootPC instancesRespondToSelector:didEndSel]) {
        class_addMethod(rootPC, didEndSel,
                        imp_implementationWithBlock(^(id pc, id tv, long t) {}), "v@:@q");
        fprintf(f, "shimmed transitionView:didEndTransition: (no-op)\n");
    }
    fflush(f);
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.systemRedColor;
    vc.view.layer.cornerRadius = 12;
    // Interactivity test: a real button. If gaze-and-pinch reaches the ornament's backing
    // window, tapping cycles the panel color and appends TAP lines to the log — that's the
    // last unknown between "renders" and "can host real controls".
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 200, 60);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [button setTitle:@"LC TAP TEST" forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    NSString *tapLogPath = logPath;
    [button addAction:[UIAction actionWithHandler:^(UIAction *action) {
        static int taps = 0;
        taps++;
        UIView *panel = ((UIButton *)action.sender).superview;
        panel.backgroundColor = (taps % 2) ? UIColor.systemBlueColor : UIColor.systemRedColor;
        FILE *tf = fopen(tapLogPath.fileSystemRepresentation, "a");
        if(tf) {
            fprintf(tf, "ORNAMENT TAP %d t=%.3f\n", taps, CFAbsoluteTimeGetCurrent());
            fclose(tf);
        }
        NSLog(@"[LCMRUIInject] ornament tapped (%d)", taps);
    }] forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:button];
    vc.preferredContentSize = CGSizeMake(200, 60);
    // Avoid the sheet-flavored default (UIModalPresentationAutomatic) in the root-VC
    // presentation MRUI runs for the ornament window.
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    // Any further gap in this beta's ornament path must LOG, not kill the guest — the 16s
    // post-inject dump still needs to run either way.
    @try {
        fprintf(f, "initWithViewController...\n");
        fflush(f);
        id orn = ((id (*)(id, SEL, id))objc_msgSend)([ornClass alloc], NSSelectorFromString(@"initWithViewController:"), vc);
        if(!orn) {
            fprintf(f, "abort: init returned nil\n");
            fclose(f);
            return;
        }
        fprintf(f, "setting anchors/size...\n");
        fflush(f);
        // Below-the-window placement, mirroring SwiftUI's .ornament(attachmentAnchor: .scene(.bottom)).
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setSceneAnchorPoint:"), CGPointMake(0.5, 1.0));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setContentAnchorPoint:"), CGPointMake(0.5, 0.0));
        ((void (*)(id, SEL, CGSize))objc_msgSend)(orn, NSSelectorFromString(@"setPreferredContentSize:"), CGSizeMake(200, 60));
        // User-visible depth: the default effectiveOffset {0,0,14} floats the ornament (and
        // the chrome bar that re-anchors to it) subtly in front of the window plane. Zero it.
        SEL zGetSel = NSSelectorFromString(@"_zOffset");
        if([orn respondsToSelector:zGetSel] && [orn respondsToSelector:NSSelectorFromString(@"_setZOffset:")]) {
            double z = ((double (*)(id, SEL))objc_msgSend)(orn, zGetSel);
            fprintf(f, "_zOffset default = %f -> setting 0\n", z);
            ((void (*)(id, SEL, double))objc_msgSend)(orn, NSSelectorFromString(@"_setZOffset:"), 0.0);
        }
        // Padding between the window's bottom edge and the ornament: our anchors alone butt
        // them together (gap 0). Native SwiftUI ornaments keep a standoff gap; 16pt is the
        // starting guess — tune by eye against the native vkQuake build.
        SEL off2DGetSel = NSSelectorFromString(@"offset2D");
        if([orn respondsToSelector:off2DGetSel] && [orn respondsToSelector:NSSelectorFromString(@"setOffset2D:")]) {
            CGPoint cur = ((CGPoint (*)(id, SEL))objc_msgSend)(orn, off2DGetSel);
            fprintf(f, "offset2D default = {%f, %f} -> setting {0, 16}\n", cur.x, cur.y);
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setOffset2D:"), CGPointMake(0, 16));
        }
        // The generic _UIRootPresentationController demonstrably can't survive this attach
        // path on ANY build (unrecognized selectors aren't beta-only), so the native flow
        // must run with MRUI's own root presentation controller — the ornament has exactly
        // that flag. Log the default, then opt in.
        SEL installPCGet = NSSelectorFromString(@"_installRootPresentationController");
        if([orn respondsToSelector:installPCGet]) {
            BOOL cur = ((BOOL (*)(id, SEL))objc_msgSend)(orn, installPCGet);
            fprintf(f, "_installRootPresentationController default = %d\n", cur);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(orn, NSSelectorFromString(@"_setInstallRootPresentationController:"), YES);
            fprintf(f, "_setInstallRootPresentationController:YES done\n");
        } else {
            fprintf(f, "_installRootPresentationController not available\n");
        }
        fprintf(f, "addOrnament...\n");
        fflush(f);
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"addOrnament:"), orn);
        lcInjectedOrnament = orn;
        lcInjectedVC = vc;
        fprintf(f, "addOrnament: done\n");
        fflush(f);
        // addOrnament: leaves two gaps in a guest (post-inject dump 807196863): _hostView nil
        // (no composited content surface -> invisible panel) and no host-window observer (no
        // points-per-meter propagation -> chrome displaced absurdly far). Run the steps the
        // native flow would have run, each logged.
        UIWindow *hostWin = ws.keyWindow ?: ws.windows.firstObject;
        SEL ppmSel = NSSelectorFromString(@"mrui_pointsPerMeter");
        if(hostWin && [hostWin respondsToSelector:ppmSel]) {
            double ppm = ((double (*)(id, SEL))objc_msgSend)(hostWin, ppmSel);
            fprintf(f, "host window mrui_pointsPerMeter = %f\n", ppm);
            if(ppm > 0 && [orn respondsToSelector:NSSelectorFromString(@"_setPointsPerMeter:")]) {
                ((void (*)(id, SEL, double))objc_msgSend)(orn, NSSelectorFromString(@"_setPointsPerMeter:"), ppm);
                fprintf(f, "_setPointsPerMeter: done\n");
            }
        }
        static const char *lcFixupSels[] = {"_updateWindowPointsPerMeter", "_addHostViewIfNeeded",
                                            "_updateForCurrentKeyWindow", "_setNeedsUpdate", NULL};
        for(int fi = 0; lcFixupSels[fi]; fi++) {
            SEL s = NSSelectorFromString(@(lcFixupSels[fi]));
            if([orn respondsToSelector:s]) {
                fprintf(f, "calling %s...\n", lcFixupSels[fi]);
                fflush(f);
                ((void (*)(id, SEL))objc_msgSend)(orn, s);
                fprintf(f, "%s done\n", lcFixupSels[fi]);
            } else {
                fprintf(f, "%s not available\n", lcFixupSels[fi]);
            }
        }
        // Proven by run 807197394: the backing window's advertised render context (a4972447)
        // exists client-side and is exactly what the shell composites — but the window's
        // hierarchy is just the empty UITransitionView the nil-toView presentation left
        // behind; even MRUI's own root VC view stays detached (2560x1360 default bounds, no
        // window), which is why installing under it last run drew nothing. Finish the attach
        // the transition skipped: root view INTO the in-window transition view, our content
        // into the root view, and paint every level so any composited pixel shows.
        UIWindow *bw = ((UIWindow *(*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_window"));
        if(bw) {
            UIView *container = bw.subviews.firstObject ?: (UIView *)bw;
            container.backgroundColor = UIColor.systemRedColor;   // already in-window; must show
            UIViewController *rootVC = bw.rootViewController;
            UIView *rootView = rootVC.viewIfLoaded;
            fprintf(f, "container=%s bounds=%s; rootView.window=%p\n", class_getName(container.class),
                    NSStringFromCGRect(container.bounds).UTF8String, rootView.window);
            if(rootView && rootView.window != bw) {
                rootView.frame = container.bounds;
                rootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [container addSubview:rootView];
                rootView.backgroundColor = UIColor.systemGreenColor;
                fprintf(f, "root view attached into container\n");
            }
            if(vc.viewIfLoaded && rootView) {
                if(vc.parentViewController != rootVC) {
                    [rootVC addChildViewController:vc];
                    [rootView addSubview:vc.view];
                    [vc didMoveToParentViewController:rootVC];
                } else if(vc.view.superview != rootView) {
                    [rootView addSubview:vc.view];
                }
                vc.view.frame = rootView.bounds;
                vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                fprintf(f, "content frame now %s; content in-window=%d\n",
                        NSStringFromCGRect(vc.view.frame).UTF8String, vc.view.window == bw);
            }
            [bw setNeedsLayout];
            [bw layoutIfNeeded];
            [CATransaction flush];
        } else {
            fprintf(f, "backing window nil — nothing to attach into\n");
        }
    } @catch(NSException *e) {
        fprintf(f, "INJECTION THREW: %s: %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
        for(NSString *line in [e.callStackSymbols subarrayWithRange:
                NSMakeRange(0, MIN((NSUInteger)15, e.callStackSymbols.count))]) {
            fprintf(f, "  %s\n", line.UTF8String);
        }
    }
    fclose(f);
    LCMRUIOrnamentStatus(logPath);
    NSLog(@"[LCMRUIInject] injection attempt finished");
}
#endif // LC_MRUI_GUEST_DIAG

// ===== LC GUEST ORNAMENT API =====
// Real ornaments for LC guests, built on the private-API recipe proven by the injection
// experiment (Fable/ORNAMENTS-NEXT-STEPS.md ★ SOLVED section). Ports opt in at runtime:
//
//   void *(*add)(UIViewController *, CGFloat, CGFloat, CGFloat) =
//       dlsym(RTLD_DEFAULT, "LCGuestAddOrnament");
//   if(add) add(myOrnamentVC, 200, 60, 16);   // content VC, width, height, gap below window
//
// dlsym misses in a native (non-LC) install, so ports keep SwiftUI .ornament there. Call on
// the main thread once the scene is active. Content: any UIViewController
// (UIHostingController included); prefer plain/material backgrounds — Reality-composited
// effects (glassBackgroundEffect) are in the known invisible-in-guest bucket.

static NSMutableArray *lcGuestOrnaments; // keeps registered ornaments alive

// MRUI's root VC periodically re-inflates its view to ~maximumOrnamentSize (512x680 in the
// tree dumps) — a huge transparent hit-testable surface that materializes as a phantom
// glass panel on gaze. Backing windows never appear in ws.windows, so the resize enforcer
// can't cover them; this dedicated tick clamps every registered ornament's root view back
// to its backing window. (No transforms are in play — dump 807821110 — so frame-set is safe.)
static void LCOrnamentStartClampTimer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm) {
            for(id orn in lcGuestOrnaments) {
                UIWindow *bw = ((UIWindow *(*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_window"));
                if(!bw) continue;
                UIView *rv = bw.rootViewController.viewIfLoaded;
                if(rv && rv.window == bw && !CGRectEqualToRect(rv.frame, bw.bounds)) {
                    rv.frame = bw.bounds;
                }
            }
        }];
        [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    });
}

static void LCOrnamentInstallShims(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // This beta's _UIRootPresentationController lacks the transition-callback family the
        // builtin animator consults during the ornament backing window's root-VC attach.
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

__attribute__((visibility("default")))
void *LCGuestAddOrnament(UIViewController *contentVC, CGFloat width, CGFloat height, CGFloat gap) {
    if(!contentVC || !NSThread.isMainThread) {
        NSLog(@"[LCOrnament] LCGuestAddOrnament needs a content VC and the main thread");
        return NULL;
    }
    Class ornClass = NSClassFromString(@"MRUIPlatterOrnament");
    UIWindowScene *ws = nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        ws = (UIWindowScene *)scene;
        if(scene.activationState == UISceneActivationStateForegroundActive) break;
    }
    if(!ornClass || !ws) {
        NSLog(@"[LCOrnament] no MRUIPlatterOrnament class or no connected window scene");
        return NULL;
    }
    LCOrnamentInstallShims();
    id mgr = ((id (*)(id, SEL))objc_msgSend)(ws, NSSelectorFromString(@"mrui_platterOrnamentManager"));
    if(!mgr) {
        NSLog(@"[LCOrnament] scene has no platter ornament manager");
        return NULL;
    }
    contentVC.modalPresentationStyle = UIModalPresentationFullScreen;
    @try {
        id orn = ((id (*)(id, SEL, id))objc_msgSend)([ornClass alloc], NSSelectorFromString(@"initWithViewController:"), contentVC);
        if(!orn) return NULL;
        // Bottom-center bar hanging `gap` points below the window edge, flush with the
        // window plane (the default zOffset floats it ~14pt toward the viewer).
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setSceneAnchorPoint:"), CGPointMake(0.5, 1.0));
        ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setContentAnchorPoint:"), CGPointMake(0.5, 0.0));
        ((void (*)(id, SEL, CGSize))objc_msgSend)(orn, NSSelectorFromString(@"setPreferredContentSize:"), CGSizeMake(width, height));
        if([orn respondsToSelector:NSSelectorFromString(@"_setZOffset:")]) {
            ((void (*)(id, SEL, double))objc_msgSend)(orn, NSSelectorFromString(@"_setZOffset:"), 0.0);
        }
        if([orn respondsToSelector:NSSelectorFromString(@"setOffset2D:")]) {
            ((void (*)(id, SEL, CGPoint))objc_msgSend)(orn, NSSelectorFromString(@"setOffset2D:"), CGPointMake(0, gap));
        }
        ((void (*)(id, SEL, id))objc_msgSend)(mgr, NSSelectorFromString(@"addOrnament:"), orn);
        // Post-registration repairs for what the native flow does elsewhere and a guest
        // never gets: points-per-meter propagation, then a config recommit.
        UIWindow *hostWin = ws.keyWindow ?: ws.windows.firstObject;
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
        // The beta's nil-toView root presentation leaves the backing window holding an empty
        // UITransitionView with MRUI's root VC view detached — attach the chain by hand.
        UIWindow *bw = ((UIWindow *(*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"_window"));
        if(bw) {
            UIView *container = bw.subviews.firstObject ?: (UIView *)bw;
            UIViewController *rootVC = bw.rootViewController;
            UIView *rootView = rootVC.viewIfLoaded;
            if(rootView && rootView.window != bw) {
                rootView.frame = container.bounds;
                rootView.autoresizingMask = UIViewAutoresizingNone;
                [container addSubview:rootView];
            }
            if(rootView && contentVC.viewIfLoaded) {
                if(contentVC.parentViewController != rootVC) {
                    [rootVC addChildViewController:contentVC];
                    [rootView addSubview:contentVC.view];
                    [contentVC didMoveToParentViewController:rootVC];
                } else if(contentVC.view.superview != rootView) {
                    [rootView addSubview:contentVC.view];
                }
                // PINNED, non-flexing frame: MRUI's root VC re-lays its view out to a huge
                // size (~maximumOrnamentSize) after this attach; flexible content would grow
                // with it and drift out of the visible window slice (buttons rendered
                // hundreds of points below the 60pt strip). The enforcer tick also clamps
                // the root view back each frame.
                contentVC.view.frame = CGRectMake(0, 0, width, height);
                contentVC.view.autoresizingMask = UIViewAutoresizingNone;
            }
            [bw setNeedsLayout];
            [bw layoutIfNeeded];
        }
        if(!lcGuestOrnaments) lcGuestOrnaments = [NSMutableArray new];
        [lcGuestOrnaments addObject:orn];
        LCOrnamentStartClampTimer();
        // Publish the footprint so the multitask host can add its chrome spacer (the grab
        // bar belongs to the HOST scene and never yields to a guest-scene ornament). Written
        // under both identities — the host looks it up by the app's bundle id, which may not
        // equal lcGuestAppId.
        NSDictionary *footprint = @{@"width": @(width), @"height": @(height), @"gap": @(gap)};
        for(NSString *key in @[NSUserDefaults.lcGuestAppId ?: @"", NSBundle.mainBundle.bundleIdentifier ?: @""]) {
            if(key.length) {
                [NSUserDefaults.lcSharedDefaults setObject:footprint
                                                    forKey:[@"LCOrnamentFootprint-" stringByAppendingString:key]];
            }
        }
        NSLog(@"[LCOrnament] ornament registered (%.0fx%.0f, gap %.0f)", width, height, gap);
        return (__bridge void *)orn;
    } @catch(NSException *e) {
        NSLog(@"[LCOrnament] add failed: %@ %@", e.name, e.reason);
        return NULL;
    }
}

// Recursive view-tree dump with the geometry that matters for the ornament content bugs:
// frame vs bounds (they diverge under a transform) and whether a transform is present.
static void LCOrnDumpTree(UIView *v, int depth, FILE *f) {
    for(int i = 0; i < depth; i++) fputs("  ", f);
    BOOL identity = CGAffineTransformIsIdentity(v.transform);
    fprintf(f, "%s frame=%s bounds=%s hidden=%d alpha=%.2f%s\n",
            class_getName(v.class),
            NSStringFromCGRect(v.frame).UTF8String,
            NSStringFromCGRect(v.bounds).UTF8String,
            v.isHidden, (double)v.alpha,
            identity ? "" : " TRANSFORM");
    if(depth < 6) {
        for(UIView *s in v.subviews) LCOrnDumpTree(s, depth + 1, f);
    }
}

__attribute__((visibility("default")))
void LCGuestRemoveOrnament(void *handle) {
    if(!handle) return;
    id orn = (__bridge id)handle;
    @try {
        if([orn respondsToSelector:NSSelectorFromString(@"removeFromManager")]) {
            ((void (*)(id, SEL))objc_msgSend)(orn, NSSelectorFromString(@"removeFromManager"));
        }
    } @catch(NSException *e) {
        NSLog(@"[LCOrnament] remove failed: %@ %@", e.name, e.reason);
    }
    [lcGuestOrnaments removeObject:orn];
}
#endif

#if TARGET_OS_VISION
// Single-app quality of life: when the guest exits cleanly (in-game Quit), bounce the
// relaunch back into the LC UI instead of stranding the user on the home view. atexit
// runs during exit(): the defaults write and LSApplicationWorkspace XPCs complete
// before the process dies, and FrontBoard processes the self-open after death as a
// fresh launch; `selected` == "ui" makes the bootstrap show the LC UI. Crashes skip
// atexit — those still need a manual reopen. Guarded so LC's own guest-switch flows
// (which set `selected` to something else before exiting) are left alone.
static void LCExitMark(const char *stage) {
    // Plain file, not defaults (cfprefsd flushes lazily), in LC's own container
    // (LC_HOME_PATH is captured before the guest home redirect).
    const char *lcHome = getenv("LC_HOME_PATH");
    if(!lcHome) return;
    char p[1024];
    snprintf(p, sizeof p, "%s/Documents/lc-exit-relaunch.log", lcHome);
    FILE *f = fopen(p, "a");
    if(f) {
        fprintf(f, "%.3f %s (main=%d)\n", CFAbsoluteTimeGetCurrent(), stage, NSThread.isMainThread);
        fclose(f);
    }
}

// atexit safety net: by exit() time the game has usually torn its windows down and
// FrontBoard SIGKILLs a scene-less app before any relaunch dance can land (proven by
// the marker log stopping at "opening", never reaching the completion or the pump
// timeout). So no dance here — just make sure the NEXT launch of LC shows the UI
// instead of re-booting the guest.
static void LCSingleAppExitRelaunch(void) {
    NSString *cur = [NSUserDefaults.lcUserDefaults stringForKey:@"selected"];
    if(cur && ![cur isEqualToString:NSUserDefaults.lcGuestAppId]) return;
    [NSUserDefaults.lcUserDefaults setObject:@"ui" forKey:@"selected"];
    [NSUserDefaults.lcUserDefaults synchronize];
    LCExitMark("atexit: selected=ui");
}

// The full quit-to-LC handoff, for guests that cooperate (call via dlsym from the
// game's quit path BEFORE tearing windows down — the scene must still be alive).
// Sets selected=="ui" (synchronized BEFORE the dance so _exit is safe), then lets
// LCSharedUtils hand the relaunch to a sibling LiveContainer install — the only
// thing on this platform that can outlive us and reopen us (pending-URL
// resurrection and extension proxies are both verified dead; see
// relaunchViaSiblingThenExit). Returns normally if the dance fails, so the
// caller can fall through to its regular quit.
__attribute__((visibility("default")))
void LCGuestQuitToLC(void) {
    if(NSUserDefaults.isLiveProcess) return;   // multitask: the host UI is already up
    if(!NSUserDefaults.lcGuestAppId) return;
    NSString *cur = [NSUserDefaults.lcUserDefaults stringForKey:@"selected"];
    if(cur && ![cur isEqualToString:NSUserDefaults.lcGuestAppId]) return;
    [NSUserDefaults.lcUserDefaults setObject:@"ui" forKey:@"selected"];
    [NSUserDefaults.lcUserDefaults synchronize];
    LCExitMark("quit-to-lc: entered");
    void (^dance)(void) = ^{
        LCExitMark("quit-to-lc: relaunching via sibling LC");
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    };
    if(NSThread.isMainThread) {
        dance();
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 8.0, false); // the handshake _exits us (6s cap)
    } else {
        dispatch_async(dispatch_get_main_queue(), dance);
        [NSThread sleepForTimeInterval:8.0];
    }
    LCExitMark("quit-to-lc: fell through to normal quit");
}

// Ports keep hand-rolling multitask detection via _dyld_get_image_name(0) contains
// "LiveProcess" (processName/argv[0] are rewritten by the bundle swap and each fooled
// a build on-device) — export the answer instead so no port copies that trap again.
__attribute__((visibility("default")))
bool LCGuestIsMultitask(void) {
    return NSUserDefaults.isLiveProcess;
}
#endif

__attribute__((constructor))
static void UIKitGuestHooksInit() {
    if(!NSUserDefaults.lcGuestAppId) return;
#if TARGET_OS_VISION
    // Install before UIApplicationMain. The keyboard-layout assertion fires on the main
    // thread, so install on the main thread's per-thread assertion handler.
    NSThread.mainThread.threadDictionary[NSAssertionHandlerKey] = [LCGuestAssertionHandler new];
    // Single-app guests only (in multitask the host UI is already up).
    if(!NSUserDefaults.isLiveProcess) {
        atexit(LCSingleAppExitRelaunch);
    }
#endif
    swizzle(UIApplication.class, @selector(_applicationOpenURLAction:payload:origin:), @selector(hook__applicationOpenURLAction:payload:origin:));
    swizzle(UIApplication.class, @selector(_connectUISceneFromFBSScene:transitionContext:), @selector(hook__connectUISceneFromFBSScene:transitionContext:));
    swizzle(UIApplication.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
    swizzle(UIApplication.class, @selector(canOpenURL:), @selector(hook_canOpenURL:));
    swizzle(UIApplication.class, @selector(setDelegate:), @selector(hook_setDelegate:));
    swizzle(UIScene.class, @selector(scene:didReceiveActions:fromTransitionContext:), @selector(hook_scene:didReceiveActions:fromTransitionContext:));
    swizzle(UIScene.class, @selector(openURL:options:completionHandler:), @selector(hook_openURL:options:completionHandler:));
#if TARGET_OS_VISION
    // Break MRUIKit's window entity-backing trait recursion. As a guest builds its first
    // window, computing -[UIWindow traitCollection] runs MRUIKit's
    // _mrui_traitCollectionForSize:, which asks -[UIWindow(MRUIKit_CoreRE) mrui_supportsEntityBacking],
    // which reads -[UIWindow traitCollection] again — recursing ~1900 deep until the stack
    // overflows. Guarding traitCollection to answer the reentrant read with the *scene's*
    // trait collection (a valid, non-recursive value) breaks the loop WITHOUT suppressing
    // entity backing, so the window's traits stay consistent with its entity-backed spatial
    // scene (returning "not entity-backed" instead makes visionOS 27's Auto Layout
    // "compatibility flow" assertion fire, NSLayoutConstraint_UIKitAdditions.m:3833).
    //
    // Verified load-bearing (2026-07-31): disabling this hook crashes guests at launch even in
    // single-app mode (real shell-backed scene) — the entity-backing recursion is intrinsic to
    // a bundle-swapped guest process, not an artifact of scene hosting. That also means MRUI
    // never establishes entity backing for guests in EITHER mode, which is why ornaments and
    // Reality-composited chrome (nav-bar titles/buttons) don't render. Root cause is beneath
    // this hook — see "OPEN INVESTIGATION" in Fable/WINDOW-PARITY-QUESTIONS.md.
    swizzle(UIWindow.class, @selector(traitCollection), @selector(hook_lc_traitCollection));

    // visionOS 27 (beta) resolves a segmented control's focus/style provider to a
    // StopwatchSupport class that doesn't implement -wantsFocusWithoutSelection, so
    // -[UISegment _wantsFocusWithoutSelectionForStyleProvider:] crashes with unrecognized
    // selector when the control's traits change (e.g. a UITableView settings cell). Replace
    // that method (a private class we can't link a category against) at runtime so a provider
    // missing the selector is treated as "no", otherwise call through to the original.
    Class segmentClass = NSClassFromString(@"UISegment");
    SEL wantsFocusSel = NSSelectorFromString(@"_wantsFocusWithoutSelectionForStyleProvider:");
    Method wantsFocusMethod = segmentClass ? class_getInstanceMethod(segmentClass, wantsFocusSel) : NULL;
    if(wantsFocusMethod) {
        IMP origImp = method_getImplementation(wantsFocusMethod);
        SEL respondsSel = NSSelectorFromString(@"wantsFocusWithoutSelection");
        IMP guardedImp = imp_implementationWithBlock(^BOOL(id selfObj, id provider) {
            if(![provider respondsToSelector:respondsSel]) {
                return NO;
            }
            return ((BOOL(*)(id, SEL, id))origImp)(selfObj, wantsFocusSel, provider);
        });
        method_setImplementation(wantsFocusMethod, guardedImp);
    }
#endif
    NSInteger LCOrientationLockDirection = [NSUserDefaults.guestAppInfo[@"LCOrientationLock"] integerValue];
    if(LCOrientationLockDirection != 0 && [UIDevice.currentDevice userInterfaceIdiom] == UIUserInterfaceIdiomPhone) {
        switch (LCOrientationLockDirection) {
            case 1:
                LCOrientationLock = UIInterfaceOrientationLandscapeRight;
                break;
            case 2:
                LCOrientationLock = UIInterfaceOrientationPortrait;
                break;
            default:
                break;
        }
        if(!NSUserDefaults.isLiveProcess && LCOrientationLock != UIInterfaceOrientationUnknown) {
//            swizzle(UIApplication.class, @selector(_handleDelegateCallbacksWithOptions:isSuspended:restoreState:), @selector(hook__handleDelegateCallbacksWithOptions:isSuspended:restoreState:));
            swizzle(FBSSceneParameters.class, @selector(initWithXPCDictionary:), @selector(hook_initWithXPCDictionary:));
            swizzle(UIViewController.class, @selector(__supportedInterfaceOrientations), @selector(hook___supportedInterfaceOrientations));
            swizzle(UIViewController.class, @selector(shouldAutorotateToInterfaceOrientation:), @selector(hook_shouldAutorotateToInterfaceOrientation:));
            swizzle(UIWindow.class, @selector(setAutorotates:forceUpdateInterfaceOrientation:), @selector(hook_setAutorotates:forceUpdateInterfaceOrientation:));
        }

    }
}

NSString* findDefaultContainerWithBundleId(NSString* bundleId) {
    // find app's default container
    NSString *appGroupPath = [NSUserDefaults lcAppGroupPath];
    NSString* appGroupFolder = [appGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    if(!infoDict) {
        NSString* lcDocFolder = [[NSString stringWithUTF8String:getenv("LC_HOME_PATH")] stringByAppendingPathComponent:@"Documents"];
        
        bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", lcDocFolder, bundleId];
        infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    }
    
    return infoDict[@"LCDataUUID"];
}

void forEachInstalledNotCurrentLC(BOOL isFree, void (^block)(NSString* scheme, BOOL* isBreak)) {
    for(NSString* scheme in [NSClassFromString(@"LCSharedUtils") lcUrlSchemes]) {
        if([scheme isEqualToString:NSUserDefaults.lcAppUrlScheme]) {
            continue;
        }
        BOOL isInstalled = [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString: [NSString stringWithFormat: @"%@://", scheme]]];
        if(!isInstalled) {
            continue;
        }
        BOOL isBreak = false;
        if(isFree && [NSClassFromString(@"LCSharedUtils") isLCSchemeInUse:scheme]) {
            continue;
        }
        block(scheme, &isBreak);
        if(isBreak) {
            return;
        }
    }
}

void LCShowSwitchAppConfirmation(NSURL *url, NSString* bundleId, bool isSharedApp) {
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    
    // check if there's any free LiveContainer to run the app
    if(isSharedApp) {
        __block BOOL anotherLCLaunched = false;
        forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            *isBreak = YES;
            anotherLCLaunched = YES;
            return;
        });
        if(anotherLCLaunched) {
            return;
        }
    }
    
    // if LCSwitchAppWithoutAsking is enabled we directly open the app in current lc
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        return;
    }

    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:bundleId];
    UIWindow *window = LCCreateAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setBool:NO forKey:@"LCOpenSideStore"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestAppWithURL:url];
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    
    if(isSharedApp) {
        forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
            UIAlertAction* openlcAction = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
                newUrlComp.scheme = scheme;
                [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
                window.windowScene = nil;
            }];
            [alert addAction:openlcAction];
        });
    }
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAlert(NSString* message) {
    UIWindow *window = LCCreateAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void LCShowAppNotFoundAlert(NSString* bundleId) {
    LCShowAlert([@"lc.guestTweak.error.bundleNotFound %@" localizeWithFormat: bundleId]);
}

void openUniversalLink(NSString* decodedUrl) {
    NSURL* urlToOpen = [NSURL URLWithString: decodedUrl];
    if(![urlToOpen.scheme isEqualToString:@"https"] && ![urlToOpen.scheme isEqualToString:@"http"]) {
        NSData *data = [decodedUrl dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        
        NSString* finalUrl = [NSString stringWithFormat:@"%@://open-url?url=%@", NSUserDefaults.lcAppUrlScheme, encodedUrl];
        NSURL* url = [NSURL URLWithString: finalUrl];
        
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return;
    }
    
    UIActivityContinuationManager* uacm = [[UIApplication sharedApplication] _getActivityContinuationManager];
    NSUserActivity* activity = [[NSUserActivity alloc] initWithActivityType:NSUserActivityTypeBrowsingWeb];
    activity.webpageURL = urlToOpen;
    NSDictionary* dict = @{
        @"UIApplicationLaunchOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityKey": activity,
        @"UIApplicationLaunchOptionsUserActivityIdentifierKey": NSUUID.UUID.UUIDString,
        @"UINSUserActivitySourceApplicationKey": @"com.apple.mobilesafari",
        @"UIApplicationLaunchOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb,
        @"_UISceneConnectionOptionsUserActivityKey": activity,
        @"UICanvasConnectionOptionsUserActivityTypeKey": NSUserActivityTypeBrowsingWeb
    };
    
    [uacm handleActivityContinuation:dict isSuspended:nil];
}

void LCOpenWebPage(NSString* webPageUrlString, NSString* originalUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCOpenWebPageWithoutAsking"]) {
        openUniversalLink(webPageUrlString);
        return;
    }
    
    NSURLComponents* newUrlComp = [NSURLComponents componentsWithString:originalUrl];
    __block BOOL anotherLCLaunched = false;
    forEachInstalledNotCurrentLC(YES, ^(NSString * scheme, BOOL* isBreak) {
        newUrlComp.scheme = scheme;
        [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
        *isBreak = YES;
        anotherLCLaunched = YES;
        return;
    });
    if(anotherLCLaunched) {
        return;
    }
    
    NSString *message = @"lc.guestTweak.openWebPageTip".loc;
    UIWindow *window = LCCreateAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSClassFromString(@"LCSharedUtils") setWebPageUrlForNextLaunch:webPageUrlString];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }];
    [alert addAction:okAction];
    UIAlertAction* openNowAction = [UIAlertAction actionWithTitle:@"lc.guestTweak.openInCurrentApp".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        openUniversalLink(webPageUrlString);
        window.windowScene = nil;
    }];

    forEachInstalledNotCurrentLC(NO, ^(NSString * scheme, BOOL* isBreak) {
        UIAlertAction* openlc2Action = [UIAlertAction actionWithTitle:[@"lc.guestTweak.openInLc %@" localizeWithFormat:scheme] style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
            newUrlComp.scheme = scheme;
            [UIApplication.sharedApplication openURL:newUrlComp.URL options:@{} completionHandler:nil];
            window.windowScene = nil;
        }];
        [alert addAction:openlc2Action];
    });
    
    [alert addAction:openNowAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    

}

void LCOpenSideStoreURL(NSURL* sidestoreUrl) {
    if ([NSUserDefaults.lcUserDefaults boolForKey:@"LCSwitchAppWithoutAsking"]) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }
    NSString *message = [@"lc.guestTweak.appSwitchTip %@" localizeWithFormat:@"SideStore"];
    UIWindow *window = LCCreateAlertWindow();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"LiveContainer" message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"lc.common.ok".loc style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        [NSUserDefaults.lcUserDefaults setObject:sidestoreUrl.absoluteString forKey:@"launchAppUrlScheme"];
        [NSUserDefaults.lcUserDefaults setObject:@"builtinSideStore" forKey:@"selected"];
        [NSClassFromString(@"LCSharedUtils") launchToGuestApp];
    }];
    [alert addAction:okAction];
    
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"lc.common.cancel".loc style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = UIApplication.sharedApplication.windows.lastObject.windowLevel + 1;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
}

void authenticateUser(void (^completion)(BOOL success, NSError *error)) {
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
        NSString *reason = @"lc.utils.requireAuthentication".loc;

        // Evaluate the policy for both biometric and passcode authentication
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthentication
                localizedReason:reason
                          reply:^(BOOL success, NSError * _Nullable evaluationError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (success) {
                    completion(YES, nil);
                } else {
                    completion(NO, evaluationError);
                }
            });
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if([error code] == LAErrorPasscodeNotSet) {
                completion(YES, nil);
            } else {
                completion(NO, error);
            }
        });
    }
}

void handleLiveContainerLaunch(NSString* bundleName, NSString* containerFolderName, NSURL* url) {
    // check if there are other LCs is running this app
        NSString* runningLC = [NSClassFromString(@"LCSharedUtils") getContainerUsingLCSchemeWithFolderName:containerFolderName];
        // the app is running in an lc, that lc is not me, also is not my avatar
        if(runningLC) {
            if([runningLC hasSuffix:@"liveprocess"]) {
                runningLC = runningLC.stringByDeletingPathExtension;
            }
            NSString* urlStr = [NSString stringWithFormat:@"%@://livecontainer-launch?bundle-name=%@&container-folder-name=%@", runningLC, bundleName, containerFolderName];
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:urlStr] options:@{} completionHandler:nil];
            return;
        }
        
        bool isSharedApp = false;
        NSBundle* bundle = [NSClassFromString(@"LCSharedUtils") findBundleWithBundleId: bundleName isSharedAppOut:&isSharedApp];
        NSDictionary* lcAppInfo;
        if(bundle) {
            lcAppInfo = [NSDictionary dictionaryWithContentsOfURL:[bundle URLForResource:@"LCAppInfo" withExtension:@"plist"]];
        }
        
        if(!bundle || ([lcAppInfo[@"isHidden"] boolValue] && [NSUserDefaults.lcSharedDefaults boolForKey:@"LCStrictHiding"])) {
            LCShowAppNotFoundAlert(bundleName);
        } else if ([lcAppInfo[@"isLocked"] boolValue]) {
            // need authentication
            authenticateUser(^(BOOL success, NSError *error) {
                if (success) {
                    LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
                } else {
                    if ([error.domain isEqualToString:LAErrorDomain]) {
                        if (error.code != LAErrorUserCancel) {
                            NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                        }
                    } else {
                        NSLog(@"[LC] Authentication Error: %@", error.localizedDescription);
                    }
                }
            });
        } else {
            LCShowSwitchAppConfirmation(url, bundleName, isSharedApp);
        }
    
}

BOOL shouldRedirectOpenURLToHost(NSURL* url) {
    NSUserDefaults *ud = NSUserDefaults.lcSharedDefaults;
    return NSUserDefaults.isLiveProcess &&
    [ud boolForKey:@"LCRedirectURLToHost"] &&
    [[ud arrayForKey:@"LCGuestURLSchemes"] containsObject:url.scheme];
}
BOOL canAppOpenItself(NSURL* url) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        NSArray *urlTypes = [infoDictionary objectForKey:@"CFBundleURLTypes"];
        LCSupportedUrlSchemes = [[NSMutableArray alloc] init];
        for (NSDictionary *urlType in urlTypes) {
            NSArray *schemes = [urlType objectForKey:@"CFBundleURLSchemes"];
            for(NSString* scheme in schemes) {
                [LCSupportedUrlSchemes addObject:[scheme lowercaseString]];
            }
        }
    });
    return [LCSupportedUrlSchemes containsObject:[url.scheme lowercaseString]];
}

typedef NS_ENUM(NSInteger, LCControlAppURLHandling) {
    LCControlAppURLHandlingPassThrough,
    LCControlAppURLHandlingReplaceURL,
    LCControlAppURLHandlingStop,
};

static NSString* LCDecodedURLStringFromControlURL(NSURL *url) {
    NSURLComponents* lcUrl = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString* realUrlEncoded = nil;
    for(NSURLQueryItem *queryItem in lcUrl.queryItems) {
        if([queryItem.name isEqualToString:@"url"]) {
            realUrlEncoded = queryItem.value;
            break;
        }
    }
    if(!realUrlEncoded) {
        realUrlEncoded = lcUrl.queryItems.firstObject.value;
    }
    if(!realUrlEncoded) {
        return nil;
    }
    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
    if(!decodedData) {
        return nil;
    }
    return [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
}

static void resolveLaunchExtensionFileBookmark(void) {
    NSData* bookmarkData = [NSUserDefaults.lcSharedDefaults dataForKey:@"LCLaunchExtensionFileBookmark"];
    if(!bookmarkData) {
        return;
    }
    BOOL isStale = NO;
    NSError* error = nil;
    NSURL* resolvedURL = [NSURL URLByResolvingBookmarkData:bookmarkData
                                                   options:(1UL << 10)
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&isStale
                                                     error:&error];
    if(!resolvedURL) {
        NSLog(@"[LC] Failed to resolve shared file bookmark: %@", error.localizedDescription);
    }
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCLaunchExtensionFileBookmark"];
    
}

static LCControlAppURLHandling LCHandleControlAppURL(NSURL *url, NSString** modifiedURLStr) {
    if(!url || url.isFileURL) {
        return LCControlAppURLHandlingPassThrough;
    }

    // pass through sidestore urls
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        return LCControlAppURLHandlingPassThrough;
    }

    if([url.scheme isEqualToString:@"sidestore"]) {
        LCOpenSideStoreURL(url);
        return LCControlAppURLHandlingStop;
    }

    NSString *lcScheme = NSUserDefaults.lcAppUrlScheme;
    // pass through any url that should not be handled by current lc
    if(![url.scheme isEqualToString:lcScheme]) {
        return LCControlAppURLHandlingPassThrough;
    }
    NSString* urlHost = url.host;
    
    if([urlHost isEqualToString:@"livecontainer-relaunch"]) {
        return LCControlAppURLHandlingStop;
    }
    
    if([urlHost isEqualToString:@"livecontainer-launch"]) {
        // If it's not current app, then switch, otherwise check if we need to open the url
        NSString* bundleName = nil;
        NSString* openUrl = nil;
        NSString* containerFolderName = nil;
        NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem* queryItem in components.queryItems) {
            if ([queryItem.name isEqualToString:@"bundle-name"]) {
                bundleName = queryItem.value;
            } else if ([queryItem.name isEqualToString:@"open-url"]) {
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
                openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
                containerFolderName = queryItem.value;
            }
        }
        
        // launch to LiveContainerUI
        if([bundleName isEqualToString:@"ui"]) {
            LCShowSwitchAppConfirmation(url, @"LiveContainer", false);
            return LCControlAppURLHandlingStop;
        }
        
        NSString* containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
        if(!containerFolderName) {
            containerFolderName = findDefaultContainerWithBundleId(bundleName);
        }
        // current bundlename and container folder name matches OR sidestore is running and we are launching builtinSideStore
        if (([bundleName isEqualToString:NSBundle.mainBundle.bundlePath.lastPathComponent] && [containerId isEqualToString:containerFolderName]) ||
            (NSUserDefaults.isSideStore && [bundleName isEqualToString:@"builtinSideStore"])) {
            if(openUrl) {
                if([openUrl hasPrefix:@"file:"]) {
                    resolveLaunchExtensionFileBookmark();
                    *modifiedURLStr = openUrl;
                    return LCControlAppURLHandlingReplaceURL;
                } else {
                    openUniversalLink(openUrl);
                }
            }
        } else {
            if([bundleName isEqualToString:@"builtinSideStore"]) {
                LCShowSwitchAppConfirmation(url, @"SideStore", NO);
                return LCControlAppURLHandlingStop;
            }
            handleLiveContainerLaunch(bundleName, containerFolderName, url);
        }
        
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-web-page"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(decodedUrl) {
            LCOpenWebPage(decodedUrl, url.absoluteString);
        }
        return LCControlAppURLHandlingStop;
    }

    if([urlHost isEqualToString:@"open-url"]) {
        NSString *decodedUrl = LCDecodedURLStringFromControlURL(url);
        if(!decodedUrl) {
            return LCControlAppURLHandlingStop;
        }
        // it's a Universal link, let's call -[UIActivityContinuationManager handleActivityContinuation:isSuspended:]
        if([decodedUrl hasPrefix:@"https"]) {
            openUniversalLink(decodedUrl);
            return LCControlAppURLHandlingStop;
        }
        *modifiedURLStr = decodedUrl;
        return LCControlAppURLHandlingReplaceURL;
    }

    if([urlHost isEqualToString:@"install"]) {
        LCShowAlert(@"lc.guestTweak.restartToInstall".loc);
        return LCControlAppURLHandlingStop;
    }

    return LCControlAppURLHandlingStop;
}

// Handler for AppDelegate
@implementation UIApplication(LiveContainerHook)
- (void)hook__applicationOpenURLAction:(id)action payload:(NSDictionary *)payload origin:(id)origin {
    NSURL *url = [NSURL URLWithString:payload[UIApplicationLaunchOptionsURLKey]];
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSMutableDictionary* newPayload = [payload mutableCopy];
        newPayload[UIApplicationLaunchOptionsURLKey] = replacementURLString;
        [self hook__applicationOpenURLAction:action payload:newPayload origin:origin];
        return;
    }
    [self hook__applicationOpenURLAction:action payload:payload origin:origin];
}

- (void)hook__connectUISceneFromFBSScene:(id)scene transitionContext:(UIApplicationSceneTransitionContext*)context {
#if TARGET_OS_VISION
    // Keep guest windows tracking the (host-driven) scene size — see LCVisionWindowResizeEnforcerTick.
    LCVisionWindowResizeEnforcerStart();
    // A footprint only counts if THIS run registers an ornament — clear the previous run's
    // record so the multitask host doesn't reserve chrome space for an ornament that never
    // arrives (e.g. after a port update that drops the registration).
    static dispatch_once_t lcOrnFootprintOnce;
    dispatch_once(&lcOrnFootprintOnce, ^{
        for(NSString *key in @[NSUserDefaults.lcGuestAppId ?: @"", NSBundle.mainBundle.bundleIdentifier ?: @""]) {
            if(key.length) {
                [NSUserDefaults.lcSharedDefaults removeObjectForKey:[@"LCOrnamentFootprint-" stringByAppendingString:key]];
            }
        }
    });
    // Generic quit ornament: a single-app guest whose port never registers an ornament
    // gets a minimal LC-provided quit pill wired to LCGuestQuitToLC — the only quit
    // affordance possible for ports with no in-game quit path at all. A port that calls
    // LCGuestAddOrnament by t+8s takes precedence (same proven post-scene timing as the
    // retired self-test rig); LCGuestQuitOrnament=NO in LC's defaults switches it off.
    // Frame-based layout throughout — Auto Layout collapses inside hand-attached
    // ornament backing windows.
    static dispatch_once_t lcQuitOrnOnce;
    dispatch_once(&lcQuitOrnOnce, ^{
        if(NSUserDefaults.isLiveProcess) return; // multitask: the host UI owns app exit
        id pref = [NSUserDefaults.lcUserDefaults objectForKey:@"LCGuestQuitOrnament"];
        if(pref && ![pref boolValue]) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if(lcGuestOrnaments.count) return; // the port brought its own bar
            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.9]; // solid: glass never composites for guests
            vc.view.layer.cornerRadius = 26;
            vc.view.layer.cornerCurve = @"continuous";
            UIButton *quit = [UIButton buttonWithType:UIButtonTypeSystem];
            quit.frame = CGRectMake(0, 0, 84, 52);
            quit.autoresizingMask = UIViewAutoresizingNone;
            [quit setImage:[UIImage systemImageNamed:@"rectangle.portrait.and.arrow.right"] forState:UIControlStateNormal];
            quit.tintColor = UIColor.whiteColor;
            // Default gaze highlight is a bare grey rectangle; give it the pill's shape.
            quit.hoverStyle = [UIHoverStyle styleWithEffect:[UIHoverHighlightEffect effect] shape:[UIShape capsuleShape]];
            [quit addAction:[UIAction actionWithHandler:^(UIAction *a) {
                // Off-main: LCGuestQuitToLC blocks its caller while the relay dance
                // runs; the engine keeps rendering and the dance _exits us.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    LCGuestQuitToLC();
                });
            }] forControlEvents:UIControlEventTouchUpInside];
            [vc.view addSubview:quit];
            LCGuestAddOrnament(vc, 84, 52, 14);
        });
    });

// Retired 2026-08-07: the port now registers its own ornament via LCGuestAddOrnament
// (vkQuake-ios VKQLiveContainer.m) — running both would double the bar. The rig's
// findings live in Fable/ORNAMENTS-NEXT-STEPS.md.
#define LC_ORNAMENT_SELFTEST 0
#if LC_ORNAMENT_SELFTEST
    // TEMPORARY API self-test (vkQuake only): exercises exported LCGuestAddOrnament exactly
    // as a port would — dlsym through RTLD_DEFAULT — and wires the buttons to the guest's
    // real exported controls (VKQ_Enter3D / VKQ_OpenSettingsSheet, @_cdecl exports in the
    // port's Swift shell). Delete once the port registers its own ornament.
    static dispatch_once_t lcOrnSelfTestOnce;
    dispatch_once(&lcOrnSelfTestOnce, ^{
        if(![NSBundle.mainBundle.bundleIdentifier containsString:@"vkquake"]) return;
        // 8s: the proven injection timing — at 4s the scene was still settling (bar never
        // yielded). Frame-based layout throughout: Auto Layout gets no reliable layout pass
        // inside the hand-attached backing-window hierarchy (buttons collapsed to specks).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            void *(*add)(UIViewController *, CGFloat, CGFloat, CGFloat) = dlsym(RTLD_DEFAULT, "LCGuestAddOrnament");
            // VKQ_Enter3D / VKQ_OpenSettingsSheet are NOT in the shipped binary's export
            // table (verified against vkq-unsigned.ipa) — but VKQ_TouchCommand IS, and the
            // shell registers `vkq3d` (toggle 3D) and `vkqsettings` (open settings sheet)
            // console commands. Drive those. (The real port patch calls its own functions
            // directly and needs none of this.)
            void *guestImg = dlopen(NSBundle.mainBundle.executablePath.fileSystemRepresentation, RTLD_NOW | RTLD_NOLOAD);
            void (*touchCmd)(const char *) = guestImg ? dlsym(guestImg, "VKQ_TouchCommand") : NULL;
            if(!touchCmd) touchCmd = dlsym(RTLD_DEFAULT, "VKQ_TouchCommand");
            NSLog(@"[LCOrnament] selftest: add=%p guestImg=%p touchCmd=%p", add, guestImg, touchCmd);
            {   // pointer forensics on disk — NSLog is a pain to pull from the device
                NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-orn-tree.log"];
                FILE *pf = fopen(p.fileSystemRepresentation, "a");
                if(pf) {
                    fprintf(pf, "SELFTEST PTRS t=%.3f add=%p guestImg=%p touchCmd=%p exe=%s\n",
                            CFAbsoluteTimeGetCurrent(), add, guestImg, (void *)touchCmd,
                            NSBundle.mainBundle.executablePath.UTF8String ?: "?");
                    fclose(pf);
                }
            }
            if(!add) return;
            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.9];
            vc.view.layer.cornerRadius = 26;
            vc.view.layer.cornerCurve = @"continuous";
            UIButton *b3d = [UIButton buttonWithType:UIButtonTypeSystem];
            b3d.frame = CGRectMake(0, 0, 90, 52);
            // NO autoresizing (tree dump 807821110: FlexibleHeight/margin masks crushed the
            // buttons to zero height / x=-1096 when the content view snapped to final size).
            b3d.autoresizingMask = UIViewAutoresizingNone;
            [b3d setTitle:@"3D" forState:UIControlStateNormal];
            b3d.titleLabel.font = [UIFont boldSystemFontOfSize:19];
            [b3d addAction:[UIAction actionWithHandler:^(UIAction *a) {
                static bool lcOrn3DOn = false;
                lcOrn3DOn = !lcOrn3DOn;
                if(touchCmd) touchCmd("vkq3d\n");   // the command itself toggles
                [(UIButton *)a.sender setTitle:(lcOrn3DOn ? @"Exit" : @"3D") forState:UIControlStateNormal];
            }] forControlEvents:UIControlEventTouchUpInside];
            UIButton *bGear = [UIButton buttonWithType:UIButtonTypeSystem];
            bGear.frame = CGRectMake(90, 0, 90, 52);
            bGear.autoresizingMask = UIViewAutoresizingNone;
            [bGear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
            [bGear addAction:[UIAction actionWithHandler:^(UIAction *a) {
                if(touchCmd) touchCmd("vkqsettings\n");
                // Forensics (2026-08-07) proved the SwiftUI sheet DOES present — its view
                // lands in a separate presentation window that, like ornament backing
                // windows, the shell never composites for guests. Experiment: pull the
                // presented sheet's view into the VISIBLE game window. If the port's real
                // settings UI appears and works, the port-side fix is just "present
                // in-window under LC".
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-orn-tree.log"];
                    FILE *pf = fopen(p.fileSystemRepresentation, "a");
                    if(!pf) return;
                    fprintf(pf, "GEAR RESCUE t=%.3f\n", CFAbsoluteTimeGetCurrent());
                    @try {
                        for(UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
                            if(![sc isKindOfClass:UIWindowScene.class]) continue;
                            UIWindowScene *wsc = (UIWindowScene *)sc;
                            for(UIWindow *w in wsc.windows) {
                                UIViewController *pvc = w.rootViewController.presentedViewController;
                                if(!pvc || !pvc.viewIfLoaded) continue;
                                // The sheet presents into the SwiftUI shell window, which
                                // under LC sits below the SDL window carrying the game
                                // render; raising that window showed the sheet but proved
                                // FLAKY (worked one build, not the next) and its opaque
                                // background blacked out the game. Deterministic fix:
                                // reparent the sheet view into the TOPMOST regular window —
                                // in-window content has rendered reliably every time.
                                // SwiftUI removes the view itself on dismissal.
                                UIWindow *topWin = nil;
                                for(UIWindow *ow in wsc.windows) {
                                    if(ow == pvc.view.window) continue;
                                    if([ow isKindOfClass:NSClassFromString(@"UITextEffectsWindow")]) continue;
                                    topWin = ow;   // windows is back-to-front; last match = topmost
                                }
                                if(!topWin) {
                                    fprintf(pf, "  no target window for sheet rescue\n");
                                    continue;
                                }
                                if(pvc.view.window == topWin) {
                                    fprintf(pf, "  sheet already rescued into %p\n", topWin);
                                    continue;
                                }
                                // Refuse degenerate sizes: after a messy cycle SwiftUI can
                                // re-present with a tiny stale frame (350x150 clipped panel).
                                CGSize sz = pvc.view.frame.size;
                                if(sz.width < 600 || sz.height < 500) {
                                    sz = CGSizeMake(topWin.bounds.size.width * 0.7,
                                                    topWin.bounds.size.height * 0.85);
                                }
                                pvc.view.frame = CGRectMake((topWin.bounds.size.width - sz.width) / 2,
                                                            (topWin.bounds.size.height - sz.height) / 2,
                                                            sz.width, sz.height);
                                pvc.view.layer.cornerRadius = 24;
                                pvc.view.layer.cornerCurve = @"continuous";
                                pvc.view.layer.masksToBounds = YES;
                                [topWin addSubview:pvc.view];
                                fprintf(pf, "  sheet %s reparented into %s(%p) frame=%s\n",
                                        class_getName(pvc.class), class_getName(topWin.class), topWin,
                                        NSStringFromCGRect(pvc.view.frame).UTF8String);
                                // Janitor: once the presentation ends, SwiftUI tears down its
                                // CONTENT but not our relocated view — the empty black shell
                                // would linger in the game window. Remove it ourselves.
                                UIView *rescuedView = pvc.view;
                                __weak UIViewController *weakPresenter = w.rootViewController;
                                __weak UIView *weakRescued = rescuedView;
                                NSTimer *janitor = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                                    if(!weakPresenter) { [t invalidate]; return; }
                                    if(!weakPresenter.presentedViewController) {
                                        [weakRescued removeFromSuperview];
                                        [t invalidate];
                                    }
                                }];
                                [NSRunLoop.mainRunLoop addTimer:janitor forMode:NSRunLoopCommonModes];
                            }
                        }
                    } @catch(NSException *e) {
                        fprintf(pf, "  rescue threw: %s %s\n", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "?");
                    }
                    fclose(pf);
                });
            }] forControlEvents:UIControlEventTouchUpInside];
            // Capsule hover shape — the default rectangular highlight looks wrong on the pill.
            b3d.hoverStyle = [UIHoverStyle styleWithEffect:[UIHoverAutomaticEffect effect] shape:[UIShape capsuleShape]];
            bGear.hoverStyle = [UIHoverStyle styleWithEffect:[UIHoverAutomaticEffect effect] shape:[UIShape capsuleShape]];
            [vc.view addSubview:b3d];
            [vc.view addSubview:bGear];
            void *handle = add(vc, 180, 52, 16);
            // Geometry forensics: the content has rendered mangled two builds in a row
            // (collapsed buttons, drifting titles). Dump the backing window's real view
            // tree — frames, bounds, transforms — 6s after registration, once MRUI has done
            // whatever late layout it does.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if(!handle) return;
                UIWindow *bw = ((UIWindow *(*)(id, SEL))objc_msgSend)((__bridge id)handle, NSSelectorFromString(@"_window"));
                if(!bw) return;
                NSString *treePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-orn-tree.log"];
                FILE *tf = fopen(treePath.fileSystemRepresentation, "a");
                if(!tf) return;
                fprintf(tf, "===== ORNAMENT TREE t=%.3f window=%s =====\n",
                        CFAbsoluteTimeGetCurrent(), NSStringFromCGRect(bw.frame).UTF8String);
                LCOrnDumpTree(bw, 0, tf);
                fclose(tf);
            });
        });
    });
#endif
#if LC_MRUI_GUEST_DIAG
    // MRUI STATE DUMP (temporary): capture guest-side entity-backing state once the UI is up,
    // then inject the test ornament and re-dump to record what registration changed.
    static dispatch_once_t lcMruiDumpOnce;
    dispatch_once(&lcMruiDumpOnce, ^{
        NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/lc-mrui-guest.log"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCMRUIDumpAll(@"guest", logPath);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCMRUIInjectTestOrnament(logPath);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCMRUIDumpAll(@"guest-postinject", logPath);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            LCMRUIOrnamentStatus(logPath);
        });
    });
#endif
#endif
#if !TARGET_OS_MACCATALYST
    NSString* decodedUrlStr = launchURLProcessed ? nil : NSUserDefaults.lcLaunchURL;
    launchURLProcessed = YES;
    NSString* urlStr;
        
    if(!decodedUrlStr && context.payload && (urlStr = context.payload[UIApplicationLaunchOptionsURLKey])) {
        do {
            if([urlStr hasPrefix:[NSString stringWithFormat: @"%@://open-url", NSUserDefaults.lcAppUrlScheme]]) {
                NSURLComponents* lcUrl = [NSURLComponents componentsWithString:urlStr];
                NSString* realUrlEncoded = lcUrl.queryItems[0].value;
                if(!realUrlEncoded) break;
                // Convert the base64 encoded url into String
                NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:realUrlEncoded options:0];
                decodedUrlStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
            } else if([urlStr hasPrefix:NSUserDefaults.lcAppUrlScheme]) {
                context.payload = nil;
                context.actions = nil;
            }
        } while (0);
    }
    
    do {
        if(!decodedUrlStr) break;
        NSURL* decodedUrl = [NSURL URLWithString:decodedUrlStr];
        if(decodedUrl.isFileURL) {
            resolveLaunchExtensionFileBookmark();
        }
        
        NSMutableDictionary* newDict = [context.payload mutableCopy];
        if(!newDict) newDict = [NSMutableDictionary new];
        newDict[UIApplicationLaunchOptionsURLKey] = decodedUrlStr;
        context.payload = newDict;
        
        
        UIOpenURLAction *urlAction = nil;
        for (id obj in context.actions.allObjects) {
            if ([obj isKindOfClass:UIOpenURLAction.class]) {
                urlAction = obj;
                break;
            }
        }
        
        NSMutableSet *newActions = context.actions.mutableCopy;
        if(newActions && urlAction) {
            [newActions removeObject:urlAction];
        }
        if(!newActions) newActions = [NSMutableSet new];
        
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:decodedUrl];
        [newActions addObject:newUrlAction];
        context.actions = newActions;
        
    } while(0);
    
#endif
    [self hook__connectUISceneFromFBSScene:scene transitionContext:context];
}

-(BOOL)hook__handleDelegateCallbacksWithOptions:(id)arg1 isSuspended:(BOOL)arg2 restoreState:(BOOL)arg3 {
    BOOL ans = [self hook__handleDelegateCallbacksWithOptions:arg1 isSuspended:arg2 restoreState:arg3];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:@"com.apple.springboard"];
            [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:NSUserDefaults.lcMainBundle.bundleIdentifier];
        });

    });


    return ans;
}

- (void)hook_openURL:(NSURL *)url options:(NSDictionary<NSString *,id> *)options completionHandler:(void (^)(_Bool))completion {
    if(NSUserDefaults.isSideStore && ![url.scheme isEqualToString:@"livecontainer"]) {
        [self hook_openURL:url options:options completionHandler:completion];
        return;
    }
    
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);;
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
- (BOOL)hook_canOpenURL:(NSURL *) url {
    return canAppOpenItself(url) || shouldRedirectOpenURLToHost(url) || [self hook_canOpenURL:url];
}

- (void)hook_setDelegate:(id<UIApplicationDelegate>)delegate {
    if(![delegate respondsToSelector:@selector(application:configurationForConnectingSceneSession:options:)]) {
        // Fix old apps black screen when UIApplicationSupportsMultipleScenes is YES
        swizzle(UIWindow.class, @selector(makeKeyAndVisible), @selector(hook_makeKeyAndVisible));
        swizzle(UIWindow.class, @selector(makeKeyWindow), @selector(hook_makeKeyWindow));
        swizzle(UIWindow.class, @selector(setHidden:), @selector(hook_setHidden:));
        // Fix apps that do not support UISceneDelegate getting 0 status bar frame
        swizzle(UIApplication.class, @selector(statusBarFrame), @selector(hook_statusBarFrame));
    }
    [self hook_setDelegate:delegate];
}

+ (BOOL)_wantsApplicationBehaviorAsExtension {
    // Fix LiveProcess: Make _UIApplicationWantsExtensionBehavior return NO so delegate code runs in the run loop
    return YES;
}

- (CGRect)hook_statusBarFrame {
    UIStatusBarManager* manager = [(UIWindowScene*)(UIApplication.sharedApplication.connectedScenes.anyObject) statusBarManager];
    if(manager) {
        return manager.statusBarFrame;
    } else {
        return [self hook_statusBarFrame];
    }
}

@end

// Handler for SceneDelegate
@implementation UIScene(LiveContainerHook)
- (void)hook_scene:(id)scene didReceiveActions:(NSSet *)actions fromTransitionContext:(id)context {
    UIOpenURLAction *urlAction = nil;
    for (id obj in actions.allObjects) {
        if ([obj isKindOfClass:UIOpenURLAction.class]) {
            urlAction = obj;
            break;
        }
    }

    if(!urlAction) {
        [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
        return;
    }
    NSString* replacementURLString = nil;
    LCControlAppURLHandling decision = LCHandleControlAppURL(urlAction.url, &replacementURLString);
    if(decision == LCControlAppURLHandlingStop) {
        return;
    }
    if(decision == LCControlAppURLHandlingReplaceURL) {
        NSURL* finalURL = [NSURL URLWithString:replacementURLString];
        if(!finalURL) {
            return;
        }
        NSMutableSet *newActions = actions.mutableCopy;
        [newActions removeObject:urlAction];
        UIOpenURLAction *newUrlAction = [[UIOpenURLAction alloc] initWithURL:finalURL];
        [newActions addObject:newUrlAction];
        [self hook_scene:scene didReceiveActions:newActions fromTransitionContext:context];
        return;
    }
    [self hook_scene:scene didReceiveActions:actions fromTransitionContext:context];
}

- (void)hook_openURL:(NSURL *)url options:(UISceneOpenExternalURLOptions *)options completionHandler:(void (^)(BOOL success))completion {
    BOOL openSelf = canAppOpenItself(url);
    BOOL redirectToHost = shouldRedirectOpenURLToHost(url);
    if(openSelf || redirectToHost) {
        NSString* schemeToUse = openSelf ? NSUserDefaults.lcAppUrlScheme : @"livecontainer";
        NSData *data = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encodedUrl = [data base64EncodedStringWithOptions:0];
        NSString* finalUrlStr = [NSString stringWithFormat:@"%@://open-url?url=%@", schemeToUse, encodedUrl];
        NSURL* finalUrl = [NSURL URLWithString:finalUrlStr];
        [self hook_openURL:finalUrl options:options completionHandler:completion];
    } else {
        [self hook_openURL:url options:options completionHandler:completion];
    }
}
@end

@implementation FBSSceneParameters(LiveContainerHook)
- (instancetype)hook_initWithXPCDictionary:(NSDictionary*)dict {

    FBSSceneParameters* ans = [self hook_initWithXPCDictionary:dict];
    UIMutableApplicationSceneSettings* settings = [ans.settings mutableCopy];
    UIMutableApplicationSceneClientSettings* clientSettings = [ans.clientSettings mutableCopy];
    [settings setInterfaceOrientation:LCOrientationLock];
    [clientSettings setInterfaceOrientation:LCOrientationLock];
    ans.settings = settings;
    ans.clientSettings = clientSettings;
    return ans;
}
@end



@implementation UIViewController(LiveContainerHook)

- (UIInterfaceOrientationMask)hook___supportedInterfaceOrientations {
    if(LCOrientationLock == UIInterfaceOrientationLandscapeRight) {
        return UIInterfaceOrientationMaskLandscape;
    } else {
        return UIInterfaceOrientationMaskPortrait;
    }

}

- (BOOL)hook_shouldAutorotateToInterfaceOrientation:(NSInteger)orientation {
    return YES;
}

@end

@implementation UIWindow(hook)
- (void)hook_setAutorotates:(BOOL)autorotates forceUpdateInterfaceOrientation:(BOOL)force {
    [self hook_setAutorotates:YES forceUpdateInterfaceOrientation:YES];
}

#if TARGET_OS_VISION
- (UITraitCollection *)hook_lc_traitCollection {
    static __thread int reentrancyDepth = 0;
    if(reentrancyDepth > 0) {
        // Reentrant read from inside this window's own trait computation (MRUIKit's
        // entity-backing check). Recomputing here is what recurses; instead answer with the
        // window scene's trait collection — a fully-formed, non-recursive value that reflects
        // the real (entity-backed) environment, falling back to the current thread traits.
        // Never call through to the original here or the recursion resumes.
        return self.windowScene.traitCollection ?: UITraitCollection.currentTraitCollection;
    }
    reentrancyDepth++;
    UITraitCollection *ans = [self hook_lc_traitCollection];
    reentrancyDepth--;
    return ans;
}
#endif

- (void)hook_makeKeyAndVisible {
    [self updateWindowScene];
    [self hook_makeKeyAndVisible];
}
- (void)hook_makeKeyWindow {
    [self updateWindowScene];
    [self hook_makeKeyWindow];
}
- (void)hook_resignKeyWindow {
    [self updateWindowScene];
    [self hook_resignKeyWindow];
}
- (void)hook_setHidden:(BOOL)hidden {
    [self updateWindowScene];
    [self hook_setHidden:hidden];
}
- (void)updateWindowScene {
    if(self.windowScene) return;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
#if !TARGET_OS_VISION
        // Adopt the scene sitting on the same display as this window. visionOS has
        // no `screen` (unavailable in that SDK) and no multi-display concept to
        // disambiguate with, so there the first window scene is the right one.
        if(self.screen != windowScene.screen) continue;
#endif
        self.windowScene = windowScene;
        break;
    }
}
@end
