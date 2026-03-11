//
//  ModelSelectionStateStore.swift
//  Doufu
//

import Foundation

@MainActor
final class ModelSelectionStateStore {

    static let shared = ModelSelectionStateStore()

    struct Snapshot: Equatable {
        var appDefault: ModelSelection?
        var projectDefault: ModelSelection?
        var threadSelection: ModelSelection?

        init(
            appDefault: ModelSelection? = nil,
            projectDefault: ModelSelection? = nil,
            threadSelection: ModelSelection? = nil
        ) {
            self.appDefault = appDefault
            self.projectDefault = projectDefault
            self.threadSelection = threadSelection
        }
    }

    struct Change: Equatable {
        let scope: Scope
    }

    enum Scope: Equatable {
        case appDefault
        case projectDefault(projectID: String)
        case threadSelection(projectID: String, threadID: String)
    }

    private struct ProjectState {
        var didLoadProjectDefault = false
        var projectDefault: ModelSelection?
        var loadedThreadIDs: Set<String> = []
        var threadSelections: [String: ModelSelection] = [:]
    }

    private static let didChangeNotification = Notification.Name("ModelSelectionStateStore.didChange")
    private static let changeUserInfoKey = "change"

    private let providerStore: LLMProviderSettingsStore

    private var hasLoadedAppDefault = false
    private var appDefault: ModelSelection?
    private var projectStates: [String: ProjectState] = [:]

    init(providerStore: LLMProviderSettingsStore? = nil) {
        self.providerStore = providerStore ?? .shared
    }

    static func appDefaultSelection() async -> ModelSelection? {
        shared.loadAppDefaultSelection()
    }

    static func projectDefaultSelection(projectID: String) async -> ModelSelection? {
        shared.loadProjectDefaultSelection(projectID: projectID)
    }

    static func currentThreadSelection(projectID: String) async -> ModelSelection? {
        // Without ChatDataStore, we can't resolve the "current" thread here.
        // Callers should use loadThreadSelection with an explicit threadID.
        nil
    }

    func addObserver(using handler: @escaping (Change) -> Void) -> NSObjectProtocol {
        let changeUserInfoKey = Self.changeUserInfoKey
        return NotificationCenter.default.addObserver(
            forName: Self.didChangeNotification,
            object: self,
            queue: .main
        ) { notification in
            guard let change = notification.userInfo?[changeUserInfoKey] as? Change else {
                return
            }
            handler(change)
        }
    }

    func loadAppDefaultSelection() -> ModelSelection? {
        if !hasLoadedAppDefault {
            appDefault = providerStore.loadDefaultModelSelection()
            hasLoadedAppDefault = true
        }
        return appDefault
    }

    func loadProjectDefaultSelection(projectID: String) -> ModelSelection? {
        var state = projectStates[projectID] ?? ProjectState()
        if !state.didLoadProjectDefault {
            state.projectDefault = providerStore.loadProjectModelSelection(projectID: projectID)
            state.didLoadProjectDefault = true
            projectStates[projectID] = state
        }
        return state.projectDefault
    }

    func loadThreadSelection(projectID: String, threadID: String) -> ModelSelection? {
        var state = projectStates[projectID] ?? ProjectState()
        if !state.loadedThreadIDs.contains(threadID) {
            let selection = providerStore.loadThreadModelSelection(projectID: projectID, threadID: threadID)
            state.loadedThreadIDs.insert(threadID)
            if let selection {
                state.threadSelections[threadID] = selection
            } else {
                state.threadSelections.removeValue(forKey: threadID)
            }
            projectStates[projectID] = state
        }
        return state.threadSelections[threadID]
    }

    func loadSnapshot(projectID: String, threadID: String?) -> Snapshot {
        let appDefault = loadAppDefaultSelection()
        let projectDefault = loadProjectDefaultSelection(projectID: projectID)
        let threadSelection: ModelSelection?
        if let threadID {
            threadSelection = loadThreadSelection(projectID: projectID, threadID: threadID)
        } else {
            threadSelection = nil
        }
        return Snapshot(
            appDefault: appDefault,
            projectDefault: projectDefault,
            threadSelection: threadSelection
        )
    }

    func setAppDefaultSelection(_ selection: ModelSelection?) {
        let didChange = !hasLoadedAppDefault || appDefault != selection
        hasLoadedAppDefault = true
        appDefault = selection

        if let selection {
            providerStore.saveDefaultModelSelection(selection)
        } else {
            providerStore.clearDefaultModelSelection()
        }

        if didChange {
            postChange(.init(scope: .appDefault))
        }
    }

    func setProjectDefaultSelection(_ selection: ModelSelection?, projectID: String) {
        let didChange = cacheProjectDefaultSelection(selection, projectID: projectID)
        providerStore.saveProjectModelSelection(selection, projectID: projectID)
        if didChange {
            AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectID)
            postChange(.init(scope: .projectDefault(projectID: projectID)))
        }
    }

    func setProjectDefaultSelectionAsync(_ selection: ModelSelection?, projectID: String) {
        let didChange = cacheProjectDefaultSelection(selection, projectID: projectID)
        if didChange {
            AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectID)
            postChange(.init(scope: .projectDefault(projectID: projectID)))
        }
        providerStore.saveProjectModelSelection(selection, projectID: projectID)
    }

    func setThreadSelection(_ selection: ModelSelection?, projectID: String, threadID: String) {
        let didChange = cacheThreadSelection(selection, projectID: projectID, threadID: threadID)
        providerStore.saveThreadModelSelection(selection, projectID: projectID, threadID: threadID)
        if didChange {
            postChange(.init(scope: .threadSelection(projectID: projectID, threadID: threadID)))
        }
    }

    func setThreadSelectionAsync(_ selection: ModelSelection?, projectID: String, threadID: String) {
        let didChange = cacheThreadSelection(selection, projectID: projectID, threadID: threadID)
        if didChange {
            postChange(.init(scope: .threadSelection(projectID: projectID, threadID: threadID)))
        }
        providerStore.saveThreadModelSelection(selection, projectID: projectID, threadID: threadID)
    }

    @discardableResult
    private func cacheProjectDefaultSelection(_ selection: ModelSelection?, projectID: String) -> Bool {
        var state = projectStates[projectID] ?? ProjectState()
        let didChange = !state.didLoadProjectDefault || state.projectDefault != selection
        state.didLoadProjectDefault = true
        state.projectDefault = selection
        projectStates[projectID] = state
        return didChange
    }

    @discardableResult
    private func cacheThreadSelection(_ selection: ModelSelection?, projectID: String, threadID: String) -> Bool {
        var state = projectStates[projectID] ?? ProjectState()
        let hadLoadedValue = state.loadedThreadIDs.contains(threadID)
        let previous = state.threadSelections[threadID]
        let didChange = !hadLoadedValue || previous != selection

        state.loadedThreadIDs.insert(threadID)
        if let selection {
            state.threadSelections[threadID] = selection
        } else {
            state.threadSelections.removeValue(forKey: threadID)
        }
        projectStates[projectID] = state
        return didChange
    }

    private func postChange(_ change: Change) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changeUserInfoKey: change]
        )
    }
}
