import AppKit
import Combine
import Foundation
import SwiftUI

enum ApplicationStartupError: LocalizedError {
    case storageUnavailable(section: String)

    var errorDescription: String? {
        switch self {
        case let .storageUnavailable(section):
            "无法打开\(section)。请检查 SkillBox 资料文件夹是否可读写、是否有同名文件占用，再点击重试。"
        }
    }
}

@MainActor
final class ApplicationStartup: ObservableObject {
    @Published private(set) var model: AppModel?
    @Published private(set) var errorMessage: String?
    let libraryRoot: URL
    private let createModel: @MainActor () throws -> AppModel

    init(libraryRoot: URL? = nil, createModel: (@MainActor () throws -> AppModel)? = nil) {
        let root = libraryRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SkillBox")
        self.libraryRoot = root
        self.createModel = createModel ?? { try AppModel(libraryRoot: root) }
        start()
    }

    func start() {
        guard model == nil else { return }
        errorMessage = nil
        do { model = try createModel() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct ApplicationStartupRecoveryView: View {
    @ObservedObject var startup: ApplicationStartup

    var body: some View {
        ContentUnavailableView {
            Label("资料暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(startup.errorMessage ?? "请检查本机资料文件夹后重试。")
        } actions: {
            Button("在访达查看资料文件夹") {
                NSWorkspace.shared.activateFileViewerSelecting([startup.libraryRoot])
            }
            Button("重试") { startup.start() }
                .keyboardShortcut(.defaultAction)
        }
        .containerBackground(.white, for: .window)
        .preferredColorScheme(.light)
    }
}
