import OpenStreamApple
import SwiftUI
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@main
struct OpenStreamPlatformApp: App {
    #if os(iOS) || os(tvOS) || os(visionOS)
    @UIApplicationDelegateAdaptor(OpenStreamAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(OpenStreamMacAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var router = AppleAppRouter()
    @State private var webManagement = AppleWebManagementController()
    @State private var resetGeneration = AppleResetGeneration.shared

    #if DEBUG
    init() {
        // `-OpenStreamDevSources <path>`: read and delete the file first, so
        // the reset below cannot empty it out from under the import.
        AppleDevSourcesImport.captureIfRequested()
        AppleDebugBackupRestore.captureIfRequested()
        // `-OpenStreamResetOnLaunch YES`: Reset OpenStream before any store loads.
        AppleDeviceReset.performIfRequestedAtLaunch()
        #if os(macOS)
        AppleMediaServerBackgroundDownloads.shared.activate()
        #endif
        #if os(macOS)
        // Before any view exists, so a stall early in launch is caught too.
        AppleDebugMainThreadWatchdog.startIfRequested()
        #endif
    }
    #else
    init() {
        #if os(macOS)
        AppleMediaServerBackgroundDownloads.shared.activate()
        #endif
    }
    #endif

    var body: some Scene {
        // Keep eager content: makeContent defers App @State reads off-main and crashes on iOS 27.
        WindowGroup("oStream", content: {
            #if DEBUG && os(tvOS)
            if ProcessInfo.processInfo.arguments.contains("-OpenStreamDebugLiveFixture") {
                AppleLiveGuideFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamInlineLiveFixture") {
                AppleLiveInlineFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamLibraryTitlesFixture") {
                AppleLibraryTitlesDebugView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamContinueWatchingFixture") {
                AppleContinueWatchingDebugView()
            } else {
                platformRoot
            }
            #elseif DEBUG
            if ProcessInfo.processInfo.arguments.contains("-OpenStreamInlineLiveFixture") {
                AppleLiveInlineFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamLibraryTitlesFixture") {
                AppleLibraryTitlesDebugView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamContinueWatchingFixture") {
                AppleContinueWatchingDebugView()
            } else if ProcessInfo.processInfo.arguments.contains("-OpenStreamDownloadFixture") {
                AppleOfflineDownloadDebugView()
            } else {
                platformRoot
            }
            #else
            platformRoot
            #endif
        })
        #if os(visionOS)
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        #endif
        #if os(macOS)
        // Without this the Mac window opens at AppKit's 900 x 450 default,
        // which is smaller than any shape this app's Discover billboard and
        // poster rows were designed for. The Settings pages that read as blank
        // at that size were a separate fault and are fixed at the source now
        // (`AppleSettingsContentModifier`, macOS branch); this is just a
        // sensible opening size for a media app.
        .defaultSize(width: 1280, height: 860)
        .commands { AppleMacMenuCommands() }
        #endif
    }

    @ViewBuilder
    private var platformRoot: some View {
        #if os(tvOS)
            // Mount a focusable hierarchy immediately. Replacing a
            // non-focusable launch overlay after startup can leave the Siri
            // Remote without a default focus candidate.
            OpenStreamRootView(webManagement: webManagement, router: router)
                // Reset OpenStream: a new root, so every store it owns is
                // created again from the emptied storage (no app exit).
                .id(resetGeneration.value)
                .tint(.white)
                .onOpenURL { router.open($0) }
                .onChange(of: resetGeneration.value) { Task { await webManagement.stop() } }
        #else
            ZStack {
                OpenStreamRootView(webManagement: webManagement, router: router)
                    // Reset OpenStream: a new root, so every store it owns is
                    // created again from the emptied storage (no app exit).
                    .id(resetGeneration.value)
                    #if DEBUG && os(iOS)
                    .appleDebugLayoutHost()
                    #endif
            }
            // Brand accent is monochrome — the mark is white bars on black, so
            // controls tint white, not the iOS default blue. Owner feedback:
            // "if there's anything anywhere but OpenStream being blue, remove
            // it." Green toggles stay (system on/off), red stays destructive.
            .tint(.white)
            .onOpenURL { router.open($0) }
            .alert("Channel Lineup", isPresented: Binding(
                get: { router.lineupImportMessage != nil },
                set: { if !$0 { router.lineupImportMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: { Text(router.lineupImportMessage ?? "") }
            .task { router.consumePendingSharedLink() }
            .onChange(of: scenePhase) {
                if scenePhase == .active { router.consumePendingSharedLink() }
            }
            .appleSpotlightContinuation(router)
            .onChange(of: resetGeneration.value) { Task { await webManagement.stop() } }
            .onAppear {
                AppleLaunchMarks.record(.coverGone)
                #if DEBUG
                AppleLaunchClock.mark("launch.cover.hidden")
                #endif
            }
            #if DEBUG
            .task {
                guard AppleAppGroupDiagnostics.isEnabled() else { return }
                AppleAppGroupDiagnostics.emit(AppleAppGroupDiagnostics.run())
            }
            #endif
            #if DEBUG && os(macOS)
            // Renders this window to a PNG and dumps the menu bar, so a macOS
            // screen can be reviewed from a headless session. See
            // `AppleMacWindowShot` for why nothing else works here.
            .task {
                guard let request = AppleMacWindowShot.request() else { return }
                await AppleMacWindowShot.run(request)
            }
            #endif
            #if DEBUG
            .task {
                guard AppleSavedSourceDiagnosticsLaunch.isEnabled() else { return }
                let operations = AppleSavedSourceDiagnosticsProductionOperations(sourceStore: AppleSourceStore())
                let results = await AppleSavedSourceDiagnosticsRunner(operations: operations).run()
                print(AppleSavedSourceDiagnosticsConsole.summary(results))
            }
            #endif
        #endif
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
@MainActor
private final class OpenStreamAppDelegate: NSObject, UIApplicationDelegate {
    #if os(iOS)
    private var backgroundSessionCompletion: (() -> Void)?
    #endif
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if os(iOS)
        AppleProgrammeReminderStore.shared.activateNotifications()
        AppleMediaServerBackgroundDownloads.shared.activate()
        #endif
        AetherSegmentScratch.sweepAtLaunch()
        if AppleMediaServerSignInNotifications.canRegisterForPush { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let handled = await AppleMediaServerSignInNotifications.receive(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppleMediaServerSignInNotifications.registrationFailed()
    }

    #if os(iOS)
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        backgroundSessionCompletion = completionHandler
        AppleMediaServerBackgroundDownloads.shared.handleEvents(identifier: identifier) { [weak self] in
            let completion = self?.backgroundSessionCompletion
            self?.backgroundSessionCompletion = nil
            completion?()
        }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppleOrientationLock.shared.supportedOrientations(
            for: UIDevice.current.userInterfaceIdiom, window: window
        )
    }
    #endif
}
#endif

#if os(macOS)
@MainActor
private final class OpenStreamMacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AetherSegmentScratch.sweepAtLaunch()
        if AppleMediaServerSignInNotifications.canRegisterForPush {
            NSApplication.shared.registerForRemoteNotifications(matching: [])
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await AppleMediaServerSignInNotifications.receive(userInfo) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        AppleMediaServerSignInNotifications.registrationFailed()
    }
}
#endif
