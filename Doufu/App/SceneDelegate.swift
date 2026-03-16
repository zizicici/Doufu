//
//  SceneDelegate.swift
//  Doufu
//
//  Created by Salley Garden on 2026/02/14.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private static let importableExtensions: Set<String> = ["doufu", "doufull"]
    private var openProjectObserver: NSObjectProtocol?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        window = UIWindow(windowScene: windowScene)

        let homeViewController = HomeViewController()
        let navigationController = UINavigationController(rootViewController: homeViewController)
        window?.rootViewController = navigationController
        window?.makeKeyAndVisible()

        // Handle file open on cold launch
        if let url = connectionOptions.urlContexts.first?.url,
           Self.importableExtensions.contains(url.pathExtension.lowercased()) {
            homeViewController.importProjectArchive(from: url)
        }

        // Listen for App Intent navigation requests
        openProjectObserver = NotificationCenter.default.addObserver(
            forName: OpenProjectIntent.openProjectNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let projectID = notification.userInfo?["projectID"] as? String,
                  let homeVC = self?.navigateToHomeViewController() else { return }
            homeVC.openProjectByID(projectID)
        }

        // Handle App Intent that triggered a cold launch
        if let pendingID = OpenProjectIntent.pendingProjectID {
            OpenProjectIntent.pendingProjectID = nil
            homeViewController.openProjectByID(pendingID)
        }
    }

    // Handle file open when app is already running
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        let importableURLs = URLContexts
            .map(\.url)
            .filter { Self.importableExtensions.contains($0.pathExtension.lowercased()) }

        guard let url = importableURLs.first,
              let homeVC = navigateToHomeViewController() else {
            return
        }

        if importableURLs.count > 1 {
            // Explicitly reject multiple files rather than silently dropping them
            let alert = UIAlertController(
                title: String(
                    localized: "import.error.multiple_files.title",
                    defaultValue: "Multiple Files"
                ),
                message: String(
                    localized: "import.error.multiple_files.message",
                    defaultValue: "Only one archive can be imported at a time. The first file will be imported."
                ),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: String(localized: "common.action.ok", defaultValue: "OK"),
                style: .default
            ) { _ in
                homeVC.importProjectArchive(from: url)
            })
            homeVC.present(alert, animated: true)
        } else {
            homeVC.importProjectArchive(from: url)
        }
    }

    /// Ensures HomeViewController is the visible VC by dismissing modals and popping the nav stack.
    private func navigateToHomeViewController() -> HomeViewController? {
        guard let nav = window?.rootViewController as? UINavigationController else { return nil }
        // Dismiss any modally-presented VC so Home can present alerts
        if nav.presentedViewController != nil {
            nav.dismiss(animated: false)
        }
        // Pop to root so HomeViewController is the topmost VC in the hierarchy
        if nav.viewControllers.count > 1 {
            nav.popToRootViewController(animated: false)
        }
        return nav.viewControllers.first as? HomeViewController
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let observer = openProjectObserver {
            NotificationCenter.default.removeObserver(observer)
            openProjectObserver = nil
        }
    }
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
