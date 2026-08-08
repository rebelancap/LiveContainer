#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
@import MachO;
#import <notify.h>
#import <objc/message.h>

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

@implementation LCSharedUtils

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        // A binary signed without that entitlement (an app extension is easy to miss)
        // gets NULL back, and CFGetTypeID(NULL) dereferences it — crashing at launch
        // before the keychain fallback below ever gets a chance to run.
        if(cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        CFRelease(taskSelf);
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            NSString *tempAccountName = @"bundleSeedID";
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        NSArray* possibleAppGroups = @[
            [@"group.com.SideStore.SideStore." stringByAppendingString:[self teamIdentifier]],
            [@"group.com.rileytestut.AltStore." stringByAppendingString:[self teamIdentifier]]
        ];
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        CFRelease(taskSelf);
        
        if(!value) {
            return;
        }
        NSArray* appGroups = (__bridge NSArray *)value;
        if(appGroups.count > 0) {
            appGroupID = [appGroups firstObject];
        }
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
    });
    return appGroupPath;
}

+ (NSString *)certificatePassword {
    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
    return [nud objectForKey:@"LCCertificatePassword"];
}

+ (BOOL)launchToGuestApp {
    NSString *urlScheme = nil;
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
    
    int tries = 1;
    if (!self.certificatePassword) {
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        } else if ([application canOpenURL:[NSURL URLWithString:@"stikjit://"]]) {
            urlScheme = @"stikjit://enable-jit?bundle-id=%@";
        } else if ([application canOpenURL:[NSURL URLWithString:@"sidestore://"]]) {
            urlScheme = @"sidestore://sidejit-enable?bid=%@";
        }
    }
    if (!urlScheme) {
        tries = 2;
        urlScheme = [NSString stringWithFormat:@"%@://livecontainer-relaunch", lcAppUrlScheme];
    }
    NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];

#if TARGET_OS_VISION
    // visionOS: FrontBoard does NOT relaunch a dead app to deliver a pending URL
    // (iOS kill-in-completion and suspend-then-die verified dead on-device
    // 2026-08-07), and an extension proxy dies with its host before it can act
    // (verified 2026-08-08). The only process that can reopen us is another APP —
    // a sibling LiveContainer install relays the relaunch.
    [self relaunchViaSiblingThenExit];
    return YES;
#endif
    if ([application canOpenURL:launchURL]) {
        //[UIApplication.sharedApplication suspend];
        for (int i = 0; i < tries; i++) {
            [application openURL:launchURL options:@{} completionHandler:^(BOOL b) {
                // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
                __asm__ __volatile__ (
                    "mov x0, #31\n"
                    "mov x16, #26\n"
                    "svc #0x80\n"
                );
                raise(SIGKILL);
            }];
        }
        return YES;
    } else {
        // none of the ways work somehow (e.g. LC itself was hidden), we just exit and wait for user to manually launch it
        exit(0);
    }
    return NO;
}

#if TARGET_OS_VISION
// Relaunch by SIBLING: hand the relaunch to another installed LiveContainer
// (livecontainer2/3 — an APP, whose lifetime is independent of ours), then die.
// The sibling polls our pid, and once we're gone reopens us by bundle id; the
// fresh process boots per lcUserDefaults["selected"] — the guest for a RUN
// handoff, the UI when the guest quit (LCGuestQuitToLC resets selected to "ui"
// and synchronizes BEFORE this runs, so _exit is safe). Receiver:
// LCTabView.dispatchURL, host "lc-relay-relaunch".
// Everything in-process is a verified dead end on this platform: FrontBoard
// won't resurrect a dead app for a pending URL (2026-08-07), and ANY extension
// we spawn is SIGKILLed within ~100ms of our death, straight through a granted
// performExpiringActivity window (2026-08-08). Only an app can outlive us.
+ (void)relaunchMark:(NSString *)stage {
    const char *lcHome = getenv("LC_HOME_PATH") ?: getenv("HOME");
    if(!lcHome) return;
    char p[1024];
    snprintf(p, sizeof p, "%s/Documents/lc-exit-relaunch.log", lcHome);
    FILE *f = fopen(p, "a");
    if(f) { fprintf(f, "%.3f SharedUtils: %s\n", CFAbsoluteTimeGetCurrent(), stage.UTF8String); fclose(f); }
}

+ (void)relaunchViaSiblingThenExit {
    NSString *lcBundleId = lcMainBundle.bundleIdentifier ?: NSBundle.mainBundle.bundleIdentifier;
    NSString *ownScheme = lcAppUrlScheme ?: @"livecontainer";
    LSApplicationWorkspace *workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];

    NSURL *relayURL = nil;
    for(NSString *scheme in [self lcUrlSchemes]) {
        if([scheme isEqualToString:ownScheme]) continue;
        // Not canOpenURL: — that gates on our Info.plist query schemes, which a
        // guest's swapped plist doesn't have. This workspace probe has no gate.
        NSURL *probe = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", scheme]];
        NSError *err = nil;
        if(![workspace isApplicationAvailableToOpenURL:probe error:&err]) continue;
        relayURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@://lc-relay-relaunch?pid=%d&target=%@",
                                         scheme, getpid(), lcBundleId]];
        break;
    }
    if(!relayURL) {
        [self relaunchMark:@"no sibling LC installed — plain exit; next manual launch honors `selected`"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        return;
    }
    // Pre-announce over Darwin state so the sibling's BOOTSTRAP handles the relay
    // before its UI exists (no window flash; LCBootstrap
    // LCVisionRelayRelaunchIfRequested). The URL open below is then only the
    // launch trigger — and the sibling's UI handler is the fallback if the state
    // goes stale before delivery. state = (our pid << 8) | own-scheme index.
    NSString *team = [self teamIdentifier] ?: @"lc";
    NSUInteger schemeIdx = [[self lcUnorderedUrlSchemes] indexOfObject:ownScheme];
    if(schemeIdx == NSNotFound) schemeIdx = 0;
    int stateToken = 0, timeToken = 0;
    notify_register_check([NSString stringWithFormat:@"%@.lcrelay.state", team].UTF8String, &stateToken);
    notify_register_check([NSString stringWithFormat:@"%@.lcrelay.time", team].UTF8String, &timeToken);
    notify_set_state(stateToken, ((uint64_t)getpid() << 8) | (uint64_t)(schemeIdx & 0xFF));
    notify_set_state(timeToken, (uint64_t)time(NULL));

    BOOL ok = [workspace openURL:relayURL];
    [self relaunchMark:[NSString stringWithFormat:@"relay open %@ -> %d", relayURL.absoluteString, ok]];
    // Give lsd/FrontBoard a beat to commit the open, then die. No handshake
    // needed: the sibling acts on our pid's ESRCH, however and whenever we exit.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ _exit(0); });
}
#endif

+ (BOOL)openApplicationWithBundleID:(NSString*)bundleId {
    return [[PrivClass(LSApplicationWorkspace) defaultWorkspace] openApplicationWithBundleID:bundleId];
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        return [self launchToGuestApp];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (!appUsageInfo) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like livecontainer or livecontainer2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"LiveContainer was unable to move the data of shared app back because LiveContainer cannot access app group. Please check JITLess diagnose page in LiveContainer settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle) {
            *isSharedAppOut = true;
        }
    } else {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"livecontainer", @"livecontainer2", @"livecontainer3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }

    return result;
}
@end
