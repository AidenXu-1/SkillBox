import SkillBoxCore
import SwiftUI

@main
struct SkillBoxApplication: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1280, height: 820)
    }
}
