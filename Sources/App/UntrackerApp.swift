//
//  UntrackerApp.swift
//  Untracker for iOS
//
//  An iOS counterpart to zhanghai/Untracker: remove tracking information from
//  links — from the share sheet, or by pasting it here.
//

import SwiftUI
import UIKit

@main
struct UntrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = RuleStore.shared
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(appState)
                .tint(Theme.accent)
                .onOpenURL { url in
                    appState.handle(url: url)
                }
        }
    }
}

// MARK: - Home screen quick actions

enum Shortcuts {
    /// "Paste & Untrack" — clipboard → cleaned link.
    static let pasteAndUntrack = "moe.mgt.untracker.paste"
    /// Jump to the rule list.
    static let rules = "moe.mgt.untracker.rules"
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Home-screen quick action. SwiftUI's scene delegate does not implement
    /// `windowScene(_:performActionFor:)`, so UIKit delivers the action here.
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        AppState.shared.perform(shortcutType: shortcutItem.type)
        completionHandler(true)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        AppState.shared.handle(url: url)
        return true
    }
}

// MARK: - Tabs

enum AppTab: Hashable {
    case untrack
    case rules
    case about
}

// MARK: - App state

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedTab: AppTab = .untrack
    /// Text to pre-load into the home screen (quick action or `untracker://` URL).
    @Published var pendingInput: String?
    @Published var selfTestSummary: String?
    @Published var isRunningSelfTest = false

    private init() {}

    func perform(shortcutType: String) {
        switch shortcutType {
        case Shortcuts.pasteAndUntrack:
            selectedTab = .untrack
            if let string = UIPasteboard.general.string, !string.isEmpty {
                pendingInput = string
            }
        case Shortcuts.rules:
            selectedTab = .rules
        default:
            break
        }
    }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "untracker" else { return }
        switch url.host?.lowercased() ?? "" {
        case "untrack":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let value = components?.queryItems?.first(where: { $0.name == "url" })?.value {
                selectedTab = .untrack
                pendingInput = value
            }
        case "selftest":
            runSelfTest()
        default:
            break
        }
    }

    func runSelfTest() {
        guard !isRunningSelfTest else { return }
        isRunningSelfTest = true
        let rules = RuleStore.shared.allRules
        Task.detached(priority: .userInitiated) {
            let report = SelfTest.runAndWriteReport()
            let total = report["total"] as? Int ?? 0
            let passed = report["passed"] as? Int ?? 0
            let failed = report["failed"] as? Int ?? 0
            let probeOK = (report["engineProbe"] as? [String: Any])?["ok"] as? Bool ?? false
            let shared = SharedStore.canShareAcrossProcesses ? "yes" : "no"
            var summary = String(
                format: "Self test: %d/%d passed, %d failed. %d rules. Cross-process storage: %@.",
                passed,
                total,
                failed,
                rules.count,
                shared
            )
            if !probeOK {
                summary += " Engine probe FAILED."
            }
            NSLog("[Untracker] Self test finished: %d/%d", passed, total)
            await MainActor.run {
                self.selfTestSummary = total > 0 ? summary : "Self test cases were not bundled."
                self.isRunningSelfTest = false
            }
        }
    }
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            HomeView()
                .tabItem { Label("Untrack", systemImage: "wand.and.stars") }
                .tag(AppTab.untrack)

            RulesView()
                .tabItem { Label("Rules", systemImage: "slider.horizontal.3") }
                .tag(AppTab.rules)

            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(AppTab.about)
        }
        .overlay(alignment: .bottom) {
            if appState.isRunningSelfTest {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running self test…")
                        .font(.footnote)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 60)
            }
        }
        .onAppear {
            // Automation hook: `simctl launch … --run-selftest` /
            // `devicectl device process launch … -- --run-selftest`.
            if ProcessInfo.processInfo.arguments.contains("--run-selftest") {
                appState.runSelfTest()
            }
        }
    }
}
