//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

struct LCTabView: View {
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @State var previousSelectedTab : LCTabIdentifier = .apps
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()
    
    @StateObject var searchContextAppList = SearchContext()
    @StateObject var searchContextSource = SearchContext()
    
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    private var appListView: LCAppListView {
        LCAppListView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames, searchContext: searchContextAppList)
    }
    
    private var sourcesView: LCSourcesView {
        LCSourcesView(searchContext: searchContextSource)
    }

    
    var body: some View {
        Group {
            if #available(iOS 19.0, *), SharedModel.isLiquidGlassSearchEnabled {
                TabView(selection: $sharedModel.selectedTab) {
                    if DataManager.shared.model.multiLCStatus != 2 {
                        Tab("lc.tabView.sources".loc, systemImage: "books.vertical", value: LCTabIdentifier.sources) {
                            sourcesView
                        }
                    }
                    Tab("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill", value: LCTabIdentifier.apps) {
                        appListView
                    }
                    if DataManager.shared.model.multiLCStatus != 2 {
                        Tab("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver", value: LCTabIdentifier.tweaks) {
                            LCTweaksView(tweakFolders: $tweakFolderNames)
                        }
                    }
                    Tab("lc.tabView.settings".loc, systemImage: "gearshape.fill", value: LCTabIdentifier.settings) {
                        LCSettingsView(appDataFolderNames: $appDataFolderNames)
                    }
                    Tab("Search".loc, systemImage: "magnifyingglass", value: LCTabIdentifier.search, role: .search) {
                        if previousSelectedTab == .sources {
                            sourcesView
                                .searchable(text: $searchContextSource.query)
                        } else {
                            appListView
                                .searchable(text: $searchContextAppList.query)
                        }

                    }
                }
            } else {
                TabView(selection: $sharedModel.selectedTab) {
                    if DataManager.shared.model.multiLCStatus != 2 {
                        sourcesView
                            .tabItem {
                                Label("lc.tabView.sources".loc, systemImage: "books.vertical")
                            }
                            .tag(LCTabIdentifier.sources)
                    }
                    appListView
                        .tabItem {
                            Label("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill")
                        }
                        .tag(LCTabIdentifier.apps)
                    if DataManager.shared.model.multiLCStatus != 2 {
                        LCTweaksView(tweakFolders: $tweakFolderNames)
                            .tabItem{
                                Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                            }
                            .tag(LCTabIdentifier.tweaks)
                    }
                    
                    LCSettingsView(appDataFolderNames: $appDataFolderNames)
                        .tabItem {
                            Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                        }
                        .tag(LCTabIdentifier.settings)
                }
            }
        }
        .downloadAlert(helper: downloadHelper)
        .environmentObject(downloadHelper)
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("lc.common.copy".loc, action: {
                            copyError()
                        })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onChange(of: sharedModel.selectedTab) { newValue in
            if newValue != LCTabIdentifier.search {
                previousSelectedTab = newValue
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }
    
    func dispatchURL(url: URL) {
#if os(visionOS)
        // Sibling-relay relaunch: a dying LiveContainer install hands us its own
        // relaunch, because nothing in ITS process tree can survive its death
        // (see LCSharedUtils.relaunchViaSiblingThenExit). Wait for the sender to
        // die, reopen it by bundle id, then bow out.
        if url.host?.lowercased() == "lc-relay-relaunch" {
            performRelayRelaunch(url: url)
            return
        }
#endif
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)

        sharedModel.deepLink = url
    }

#if os(visionOS)
    func performRelayRelaunch(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var senderPid: Int32 = 0
        var target: String? = nil
        for item in components.queryItems ?? [] {
            if item.name == "pid" { senderPid = Int32(item.value ?? "") ?? 0 }
            if item.name == "target" { target = item.value }
        }
        // Never relay for ourselves — that's the resurrect-a-dead-app trap this
        // mechanism exists to escape.
        guard senderPid > 0, let target, target != Bundle.main.bundleIdentifier else { return }
        relayMark("relay request: pid=\(senderPid) target=\(target)")
        Task.detached(priority: .userInitiated) {
            var steps = 0 // 50ms each; ESRCH (not EPERM) is the only reliable "gone"
            while !(kill(senderPid, 0) == -1 && errno == ESRCH) && steps < 160 {
                usleep(50000)
                steps += 1
            }
            relayMark(steps < 160 ? "sender gone after \(steps * 50)ms" : "sender STILL alive after 8s — opening anyway")
            usleep(250000)
            for attempt in 1...4 {
                let ok = LCSharedUtils.openApplication(withBundleID: target)
                relayMark("open \(target) attempt \(attempt) -> \(ok)")
                if ok { break }
                usleep(600000)
            }
            // Job done; the target is foreground now. Our death needs no relay.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            exit(0)
        }
    }

    nonisolated func relayMark(_ msg: String) {
        let path = NSHomeDirectory() + "/Documents/lc-relay.log"
        let line = String(format: "%.3f relay[%d]: %@\n", CFAbsoluteTimeGetCurrent(), getpid(), msg)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkBundleId() {
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
