import SwiftUI
import AppKit
import ServiceManagement

@MainActor
enum AppGlobals {
    static let viewModel = ContainerViewModel()
}


class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon
        NSApp.setActivationPolicy(.accessory)
        AppGlobals.viewModel.startPolling(interval: 5)
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.post(name: Notification.Name("AppWillTerminate"), object: nil)
    }
    
    
    private func updateActivationPolicyIfNeeded() {
        // Defer to next runloop to ensure window state is updated
        DispatchQueue.main.async {
            let hasVisibleWindows = NSApp.windows.contains { window in
                // Only consider normal app windows that are actually visible on screen
                guard window.level == .normal else { return false }
                guard window.isVisible, !window.isMiniaturized, !window.isExcludedFromWindowsMenu else { return false }
                return window.occlusionState.contains(.visible)
            }
            if !hasVisibleWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

@main
struct ContainerStatusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = AppGlobals.viewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some Scene {
        MenuBarExtra {
            VStack {
                Text("\(vm.getRunningContainersAmount()) Containers running")
                Button("Open Container View") {
                    // Promote to regular app so Dock icon appears when showing a window
                    NSApp.setActivationPolicy(.regular)
                        // No existing window, open a new one
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "containerUI")
                }
                Divider()
                vm.isSystemRunning ?  Button("Stop System") { vm.stopSystem() } : Button("Start System") {vm.startSystem()}
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(8)
            .frame(width: 200)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppWillTerminate"), object: nil)) { _ in
                vm.stopPolling()
            }
        } label: {
            (vm.isSystemRunning ? Image(systemName: "shippingbox") : Image(systemName: "stop")).frame(width: 22, height: 22)

        }

        Window("Container", id: "containerUI") {
            ContentView()
            .environmentObject(vm)
        }
    }
}

