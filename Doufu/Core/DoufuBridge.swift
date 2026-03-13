//
//  DoufuBridge.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation
import WebKit

/// Manages the JS bridge injected into every project web page.
///
/// Capabilities:
/// - **fetch() proxy**: Cross-origin requests are transparently routed through
///   the local HTTP server's `/__doufu_proxy__` endpoint. The LLM writes normal
///   `fetch()` calls; CORS is handled automatically.
/// - **localStorage persistence**: `localStorage` is overridden with an
///   in-memory store that async-flushes to a JSON file in the project directory.
///   Data survives WKWebView cache clears and app reinstalls.
/// - **IndexedDB persistence**: `indexedDB` is overridden with a JS shim that
///   stores all data in-memory and flushes to `AppData/indexedDB.json`.
///   Survives cache clears, git checkpoint restores, and app reinstalls.
@MainActor
final class DoufuBridge: NSObject {

    private let projectURL: URL
    private let storageDirectoryOverride: URL?

    /// Called from the WKScriptMessageHandler when localStorage changes.
    private var storageData: [String: String] = [:]

    /// Full IndexedDB snapshot: { dbName: { version, stores: { ... } } }
    private var indexedDBData: [String: Any] = [:]

    /// - Parameters:
    ///   - projectURL: The project directory.
    ///   - storageDirectoryOverride: If provided, localStorage and IndexedDB data
    ///     are persisted here instead of the default `AppData/` location. Useful for
    ///     validation runs that should not dirty real user data.
    init(projectURL: URL, storageDirectoryOverride: URL? = nil) {
        self.projectURL = projectURL
        self.storageDirectoryOverride = storageDirectoryOverride
        super.init()
        loadStorage()
        loadIndexedDB()
    }

    // MARK: - WKWebView Integration

    /// Registers the bridge's message handlers on the given WKWebView configuration.
    /// Call this before creating the WKWebView.
    func register(on configuration: WKWebViewConfiguration) {
        let bridgeScript = WKUserScript(
            source: bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(bridgeScript)
        let handler = DoufuBridgeMessageHandler(bridge: self)
        configuration.userContentController.add(handler, name: "doufuStorage")
        configuration.userContentController.add(handler, name: "doufuIndexedDB")
    }

    /// Re-adds the bridge user script with the latest `storageData` and `indexedDBData`.
    ///
    /// `WKUserScript` captures its source at creation time, so after storage
    /// changes the embedded JSON snapshot becomes stale. Call this **before** any
    /// page reload / navigation to ensure the freshly-injected script carries the
    /// current data.
    ///
    /// - Important: This calls `removeAllUserScripts()` on the content controller.
    ///   The caller must re-add any non-bridge user scripts afterwards.
    func refreshStorageScript(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        let bridgeScript = WKUserScript(
            source: bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(bridgeScript)
    }

    /// Removes the bridge's message handlers. Call on deinit to break retain cycles.
    nonisolated func unregister(from configuration: WKWebViewConfiguration) {
        MainActor.assumeIsolated {
            configuration.userContentController.removeScriptMessageHandler(forName: "doufuStorage")
            configuration.userContentController.removeScriptMessageHandler(forName: "doufuIndexedDB")
        }
    }

    // MARK: - Storage Persistence

    /// User data lives in the sibling `AppData/` directory next to `App/`.
    /// Structure: `Projects/{uuid}/AppData/localStorage.json`
    /// This way git checkpoint restore doesn't affect user data.
    private var storageFileURL: URL {
        let dataDir = projectDataDirectory()
        return dataDir.appendingPathComponent("localStorage.json")
    }

    private var indexedDBFileURL: URL {
        let dataDir = projectDataDirectory()
        return dataDir.appendingPathComponent("indexedDB.json")
    }

    private func projectDataDirectory() -> URL {
        if let override = storageDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        // projectURL is the App/ directory; sibling AppData/ lives next to it.
        let dataDir = projectURL.deletingLastPathComponent()
            .appendingPathComponent("AppData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        return dataDir
    }

    private func loadStorage() {
        guard let data = try? Data(contentsOf: storageFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            storageData = [:]
            return
        }
        storageData = dict
    }

    private func loadIndexedDB() {
        guard let data = try? Data(contentsOf: indexedDBFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            indexedDBData = [:]
            return
        }
        indexedDBData = dict
    }

    fileprivate func handleStorageUpdate(_ payload: Any) {
        guard let dict = payload as? [String: String] else { return }
        storageData = dict
        saveStorage()
    }

    fileprivate func handleIndexedDBUpdate(_ payload: Any) {
        guard let dict = payload as? [String: Any] else { return }
        indexedDBData = dict
        saveIndexedDB()
    }

    private func saveStorage() {
        guard let data = try? JSONSerialization.data(withJSONObject: storageData, options: []) else {
            return
        }
        try? data.write(to: storageFileURL, options: .atomic)
    }

    private func saveIndexedDB() {
        guard let data = try? JSONSerialization.data(withJSONObject: indexedDBData, options: []) else {
            return
        }
        try? data.write(to: indexedDBFileURL, options: .atomic)
    }

    // MARK: - Bridge JavaScript

    private func bridgeJavaScript() -> String {
        let storageJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: storageData, options: []),
           let str = String(data: data, encoding: .utf8) {
            storageJSON = str
        } else {
            storageJSON = "{}"
        }

        let idbJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: indexedDBData, options: []),
           let str = String(data: data, encoding: .utf8) {
            idbJSON = str
        } else {
            idbJSON = "{}"
        }

        return """
        \(fetchProxyAndLocalStorageJavaScript(storageJSON: storageJSON))
        \(indexedDBShimJavaScript(snapshot: idbJSON))
        """
    }

    // MARK: - fetch() proxy + localStorage shim

    private func fetchProxyAndLocalStorageJavaScript(storageJSON: String) -> String {
        return """
        (function() {
          'use strict';

          var _origin = location.origin;

          function _isCrossOrigin(url) {
            try { return new URL(url, location.href).origin !== _origin; }
            catch(e) { return false; }
          }

          // ======== fetch() proxy ========
          var _originalFetch = window.fetch.bind(window);

          window.fetch = function(input, init) {
            var url;
            var ri = init ? Object.assign({}, init) : {};

            if (input instanceof Request) {
              url = input.url;
              if (!ri.method) ri.method = input.method;
              if (!ri.headers) {
                var h = {};
                input.headers.forEach(function(v, k) { h[k] = v; });
                ri.headers = h;
              }
              if (!ri.body && input.body) ri.body = input.body;
            } else {
              url = String(input);
            }

            if (_isCrossOrigin(url)) {
              return _originalFetch('/__doufu_proxy__?url=' + encodeURIComponent(url), ri);
            }
            return _originalFetch(input, init);
          };

          // ======== XMLHttpRequest proxy ========
          var _XHROpen = XMLHttpRequest.prototype.open;

          XMLHttpRequest.prototype.open = function(method, url) {
            var resolved = url;
            try { resolved = new URL(url, location.href).href; } catch(e) {}

            if (_isCrossOrigin(resolved)) {
              this._doufuProxied = true;
              var proxyUrl = '/__doufu_proxy__?url=' + encodeURIComponent(resolved);
              return _XHROpen.apply(this, [method, proxyUrl].concat(
                Array.prototype.slice.call(arguments, 2)
              ));
            }
            this._doufuProxied = false;
            return _XHROpen.apply(this, arguments);
          };

          // ======== localStorage persistence ========
          var _data = \(storageJSON);
          var _apiMethods = ['getItem','setItem','removeItem','clear','key'];

          function _flush() {
            try {
              var copy = {};
              for (var k in _data) copy[k] = _data[k];
              window.webkit.messageHandlers.doufuStorage.postMessage(copy);
            } catch(e) {}
          }

          var _storageTarget = {
            getItem: function(k) {
              var v = _data[String(k)];
              return v !== undefined ? v : null;
            },
            setItem: function(k, v) {
              _data[String(k)] = String(v);
              _flush();
            },
            removeItem: function(k) {
              delete _data[String(k)];
              _flush();
            },
            clear: function() {
              var keys = Object.keys(_data);
              for (var i = 0; i < keys.length; i++) delete _data[keys[i]];
              _flush();
            },
            key: function(i) {
              var keys = Object.keys(_data);
              return (i >= 0 && i < keys.length) ? keys[i] : null;
            }
          };

          Object.defineProperty(_storageTarget, 'length', {
            get: function() { return Object.keys(_data).length; },
            enumerable: false
          });

          // Proxy handles: localStorage.foo = 'bar', localStorage['foo'],
          // delete localStorage.foo, for...in, Object.keys(), etc.
          var _storageProxy = new Proxy(_storageTarget, {
            get: function(target, prop) {
              if (prop === 'length') return Object.keys(_data).length;
              if (typeof target[prop] === 'function') return target[prop].bind(target);
              if (_apiMethods.indexOf(prop) !== -1) return target[prop];
              if (typeof prop === 'symbol') return target[prop];
              // Property-style access: localStorage.myKey
              var v = _data[prop];
              return v !== undefined ? v : undefined;
            },
            set: function(target, prop, value) {
              if (_apiMethods.indexOf(prop) !== -1 || prop === 'length') return true;
              _data[String(prop)] = String(value);
              _flush();
              return true;
            },
            deleteProperty: function(target, prop) {
              delete _data[prop];
              _flush();
              return true;
            },
            has: function(target, prop) {
              return prop in _data || prop in target;
            },
            ownKeys: function() {
              return Object.keys(_data);
            },
            getOwnPropertyDescriptor: function(target, prop) {
              if (prop in _data) {
                return { value: _data[prop], writable: true, enumerable: true, configurable: true };
              }
              return Object.getOwnPropertyDescriptor(target, prop);
            }
          });

          try {
            Object.defineProperty(window, 'localStorage', {
              get: function() { return _storageProxy; },
              configurable: true
            });
          } catch(e) {}

        })();
        """
    }

    // MARK: - IndexedDB shim

    /// Cached shim template loaded from bundle (DoufuIndexedDBShim.js).
    private static let indexedDBShimTemplate: String = {
        guard let url = Bundle.main.url(forResource: "DoufuIndexedDBShim", withExtension: "js"),
              let js = try? String(contentsOf: url) else {
            assertionFailure("DoufuIndexedDBShim.js not found in bundle")
            return ""
        }
        return js
    }()

    private func indexedDBShimJavaScript(snapshot: String) -> String {
        // The .js file contains: var _idb = '__DOUFU_IDB_SNAPSHOT__';
        // We replace the entire placeholder string (including quotes) with the raw JSON
        // object literal, producing: var _idb = {"dbName": ...};
        return Self.indexedDBShimTemplate
            .replacingOccurrences(of: "'__DOUFU_IDB_SNAPSHOT__'", with: snapshot)
    }
}

// MARK: - Message Handler (prevent retain cycle)

/// A thin non-isolated wrapper so that `WKScriptMessageHandler` doesn't
/// retain the `@MainActor` bridge directly.
private nonisolated final class DoufuBridgeMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var bridge: DoufuBridge?

    init(bridge: DoufuBridge) {
        self.bridge = bridge
        super.init()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WebKit guarantees this delegate is called on the main thread.
        let name = MainActor.assumeIsolated { message.name }
        let body = MainActor.assumeIsolated { message.body }
        Task { @MainActor [weak self] in
            guard let bridge = self?.bridge else { return }
            switch name {
            case "doufuStorage":
                bridge.handleStorageUpdate(body)
            case "doufuIndexedDB":
                bridge.handleIndexedDBUpdate(body)
            default:
                break
            }
        }
    }
}
