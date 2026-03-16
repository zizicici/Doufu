//
//  DoufuBridge.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation
import WebKit

/// Protocol for handling capability requests from the JS bridge.
@MainActor
protocol DoufuBridgeCapabilityDelegate: AnyObject {
    /// Called when JS code requests a capability. The delegate should check
    /// system + project permissions and call the completion handler with:
    /// - `.success(jsonString)` with JSON data to resolve the JS Promise
    /// - `.failure(error)` with a descriptive error
    func bridge(
        _ bridge: DoufuBridge,
        didRequestCapability type: CapabilityType,
        action: String,
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    )

    /// Called when JS requests photo picking. PHPicker is privacy-safe and
    /// requires no system or project permission — no permission checks needed.
    func bridge(
        _ bridge: DoufuBridge,
        didRequestPhotoPick options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    )
}

struct DoufuBridgeCapabilityError: Error {
    let message: String
    let name: String // DOMException name, e.g. "NotAllowedError"
}

/// Manages the JS bridge injected into every project web page.
///
/// Capabilities:
/// - **fetch() proxy**: Cross-origin requests are transparently routed through
///   the local HTTP server's `/__doufu_proxy__` endpoint. The LLM writes normal
///   `fetch()` calls; CORS is handled automatically.
/// - **localStorage persistence**: `localStorage` is overridden with an
///   in-memory store that async-flushes to a JSON file in the project directory.
///   Data survives WKWebView cache clears and app reinstalls.
/// - **IndexedDB persistence**: `indexedDB` is overridden with a sql.js (WASM SQLite)
///   backed shim that persists to `AppData/indexedDB.sqlite` via HTTP PUT/GET.
///   Survives cache clears, git checkpoint restores, and app reinstalls.
/// - **doufu.db API**: Direct SQL access via `doufu.db.open/exec/run/close`,
///   each named database persisted as `AppData/{name}.sqlite`.
@MainActor
final class DoufuBridge: NSObject {

    private let projectURL: URL
    let projectID: String
    let projectName: String
    private let storageDirectoryOverride: URL?

    weak var capabilityDelegate: DoufuBridgeCapabilityDelegate?

    /// Delegate for forwarding WebRTC media signaling messages from JS.
    weak var mediaDelegate: MediaSessionManager?

    /// Reference to the webView for evaluateJavaScript callbacks.
    weak var webView: WKWebView?

    /// Called from the WKScriptMessageHandler when localStorage changes.
    private var storageData: [String: String] = [:]

    /// - Parameters:
    ///   - projectURL: The project directory.
    ///   - projectID: The project's unique identifier.
    ///   - projectName: The project's display name.
    ///   - storageDirectoryOverride: If provided, localStorage data is persisted
    ///     here instead of the default `AppData/` location. Useful for validation
    ///     runs that should not dirty real user data. Note: IndexedDB data is served
    ///     via the shared LocalWebServer and is not affected by this override.
    init(projectURL: URL, projectID: String = "", projectName: String = "", storageDirectoryOverride: URL? = nil) {
        self.projectURL = projectURL
        self.projectID = projectID
        self.projectName = projectName
        self.storageDirectoryOverride = storageDirectoryOverride
        super.init()
        loadStorage()
    }

    // MARK: - WKWebView Integration

    /// Registers the bridge's message handlers on the given WKWebView configuration.
    /// Call this before creating the WKWebView.
    func register(on configuration: WKWebViewConfiguration) {
        // Permission blocking must run in ALL frames (including iframes) to prevent
        // standard Web APIs from bypassing Doufu's project-level gating.
        let blockingScript = WKUserScript(
            source: permissionBlockingJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(blockingScript)
        // The bridge (doufu.*, storage, media) is injected into all frames.
        // A JS-side origin guard in bridgeJavaScript() skips initialization for
        // cross-origin iframes, while same-origin iframes get the full bridge.
        let bridgeScript = WKUserScript(
            source: bridgeJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(bridgeScript)
        let handler = DoufuBridgeMessageHandler(bridge: self)
        configuration.userContentController.add(handler, name: "doufuStorage")
        configuration.userContentController.add(handler, name: "doufuCapability")
        configuration.userContentController.add(handler, name: "doufuMedia")
    }

    /// Re-adds the bridge user script with the latest `storageData`.
    ///
    /// `WKUserScript` captures its source at creation time, so after localStorage
    /// changes the embedded JSON snapshot becomes stale. Call this **before** any
    /// page reload / navigation to ensure the freshly-injected script carries the
    /// current data. IndexedDB data is loaded by the shim via HTTP fetch, so no
    /// snapshot injection is needed.
    ///
    /// - Important: This calls `removeAllUserScripts()` on the content controller.
    ///   The caller must re-add any non-bridge user scripts afterwards.
    func refreshStorageScript(on configuration: WKWebViewConfiguration) {
        // Flush pending IndexedDB and doufu.db writes before tearing down scripts.
        // The old page's JS is still alive at this point.
        flushAllStorageSync()
        let controller = configuration.userContentController
        controller.removeAllUserScripts()
        let blockingScript = WKUserScript(
            source: permissionBlockingJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        controller.addUserScript(blockingScript)
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
            configuration.userContentController.removeScriptMessageHandler(forName: "doufuCapability")
            configuration.userContentController.removeScriptMessageHandler(forName: "doufuMedia")
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

    fileprivate func handleStorageUpdate(_ payload: Any) {
        guard let dict = payload as? [String: String] else { return }
        storageData = dict
        saveStorage()
    }

    private func saveStorage() {
        guard let data = try? JSONSerialization.data(withJSONObject: storageData, options: []) else {
            return
        }
        try? data.write(to: storageFileURL, options: .atomic)
    }

    /// Clears all localStorage data and writes an empty JSON object to disk.
    func clearLocalStorage() {
        storageData = [:]
        saveStorage()
        // Cancel JS-side flush so that any write during page teardown
        // (e.g. beforeunload handler) does not re-persist stale data.
        webView?.evaluateJavaScript("""
        (function() {
            if (typeof __doufuLocalStorageClear === 'function') __doufuLocalStorageClear();
        })();
        """, completionHandler: nil)
    }

    /// Flushes all pending storage writes to disk synchronously.
    ///
    /// Call before page navigation or WebView teardown to ensure in-memory
    /// IndexedDB and doufu.db changes are persisted. Unlike `clear*` methods,
    /// this preserves data — it just forces pending debounced writes to complete.
    func flushAllStorageSync() {
        webView?.evaluateJavaScript("""
        (function() {
            if (typeof __doufuIDBFlushSync === 'function') __doufuIDBFlushSync();
            if (typeof __doufuDbFlushAllSync === 'function') __doufuDbFlushAllSync();
        })();
        """, completionHandler: nil)
    }

    /// Clears all IndexedDB data by removing the SQLite file (and legacy JSON file).
    ///
    /// Also cancels any pending JS-side persist timer so the in-memory data
    /// is not flushed back to disk before the webView reloads.
    func clearIndexedDB() {
        // Cancel JS-side debounce timer and drop the in-memory DB so that
        // the upcoming page reload does NOT re-persist stale data.
        webView?.evaluateJavaScript("""
        (function() {
            if (typeof __doufuIDBCancelPersist === 'function') __doufuIDBCancelPersist();
        })();
        """, completionHandler: nil)
        let dir = projectDataDirectory()
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("indexedDB.sqlite"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("indexedDB.json"))
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

        // Skip the sql.js IndexedDB shim for validation bridges so they don't
        // read/write the real project's AppData. The validation WebView will use
        // WKWebView's native IndexedDB which is isolated per data store.
        let idbShim = storageDirectoryOverride == nil ? sqlJsIndexedDBJavaScript() : ""

        // Only initialize the bridge for local origins (localhost / file://).
        // Cross-origin iframes (e.g. <iframe src="https://example.com">) as well
        // as data:/blob:/about:blank frames are skipped automatically.
        return """
        if (location.protocol === 'file:' || location.hostname === 'localhost') {
        \(capabilityJavaScript())
        \(mediaJavaScript())
        \(fetchProxyAndLocalStorageJavaScript(storageJSON: storageJSON))
        \(idbShim)
        }
        """
    }

    // MARK: - Permission Blocking

    private func permissionBlockingJavaScript() -> String {
        return """
        (function() {
          'use strict';

          var _notAllowed = function(msg) {
            return Promise.reject(new DOMException(msg || 'Permission denied by Doufu.', 'NotAllowedError'));
          };

          // ======== Camera / Microphone ========
          if (navigator.mediaDevices) {
            navigator.mediaDevices.getUserMedia = function() { return _notAllowed('getUserMedia is not allowed.'); };
            navigator.mediaDevices.enumerateDevices = function() { return Promise.resolve([]); };
          }
          // Legacy APIs
          navigator.getUserMedia = function(c, s, e) { if (e) e(new DOMException('getUserMedia is not allowed.', 'NotAllowedError')); };
          navigator.webkitGetUserMedia = navigator.getUserMedia;

          // ======== Geolocation ========
          if (navigator.geolocation) {
            var _geoError = { code: 1, message: 'Geolocation permission denied by Doufu.', PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 };
            navigator.geolocation.getCurrentPosition = function(s, e) { if (e) { try { e(_geoError); } catch(x){} } };
            navigator.geolocation.watchPosition = function(s, e) { if (e) { try { e(_geoError); } catch(x){} } return 0; };
            navigator.geolocation.clearWatch = function() {};
          }

          // ======== Clipboard ========
          if (navigator.clipboard) {
            navigator.clipboard.readText = function() { return _notAllowed('Clipboard access is not allowed.'); };
            navigator.clipboard.read = function() { return _notAllowed('Clipboard access is not allowed.'); };
            navigator.clipboard.writeText = function() { return _notAllowed('Clipboard access is not allowed.'); };
            navigator.clipboard.write = function() { return _notAllowed('Clipboard access is not allowed.'); };
          }

          // Legacy execCommand clipboard operations
          var _origExecCommand = document.execCommand.bind(document);
          document.execCommand = function(cmd) {
            var lower = (cmd || '').toLowerCase();
            if (lower === 'copy' || lower === 'cut' || lower === 'paste') return false;
            return _origExecCommand.apply(document, arguments);
          };

          // ======== Permissions API ========
          if (navigator.permissions && navigator.permissions.query) {
            var _origQuery = navigator.permissions.query.bind(navigator.permissions);
            var _blocked = ['camera', 'microphone', 'geolocation', 'clipboard-read', 'clipboard-write'];
            navigator.permissions.query = function(desc) {
              if (desc && _blocked.indexOf(desc.name) !== -1) {
                return Promise.resolve({ state: 'denied', onchange: null });
              }
              return _origQuery(desc);
            };
          }

        })();
        """
    }

    // MARK: - Capability JS API

    private func capabilityJavaScript() -> String {
        return """
        (function() {
          'use strict';

          var _callbacks = {};
          var _watchCallbacks = {};
          var _nextId = 1;

          function _request(capability, action, opts) {
            return new Promise(function(resolve, reject) {
              var id = String(_nextId++);
              _callbacks[id] = { resolve: resolve, reject: reject };
              try {
                window.webkit.messageHandlers.doufuCapability.postMessage({
                  callbackId: id,
                  capability: capability,
                  action: action,
                  options: opts || {}
                });
              } catch(e) {
                delete _callbacks[id];
                reject(new DOMException('Bridge unavailable.', 'NotSupportedError'));
              }
            });
          }

          window.__doufuResolve = function(id, data) {
            var cb = _callbacks[id];
            if (cb) { delete _callbacks[id]; cb.resolve(data); }
          };

          window.__doufuReject = function(id, message, name) {
            var cb = _callbacks[id];
            if (cb) { delete _callbacks[id]; cb.reject(new DOMException(message, name || 'NotAllowedError')); }
          };

          window.__doufuLocationUpdate = function(watchId, data) {
            var cb = _watchCallbacks[watchId];
            if (cb) cb(data);
          };

          window.doufu = {
            // Exposed for mediaJavaScript() to call _request for stop actions.
            _rawRequest: _request,
            camera: {
              start: function(opts) { return _request('camera', 'start', opts); },
              stop: function() { return _request('camera', 'stop'); },
              focus: function(opts) { return _request('camera', 'focus', opts); },
              exposure: function(opts) { return _request('camera', 'exposure', opts); },
              torch: function(opts) { return _request('camera', 'torch', opts); },
              zoom: function(opts) { return _request('camera', 'zoom', opts); },
              mirror: function(opts) { return _request('camera', 'mirror', opts); }
            },
            mic: {
              start: function(opts) { return _request('microphone', 'start', opts); },
              stop: function() { return _request('microphone', 'stop'); }
            },
            photos: {
              pick: function(opts) { return _request('photo_pick', 'pick', opts); },
              savePhoto: function(dataUrl) { return _request('photo_save', 'savePhoto', { data: dataUrl }); },
              saveVideo: function(dataUrl) { return _request('photo_save', 'saveVideo', { data: dataUrl }); }
            },
            location: {
              get: function() { return _request('location', 'get'); },
              watch: function(cb) {
                return _request('location', 'watch').then(function(watchId) {
                  _watchCallbacks[watchId] = cb;
                  return watchId;
                });
              },
              clearWatch: function(id) {
                delete _watchCallbacks[id];
                return _request('location', 'clearWatch', { watchId: String(id) });
              }
            },
            clipboard: {
              read: function() { return _request('clipboard_read', 'read'); },
              write: function(text) { return _request('clipboard_write', 'write', { text: text }); }
            }
          };
        })();
        """
    }

    // MARK: - Capability Request Handling

    fileprivate func handleCapabilityRequest(_ payload: Any) {
        guard let dict = payload as? [String: Any],
              let callbackID = dict["callbackId"] as? String else {
            return
        }

        guard let capabilityKey = dict["capability"] as? String else {
            rejectCallback(callbackID: callbackID, message: "Unknown capability.", name: "NotSupportedError")
            return
        }

        guard let delegate = capabilityDelegate else {
            rejectCallback(callbackID: callbackID, message: "Capability not available.", name: "NotSupportedError")
            return
        }

        let options = dict["options"] as? [String: Any] ?? [:]

        // PHPicker is privacy-safe — bypass the CapabilityType permission system entirely.
        if capabilityKey == "photo_pick" {
            delegate.bridge(self, didRequestPhotoPick: options) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    self.resolveCallback(callbackID: callbackID, data: data)
                case .failure(let error):
                    self.rejectCallback(callbackID: callbackID, message: error.message, name: error.name)
                }
            }
            return
        }

        guard let type = CapabilityType.from(dbKey: capabilityKey) else {
            rejectCallback(callbackID: callbackID, message: "Unknown capability.", name: "NotSupportedError")
            return
        }

        let action = dict["action"] as? String ?? ""

        delegate.bridge(self, didRequestCapability: type, action: action, options: options) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.resolveCallback(callbackID: callbackID, data: data)
            case .failure(let error):
                self.rejectCallback(callbackID: callbackID, message: error.message, name: error.name)
            }
        }
    }

    /// Pushes a location update to a JS watch callback.
    func pushLocationUpdate(watchID: String, data: String) {
        let js = "window.__doufuLocationUpdate('\(watchID.escapedForJS)', \(data));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func resolveCallback(callbackID: String, data: String) {
        let js = "window.__doufuResolve('\(callbackID.escapedForJS)', \(data));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func rejectCallback(callbackID: String, message: String, name: String) {
        let js = "window.__doufuReject('\(callbackID.escapedForJS)', '\(message.escapedForJS)', '\(name.escapedForJS)');"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Media WebRTC Signaling

    /// JavaScript that overrides `doufu.camera.start/stop` and `doufu.mic.start/stop`
    /// to transparently handle WebRTC signaling and deliver a standard `MediaStream`.
    private func mediaJavaScript() -> String {
        return """
        (function() {
          'use strict';

          var _mediaPc = null;
          var _pendingMedia = {};
          var _activeStreams = {};
          var _currentFacing = 'user';

          window.__doufuMediaSignal = function(signal) {
            if (signal.type === 'offer') {
              _handleOffer(signal);
            } else if (signal.type === 'ice') {
              if (_mediaPc && signal.candidate) {
                _mediaPc.addIceCandidate(new RTCIceCandidate(signal.candidate))
                  .catch(function() {});
              }
            } else if (signal.type === 'teardown') {
              _teardownPC();
            }
          };

          function _handleOffer(signal) {
            if (!_mediaPc) {
              var iceConfig = {iceServers: []};
              if (signal.stunPort) {
                iceConfig.iceServers = [{urls: 'stun:127.0.0.1:' + signal.stunPort}];
              }
              _mediaPc = new RTCPeerConnection(iceConfig);

              _mediaPc.ontrack = function(e) {
                var kind = e.track.kind;
                var capType = kind === 'video' ? 'camera' : 'microphone';
                // Always create a dedicated stream per track so stopping camera
                // doesn't kill the mic track (and vice versa).
                var stream = new MediaStream([e.track]);
                if (capType === 'camera') {
                  stream.__doufuMirrored = (_currentFacing === 'user');
                }
                _activeStreams[capType] = stream;
                var cb = _pendingMedia[capType];
                if (cb) {
                  clearTimeout(cb.timer);
                  delete _pendingMedia[capType];
                  cb.resolve(stream);
                }
              };

              _mediaPc.onicecandidate = function(e) {
                if (e.candidate) {
                  try {
                    window.webkit.messageHandlers.doufuMedia.postMessage({
                      type: 'ice',
                      candidate: {
                        candidate: e.candidate.candidate,
                        sdpMid: e.candidate.sdpMid,
                        sdpMLineIndex: e.candidate.sdpMLineIndex
                      }
                    });
                  } catch(x) {}
                }
              };
            }

            _mediaPc.setRemoteDescription(new RTCSessionDescription({
              type: 'offer', sdp: signal.sdp
            }))
            .then(function() { return _mediaPc.createAnswer(); })
            .then(function(answer) { return _mediaPc.setLocalDescription(answer); })
            .then(function() {
              window.webkit.messageHandlers.doufuMedia.postMessage({
                type: 'answer',
                sdp: _mediaPc.localDescription.sdp
              });
            })
            .catch(function(err) {
              var keys = Object.keys(_pendingMedia);
              for (var i = 0; i < keys.length; i++) {
                var k = keys[i];
                clearTimeout(_pendingMedia[k].timer);
                _pendingMedia[k].reject(new DOMException(err.message || 'SDP negotiation failed.', 'NotSupportedError'));
                delete _pendingMedia[k];
              }
            });
          }

          function _teardownPC() {
            if (_mediaPc) {
              try { _mediaPc.close(); } catch(x) {}
              _mediaPc = null;
            }
            _activeStreams = {};
          }

          // Override doufu.camera.start to return MediaStream via WebRTC ontrack
          var _origCamStart = window.doufu.camera.start;
          window.doufu.camera.start = function(opts) {
            var facing = (opts && opts.facing) || 'user';
            _currentFacing = facing;

            // Cancel any previous pending camera callback
            var prev = _pendingMedia['camera'];
            if (prev) {
              clearTimeout(prev.timer);
              delete _pendingMedia['camera'];
            }

            return new Promise(function(resolve, reject) {
              var timer = setTimeout(function() {
                delete _pendingMedia['camera'];
                reject(new DOMException('Camera start timed out.', 'NotSupportedError'));
              }, 10000);
              _pendingMedia['camera'] = { resolve: resolve, reject: reject, timer: timer };

              _origCamStart(opts).then(function() {
                // Permission granted. If stream already exists (already active / camera switch),
                // resolve immediately with existing stream.
                if (_activeStreams['camera']) {
                  _activeStreams['camera'].__doufuMirrored = (facing === 'user');
                  var cb = _pendingMedia['camera'];
                  if (cb) {
                    clearTimeout(cb.timer);
                    delete _pendingMedia['camera'];
                    cb.resolve(_activeStreams['camera']);
                  }
                }
                // Otherwise wait for ontrack via SDP renegotiation
              }).catch(function(err) {
                var cb = _pendingMedia['camera'];
                if (cb) {
                  clearTimeout(cb.timer);
                  delete _pendingMedia['camera'];
                  cb.reject(err);
                }
              });
            });
          };

          // Override doufu.mic.start to return MediaStream via WebRTC ontrack
          var _origMicStart = window.doufu.mic.start;
          window.doufu.mic.start = function(opts) {
            // Cancel any previous pending mic callback
            var prev = _pendingMedia['microphone'];
            if (prev) {
              clearTimeout(prev.timer);
              delete _pendingMedia['microphone'];
            }

            return new Promise(function(resolve, reject) {
              var timer = setTimeout(function() {
                delete _pendingMedia['microphone'];
                reject(new DOMException('Microphone start timed out.', 'NotSupportedError'));
              }, 10000);
              _pendingMedia['microphone'] = { resolve: resolve, reject: reject, timer: timer };

              _origMicStart(opts).then(function() {
                // Permission granted. If stream already exists (already active),
                // resolve immediately with existing stream.
                if (_activeStreams['microphone']) {
                  var cb = _pendingMedia['microphone'];
                  if (cb) {
                    clearTimeout(cb.timer);
                    delete _pendingMedia['microphone'];
                    cb.resolve(_activeStreams['microphone']);
                  }
                }
                // Otherwise wait for ontrack via SDP renegotiation
              }).catch(function(err) {
                var cb = _pendingMedia['microphone'];
                if (cb) {
                  clearTimeout(cb.timer);
                  delete _pendingMedia['microphone'];
                  cb.reject(err);
                }
              });
            });
          };

          // Override stop to clean up JS-side streams
          window.doufu.camera.stop = function() {
            var stream = _activeStreams['camera'];
            if (stream) {
              stream.getTracks().forEach(function(t) { t.stop(); });
              delete _activeStreams['camera'];
            }
            return window.doufu._rawRequest('camera', 'stop');
          };

          window.doufu.mic.stop = function() {
            var stream = _activeStreams['microphone'];
            if (stream) {
              stream.getTracks().forEach(function(t) { t.stop(); });
              delete _activeStreams['microphone'];
            }
            return window.doufu._rawRequest('microphone', 'stop');
          };

          // Override doufu.camera.mirror to update __doufuMirrored on the active stream
          var _origMirror = window.doufu.camera.mirror;
          window.doufu.camera.mirror = function(opts) {
            return _origMirror(opts).then(function() {
              var stream = _activeStreams['camera'];
              if (stream) {
                stream.__doufuMirrored = !!(opts && opts.enabled);
              }
            });
          };

        })();
        """
    }

    /// Sends a WebRTC signaling message from native to JS.
    func sendMediaSignal(type: String, sdp: String? = nil, candidate: [String: Any]? = nil, stunPort: UInt16? = nil) {
        var parts = ["type:'\(type.escapedForJS)'"]
        if let sdp {
            parts.append("sdp:'\(sdp.escapedForJS)'")
        }
        if let candidate,
           let data = try? JSONSerialization.data(withJSONObject: candidate),
           let str = String(data: data, encoding: .utf8) {
            parts.append("candidate:\(str)")
        }
        if let stunPort {
            parts.append("stunPort:\(stunPort)")
        }
        let joined = parts.joined(separator: ",")
        let js = "window.__doufuMediaSignal({\(joined)});"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    fileprivate func handleMediaSignalFromJS(_ payload: Any) {
        guard let dict = payload as? [String: Any] else { return }
        Task { @MainActor [weak self] in
            self?.mediaDelegate?.handleMediaSignal(dict)
        }
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

        })();
        (function() {
          'use strict';

          // ======== localStorage persistence ========
          // Same-origin iframes share the parent frame's shim — single _data,
          // single flush path. Only the main frame creates the authoritative shim.
          if (window.parent !== window) {
            try {
              Object.defineProperty(window, 'localStorage', {
                get: function() { return window.parent.localStorage; },
                configurable: true
              });
              return;
            } catch(e) {}
          }

          // Use null-prototype object so inherited names like toString / __proto__
          // do not collide with valid localStorage keys.
          var _data = Object.assign(Object.create(null), \(storageJSON));
          var _apiMethods = ['getItem','setItem','removeItem','clear','key'];

          var _flushEnabled = true;
          function _flush() {
            if (!_flushEnabled) return;
            try {
              var copy = {};
              for (var k in _data) copy[k] = _data[k];
              window.webkit.messageHandlers.doufuStorage.postMessage(copy);
            } catch(e) {}
          }

          // Called from native before page reload to prevent stale writes
          // during teardown (e.g. beforeunload handlers re-persisting old data).
          window.__doufuLocalStorageClear = function() {
            var keys = Object.keys(_data);
            for (var i = 0; i < keys.length; i++) delete _data[keys[i]];
            _flushEnabled = false;
          };

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
              // Return null for missing keys to match native Storage named getter.
              var v = _data[prop];
              return v !== undefined ? v : null;
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

    // MARK: - sql.js IndexedDB shim + doufu.db API

    /// sql.js JS loader (sql-wasm.js) — cached from bundle.
    private static let sqlJsLoaderScript: String = {
        guard let url = Bundle.main.url(forResource: "sql-wasm", withExtension: "js"),
              let js = try? String(contentsOf: url) else {
            assertionFailure("sql-wasm.js not found in bundle")
            return ""
        }
        return js
    }()

    /// New IndexedDB shim template (DoufuSqlJsIndexedDB.js) — cached from bundle.
    private static let sqlJsIDBShimTemplate: String = {
        guard let url = Bundle.main.url(forResource: "DoufuSqlJsIndexedDB", withExtension: "js"),
              let js = try? String(contentsOf: url) else {
            assertionFailure("DoufuSqlJsIndexedDB.js not found in bundle")
            return ""
        }
        return js
    }()

    /// doufu.db.* direct SQL API template — cached from bundle.
    private static let doufuDbAPITemplate: String = {
        guard let url = Bundle.main.url(forResource: "DoufuDbAPI", withExtension: "js"),
              let js = try? String(contentsOf: url) else {
            assertionFailure("DoufuDbAPI.js not found in bundle")
            return ""
        }
        return js
    }()

    private func sqlJsIndexedDBJavaScript() -> String {
        let shimJS = Self.sqlJsIDBShimTemplate
            .replacingOccurrences(of: "'__DOUFU_WASMURL__'",
                                  with: "'/__doufu_static__/sql-wasm.wasm'")
            .replacingOccurrences(of: "'__DOUFU_APPDATAURL__'",
                                  with: "'/__doufu_appdata__'")
        let dbAPI = Self.doufuDbAPITemplate
            .replacingOccurrences(of: "'__DOUFU_APPDATAURL__'",
                                  with: "'/__doufu_appdata__'")
        // Wrap in an outer IIFE so same-origin iframes can delegate to
        // parent's shim and return early — skipping sql.js WASM load entirely.
        return """
        (function() {
          if (window.parent !== window) {
            try {
              Object.defineProperty(window, 'indexedDB', {
                get: function() { return window.parent.indexedDB; },
                configurable: true
              });
              window.IDBKeyRange = window.parent.IDBKeyRange;
              window.IDBDatabase = window.parent.IDBDatabase;
              window.IDBTransaction = window.parent.IDBTransaction;
              window.IDBObjectStore = window.parent.IDBObjectStore;
              window.IDBIndex = window.parent.IDBIndex;
              window.IDBCursor = window.parent.IDBCursor;
              window.IDBRequest = window.parent.IDBRequest;
              window.IDBOpenDBRequest = window.parent.IDBOpenDBRequest;
              window.IDBVersionChangeEvent = window.parent.IDBVersionChangeEvent;
              if (window.parent.doufu && window.parent.doufu.db) {
                window.doufu = window.doufu || {};
                window.doufu.db = window.parent.doufu.db;
              }
              return;
            } catch(e) {}
          }
        \(Self.sqlJsLoaderScript)
        \(shimJS)
        \(dbAPI)
        })();
        """
    }
}

// MARK: - String JS Escaping

private extension String {
    /// Escapes single quotes, backslashes, and newlines for safe embedding in JS string literals.
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
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
        // Accept messages from any frame with a local origin. Same-origin iframes
        // are part of the same application context and should access the bridge.
        // Cross-origin iframes are rejected by the origin check below.
        let securityOrigin = MainActor.assumeIsolated { message.frameInfo.securityOrigin }
        let isLocalOrigin = securityOrigin.host == "localhost"
            || securityOrigin.protocol == "file"
        guard isLocalOrigin else { return }
        let name = MainActor.assumeIsolated { message.name }
        let body = MainActor.assumeIsolated { message.body }
        Task { @MainActor [weak self] in
            guard let bridge = self?.bridge else { return }
            switch name {
            case "doufuStorage":
                bridge.handleStorageUpdate(body)
            case "doufuCapability":
                bridge.handleCapabilityRequest(body)
            case "doufuMedia":
                bridge.handleMediaSignalFromJS(body)
            default:
                break
            }
        }
    }
}
