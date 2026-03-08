//
//  CodeValidator.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation
import WebKit

@MainActor
final class CodeValidator: NSObject {

    struct ValidationError {
        let message: String
        let source: String
        let line: Int
        let column: Int

        var description: String {
            var desc = message
            if !source.isEmpty {
                desc += " (source: \(source))"
            }
            if line > 0 || column > 0 {
                desc += " at line \(line), column \(column)"
            }
            return desc
        }
    }

    struct ValidationResult {
        let errors: [ValidationError]
        let consoleOutput: [String]

        var passed: Bool { errors.isEmpty }

        var summary: String {
            if passed {
                return "Validation passed. No JavaScript errors detected."
            }
            var lines: [String] = ["Validation found \(errors.count) error(s):"]
            for (i, error) in errors.enumerated() {
                lines.append("  \(i + 1). \(error.description)")
            }
            if !consoleOutput.isEmpty {
                lines.append("")
                lines.append("Console output:")
                for entry in consoleOutput.prefix(20) {
                    lines.append("  \(entry)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let errorHandlerName = "doufuValidatorError"
    private static let consoleHandlerName = "doufuValidatorConsole"
    private static let completionHandlerName = "doufuValidatorDone"

    private var collectedErrors: [ValidationError] = []
    private var collectedConsole: [String] = []
    private var continuation: CheckedContinuation<ValidationResult, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var webView: WKWebView?
    private var activeBridge: DoufuBridge?

    private let validationTimeout: TimeInterval = 5.0

    /// Validate by loading through the project's local HTTP server (preferred).
    /// This matches the real runtime environment: ES Modules, fetch proxy, etc.
    func validate(relativePath: String, serverBaseURL: URL, bridge: DoufuBridge?) async -> ValidationResult {
        let pageURL = serverBaseURL.appendingPathComponent(relativePath)
        return await runValidation(url: pageURL, bridge: bridge)
    }

    /// Fallback: validate by loading a file:// URL directly.
    func validate(entryFileURL: URL, allowingReadAccessTo directoryURL: URL) async -> ValidationResult {
        return await runValidation(fileURL: entryFileURL, readAccessURL: directoryURL, bridge: nil)
    }

    private func runValidation(
        url: URL? = nil,
        fileURL: URL? = nil,
        readAccessURL: URL? = nil,
        bridge: DoufuBridge?
    ) async -> ValidationResult {
        cleanup()
        collectedErrors = []
        collectedConsole = []

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // Inject the Doufu bridge so fetch proxy + localStorage work during validation
        bridge?.register(on: config)

        let bridgeScript = WKUserScript(
            source: validatorBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(bridgeScript)
        config.userContentController.add(self, name: Self.errorHandlerName)
        config.userContentController.add(self, name: Self.consoleHandlerName)
        config.userContentController.add(self, name: Self.completionHandlerName)

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv
        self.activeBridge = bridge

        if let url {
            wv.load(URLRequest(url: url))
        } else if let fileURL, let readAccessURL {
            wv.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }

        return await withCheckedContinuation { cont in
            self.continuation = cont

            let timeout = DispatchWorkItem { [weak self] in
                self?.finishValidation()
            }
            self.timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + validationTimeout, execute: timeout)
        }
    }

    private func finishValidation() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        let result = ValidationResult(errors: collectedErrors, consoleOutput: collectedConsole)
        let cont = continuation
        continuation = nil
        cleanup()
        cont?.resume(returning: result)
    }

    private func cleanup() {
        if let wv = webView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            activeBridge?.unregister(from: wv.configuration)
            activeBridge = nil
            let controller = wv.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.errorHandlerName)
            controller.removeScriptMessageHandler(forName: Self.consoleHandlerName)
            controller.removeScriptMessageHandler(forName: Self.completionHandlerName)
            webView = nil
        }
    }

    private func validatorBridgeScript() -> String {
        """
        (function() {
          var errors = [];
          var consoleLogs = [];

          window.addEventListener('error', function(event) {
            try {
              window.webkit.messageHandlers.\(Self.errorHandlerName).postMessage({
                message: String(event.message || 'Unknown error'),
                source: String(event.filename || ''),
                line: Number(event.lineno || 0),
                column: Number(event.colno || 0)
              });
            } catch(_) {}
          });

          window.addEventListener('unhandledrejection', function(event) {
            var reason = event.reason;
            var text = '';
            if (typeof reason === 'string') { text = reason; }
            else if (reason && typeof reason.message === 'string') { text = reason.message; }
            else { text = 'Unhandled promise rejection'; }
            try {
              window.webkit.messageHandlers.\(Self.errorHandlerName).postMessage({
                message: text, source: 'promise', line: 0, column: 0
              });
            } catch(_) {}
          });

          var origLog = console.log;
          var origWarn = console.warn;
          var origError = console.error;
          function capture(level, args) {
            var msg = Array.prototype.slice.call(args).map(function(a) {
              return typeof a === 'object' ? JSON.stringify(a) : String(a);
            }).join(' ');
            try {
              window.webkit.messageHandlers.\(Self.consoleHandlerName).postMessage({
                level: level, message: msg
              });
            } catch(_) {}
          }
          console.log = function() { capture('log', arguments); origLog.apply(console, arguments); };
          console.warn = function() { capture('warn', arguments); origWarn.apply(console, arguments); };
          console.error = function() { capture('error', arguments); origError.apply(console, arguments); };

          window.addEventListener('load', function() {
            setTimeout(function() {
              try {
                window.webkit.messageHandlers.\(Self.completionHandlerName).postMessage({done: true});
              } catch(_) {}
            }, 500);
          });
        })();
        """
    }
}

// MARK: - WKScriptMessageHandler

extension CodeValidator: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            handleMessage(message)
        }
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard continuation != nil else { return }

        switch message.name {
        case Self.errorHandlerName:
            guard let body = message.body as? [String: Any] else { return }
            let error = ValidationError(
                message: (body["message"] as? String) ?? "Unknown error",
                source: (body["source"] as? String) ?? "",
                line: intValue(body["line"]) ?? 0,
                column: intValue(body["column"]) ?? 0
            )
            collectedErrors.append(error)

        case Self.consoleHandlerName:
            guard let body = message.body as? [String: Any] else { return }
            let level = (body["level"] as? String) ?? "log"
            let msg = (body["message"] as? String) ?? ""
            collectedConsole.append("[\(level)] \(msg)")

        case Self.completionHandlerName:
            finishValidation()

        default:
            break
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Double { return Int(v) }
        return nil
    }
}

// MARK: - WKNavigationDelegate

extension CodeValidator: WKNavigationDelegate {
    nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            collectedErrors.append(ValidationError(
                message: "Page load failed: \(error.localizedDescription)",
                source: "navigation",
                line: 0,
                column: 0
            ))
            finishValidation()
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            collectedErrors.append(ValidationError(
                message: "Page failed to load: \(error.localizedDescription)",
                source: "navigation",
                line: 0,
                column: 0
            ))
            finishValidation()
        }
    }
}
