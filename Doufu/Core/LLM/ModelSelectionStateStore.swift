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
    private var dataServices: [String: ChatDataService] = [:]

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
        await shared.loadProjectDefaultSelection(projectID: projectID)
    }

    static func currentThreadSelection(projectID: String) async -> ModelSelection? {
        await shared.loadCurrentThreadSelection(projectID: projectID)
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

    func loadProjectDefaultSelection(projectID: String) async -> ModelSelection? {
        var state = projectStates[projectID] ?? ProjectState()
        if !state.didLoadProjectDefault {
            state.projectDefault = await dataService(for: projectID).loadProjectModelSelection()
            state.didLoadProjectDefault = true
            projectStates[projectID] = state
        }
        return state.projectDefault
    }

    func loadThreadSelection(projectID: String, threadID: String) async -> ModelSelection? {
        var state = projectStates[projectID] ?? ProjectState()
        if !state.loadedThreadIDs.contains(threadID) {
            let selection = await dataService(for: projectID).loadModelSelection(threadID: threadID)
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

    func loadCurrentThreadSelection(projectID: String) async -> ModelSelection? {
        await dataService(for: projectID).loadCurrentModelSelection()
    }

    func loadSnapshot(projectID: String, threadID: String?) async -> Snapshot {
        let appDefault = loadAppDefaultSelection()
        let projectDefault = await loadProjectDefaultSelection(projectID: projectID)
        let threadSelection: ModelSelection?
        if let threadID {
            threadSelection = await loadThreadSelection(projectID: projectID, threadID: threadID)
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
        dataService(for: projectID).persistProjectModelSelection(selection)
        if didChange {
            postChange(.init(scope: .projectDefault(projectID: projectID)))
        }
    }

    func setProjectDefaultSelectionAsync(_ selection: ModelSelection?, projectID: String) async {
        let didChange = cacheProjectDefaultSelection(selection, projectID: projectID)
        if didChange {
            postChange(.init(scope: .projectDefault(projectID: projectID)))
        }
        await dataService(for: projectID).persistProjectModelSelectionAsync(selection)
    }

    func setThreadSelection(_ selection: ModelSelection?, projectID: String, threadID: String) {
        let didChange = cacheThreadSelection(selection, projectID: projectID, threadID: threadID)
        if let selection {
            dataService(for: projectID).persistModelSelection(selection, threadID: threadID)
        } else {
            dataService(for: projectID).removeModelSelection(threadID: threadID)
        }
        if didChange {
            postChange(.init(scope: .threadSelection(projectID: projectID, threadID: threadID)))
        }
    }

    func setThreadSelectionAsync(_ selection: ModelSelection?, projectID: String, threadID: String) async {
        let didChange = cacheThreadSelection(selection, projectID: projectID, threadID: threadID)
        if didChange {
            postChange(.init(scope: .threadSelection(projectID: projectID, threadID: threadID)))
        }
        if let selection {
            await dataService(for: projectID).persistModelSelectionAsync(selection, threadID: threadID)
        } else {
            await dataService(for: projectID).removeModelSelectionAsync(threadID: threadID)
        }
    }

    private func dataService(for projectID: String) -> ChatDataService {
        if let existing = dataServices[projectID] {
            return existing
        }
        let service = ChatDataService(projectID: projectID)
        dataServices[projectID] = service
        return service
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
