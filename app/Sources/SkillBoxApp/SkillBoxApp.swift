import SkillBoxCore
import SwiftUI

@main
struct SkillBoxApplication: App {
    @StateObject private var startup = ApplicationStartup()
    @StateObject private var updater = ApplicationUpdater()
    @NSApplicationDelegateAdaptor(SkillBoxApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        Window("SkillBox", id: "main") {
            Group {
                if let model = startup.model {
                    ContentView(model: model)
                        .environmentObject(updater)
                        .task {
                            updater.canRestart = { [weak model] in model?.isBusy == false }
                            appDelegate.canTerminate = { [weak model, weak updater] in
                                updater?.phase != .installing || model?.isBusy == false
                            }
                            updater.start()
                        }
                } else if startup.errorMessage != nil {
                    ApplicationStartupRecoveryView(startup: startup)
                } else {
                    ProgressView("正在打开 SkillBox…")
                        .containerBackground(.white, for: .window)
                        .preferredColorScheme(.light)
                }
            }
            .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { SkillBoxApplicationCommands(updater: updater) }
    }
}

@MainActor
final class SkillBoxApplicationDelegate: NSObject, NSApplicationDelegate {
    var canTerminate: () -> Bool = { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canTerminate() ? .terminateNow : .terminateCancel
    }
}

private struct SkillBoxApplicationCommands: Commands {
    @ObservedObject var updater: ApplicationUpdater
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 SkillBox") {
                openWindow(id: "main")
                updater.showUpdateInFocus()
            }
            Button("检查更新…") {
                openWindow(id: "main")
                updater.checkForUpdates()
            }
        }
    }
}
