//
//  ChatMenuBuilder.swift
//  Doufu
//

import UIKit

struct ChatMenuBuilder {

    static func threadMenu(
        threads: [ProjectChatThreadRecord],
        currentThreadID: String?,
        onSwitch: @escaping (String) -> Void,
        onCreate: @escaping () -> Void,
        onManage: @escaping () -> Void
    ) -> UIMenu {
        let threadActions: [UIMenuElement]
        if !threads.isEmpty {
            threadActions = threads.map { thread in
                UIAction(
                    title: thread.title,
                    state: thread.id == currentThreadID ? .on : .off
                ) { _ in
                    onSwitch(thread.id)
                }
            }
        } else {
            threadActions = [
                UIAction(title: String(localized: "chat.menu.no_thread"), attributes: .disabled) { _ in }
            ]
        }

        let createAction = UIAction(
            title: String(localized: "chat.menu.new_thread"),
            image: UIImage(systemName: "plus")
        ) { _ in
            onCreate()
        }
        let manageAction = UIAction(
            title: String(localized: "chat.menu.manage_threads"),
            image: UIImage(systemName: "list.bullet")
        ) { _ in
            onManage()
        }
        let actionsSubmenu = UIMenu(title: "", options: .displayInline, children: [createAction, manageAction])
        return UIMenu(title: String(localized: "chat.thread.button_title"), children: threadActions + [actionsSubmenu])
    }

    static func moreMenu(
        isExecuting: Bool = false,
        onFiles: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> UIMenu {
        let filesAction = UIAction(
            title: String(localized: "workspace.panel.files"),
            image: UIImage(systemName: "folder"),
            attributes: isExecuting ? .disabled : []
        ) { _ in
            onFiles()
        }
        let settingsAction = UIAction(
            title: String(localized: "workspace.panel.settings"),
            image: UIImage(systemName: "gearshape"),
            attributes: isExecuting ? .disabled : []
        ) { _ in
            onSettings()
        }
        let closeAction = UIAction(
            title: String(localized: "common.action.close"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { _ in
            onClose()
        }
        return UIMenu(children: [filesAction, settingsAction, closeAction])
    }
}
