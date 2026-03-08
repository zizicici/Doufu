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
        let stack: String?

        var description: String {
            var desc = message
            if !source.isEmpty {
                desc += " (source: \(source))"
            }
            if line > 0 || column > 0 {
                desc += " at line \(line), column \(column)"
            }
            if let stack, !stack.isEmpty {
                desc += "\n    Stack:\n"
                for stackLine in stack.components(separatedBy: "\n").prefix(8) {
                    desc += "      \(stackLine)\n"
                }
            }
            return desc
        }
    }

    struct ValidationResult {
        let errors: [ValidationError]
        let resourceErrors: [String]
        let consoleOutput: [String]

        var passed: Bool { errors.isEmpty && resourceErrors.isEmpty }

        var summary: String {
            if passed && consoleOutput.isEmpty {
                return "Validation passed. No errors detected."
            }
            var lines: [String] = []
            if !errors.isEmpty {
                lines.append("Validation found \(errors.count) JS error(s):")
                for (i, error) in errors.enumerated() {
                    lines.append("  \(i + 1). \(error.description)")
                }
            }
            if !resourceErrors.isEmpty {
                if !lines.isEmpty { lines.append("") }
                lines.append("Resource loading failures (\(resourceErrors.count)):")
                for (i, res) in resourceErrors.prefix(10).enumerated() {
                    lines.append("  \(i + 1). \(res)")
                }
            }
            if passed && errors.isEmpty && resourceErrors.isEmpty {
                lines.append("Validation passed (no JS or resource errors).")
            }
            if !consoleOutput.isEmpty {
                lines.append("")
                lines.append("Console output:")
                for entry in consoleOutput.prefix(30) {
                    lines.append("  \(entry)")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let errorHandlerName = "doufuValidatorError"
    private static let consoleHandlerName = "doufuValidatorConsole"
    private static let resourceErrorHandlerName = "doufuValidatorResource"
    private static let completionHandlerName = "doufuValidatorDone"

    private var collectedErrors: [ValidationError] = []
    private var collectedResourceErrors: [String] = []
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
        collectedResourceErrors = []
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
        config.userContentController.add(self, name: Self.resourceErrorHandlerName)
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

        let result = ValidationResult(errors: collectedErrors, resourceErrors: collectedResourceErrors, consoleOutput: collectedConsole)
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
            controller.removeScriptMessageHandler(forName: Self.resourceErrorHandlerName)
            controller.removeScriptMessageHandler(forName: Self.completionHandlerName)
            webView = nil
        }
    }

    private func validatorBridgeScript() -> String {
        """
        (function() {
          'use strict';

          // ======== Helper: extract stack trace from Error ========
          function _extractStack(err) {
            if (!err) return '';
            if (typeof err.stack === 'string') {
              // Remove the first line (error message) to keep just the trace
              var lines = err.stack.split('\\n');
              if (lines.length > 1 && lines[0].indexOf(err.message) !== -1) {
                lines.shift();
              }
              return lines.join('\\n').substring(0, 2000);
            }
            return '';
          }

          // ======== 1. JS runtime errors (with stack trace) ========
          window.addEventListener('error', function(event) {
            try {
              var stack = '';
              if (event.error) {
                stack = _extractStack(event.error);
              }
              window.webkit.messageHandlers.\(Self.errorHandlerName).postMessage({
                message: String(event.message || 'Unknown error'),
                source: String(event.filename || ''),
                line: Number(event.lineno || 0),
                column: Number(event.colno || 0),
                stack: stack
              });
            } catch(_) {}
          });

          // ======== 2. Unhandled promise rejections (with stack trace) ========
          window.addEventListener('unhandledrejection', function(event) {
            var reason = event.reason;
            var text = '';
            var stack = '';
            if (typeof reason === 'string') {
              text = reason;
            } else if (reason instanceof Error) {
              text = reason.message || 'Unhandled promise rejection';
              stack = _extractStack(reason);
            } else if (reason && typeof reason.message === 'string') {
              text = reason.message;
            } else {
              text = 'Unhandled promise rejection';
            }
            try {
              window.webkit.messageHandlers.\(Self.errorHandlerName).postMessage({
                message: text, source: 'promise', line: 0, column: 0, stack: stack
              });
            } catch(_) {}
          });

          // ======== 3. Resource loading failures (img, script, link, etc.) ========
          window.addEventListener('error', function(event) {
            try {
              var el = event.target;
              if (!el || el === window) return;
              var tag = (el.tagName || '').toLowerCase();
              var url = el.src || el.href || '';
              if (!url) return;
              var desc = 'Failed to load <' + tag + '>: ' + url;
              window.webkit.messageHandlers.\(Self.resourceErrorHandlerName).postMessage({
                description: desc, tag: tag, url: url
              });
            } catch(_) {}
          }, true); // capture phase to catch resource errors

          // ======== 4. Console method interception (full set) ========
          var _originals = {
            log: console.log,
            warn: console.warn,
            error: console.error,
            info: console.info,
            debug: console.debug,
            assert: console.assert,
            trace: console.trace
          };

          function _formatArgs(args) {
            return Array.prototype.slice.call(args).map(function(a) {
              if (a instanceof Error) return a.message + '\\n' + _extractStack(a);
              if (typeof a === 'object') {
                try { return JSON.stringify(a); } catch(e) { return String(a); }
              }
              return String(a);
            }).join(' ');
          }

          function _capture(level, args) {
            try {
              window.webkit.messageHandlers.\(Self.consoleHandlerName).postMessage({
                level: level, message: _formatArgs(args)
              });
            } catch(_) {}
          }

          console.log   = function() { _capture('log', arguments);   _originals.log.apply(console, arguments); };
          console.warn  = function() { _capture('warn', arguments);  _originals.warn.apply(console, arguments); };
          console.error = function() { _capture('error', arguments); _originals.error.apply(console, arguments); };
          console.info  = function() { _capture('info', arguments);  _originals.info.apply(console, arguments); };
          console.debug = function() { _capture('debug', arguments); _originals.debug.apply(console, arguments); };

          console.assert = function(condition) {
            if (!condition) {
              var args = Array.prototype.slice.call(arguments, 1);
              var msg = args.length > 0 ? _formatArgs(args) : 'Assertion failed';
              _capture('assert', ['Assertion failed: ' + msg]);
              // Generate a stack trace for the assert location
              try {
                var err = new Error('Assertion failed');
                window.webkit.messageHandlers.\(Self.errorHandlerName).postMessage({
                  message: 'Assertion failed: ' + msg,
                  source: 'console.assert',
                  line: 0, column: 0,
                  stack: _extractStack(err)
                });
              } catch(_) {}
            }
            _originals.assert.apply(console, arguments);
          };

          console.trace = function() {
            var msg = arguments.length > 0 ? _formatArgs(arguments) : 'console.trace';
            var err = new Error(msg);
            _capture('trace', [msg + '\\n' + _extractStack(err)]);
            _originals.trace.apply(console, arguments);
          };

          // ======== 5. Completion signal ========
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
                column: intValue(body["column"]) ?? 0,
                stack: body["stack"] as? String
            )
            collectedErrors.append(error)

        case Self.consoleHandlerName:
            guard let body = message.body as? [String: Any] else { return }
            let level = (body["level"] as? String) ?? "log"
            let msg = (body["message"] as? String) ?? ""
            collectedConsole.append("[\(level)] \(msg)")

        case Self.resourceErrorHandlerName:
            guard let body = message.body as? [String: Any] else { return }
            let desc = (body["description"] as? String) ?? "Unknown resource error"
            collectedResourceErrors.append(desc)

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
                column: 0,
                stack: nil
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
                column: 0,
                stack: nil
            ))
            finishValidation()
        }
    }
}
