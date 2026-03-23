//
//  LocalWebServer.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import CryptoKit
import Foundation
import Network

/// A lightweight HTTP server that serves static files from a project directory
/// over localhost. Also provides a reverse proxy endpoint (`/__doufu_proxy__`)
/// so that web apps can make cross-origin requests through the host app,
/// bypassing CORS restrictions transparently.
final class LocalWebServer: @unchecked Sendable {
    static let requestTokenHeaderName = "X-Doufu-Token"

    private let projectURL: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.doufu.localwebserver", qos: .userInitiated)
    private let urlSession: URLSession
    private(set) var port: UInt16 = 0
    private var restartAttempts = 0
    private static let maxRestartAttempts = 3
    private static let dynamicPortRange: ClosedRange<UInt16> = 49_152...65_535
    private static let tokenCookieName = "__doufu_dt"

    /// Per-launch secret token. Required on protected localhost routes.
    /// The initial main-document request can bootstrap access via
    /// `X-Doufu-Token`, after which a same-origin cookie is set for
    /// transparent subresource loading.
    let authToken = UUID().uuidString

    /// Optional secondary directory served under the `/__doufu_tmp__/` path prefix.
    /// Used for temporary files (e.g. picked photos) that should not live inside the App/ directory.
    var tmpDirectoryURL: URL?

    /// Optional directory for app data files served under the `/__doufu_appdata__/` path prefix.
    /// Supports GET (read) and PUT (write) for binary file persistence (e.g. SQLite databases).
    var appDataDirectoryURL: URL?

    init(projectURL: URL, projectID _: String) {
        self.projectURL = projectURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config)
    }

    deinit {
        stop()
    }

    /// Idempotent — stops any existing listener before starting a new one.
    @discardableResult
    func start() throws -> UInt16 {
        stop()
        // Use a fresh random high port each launch to make same-device probing harder.
        for _ in 0..<8 {
            let candidate = UInt16.random(in: Self.dynamicPortRange)
            if let port = NWEndpoint.Port(rawValue: candidate),
               let startedPort = try? startListener(on: port) {
                return startedPort
            }
        }
        return try startListener(on: .any)
    }

    /// Maximum request body size (16 MB). Larger PUT payloads are rejected.
    private static let maxBodySize = 16 * 1024 * 1024

    private func startListener(on requestedPort: NWEndpoint.Port) throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Bind to loopback only — prevents any device on the same network
        // from accessing project files, user data, or the proxy endpoint.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requestedPort)
        let listener = try NWListener(using: parameters, on: requestedPort)

        listener.stateUpdateHandler = makeStateHandler()
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
        self.listener = listener

        let deadline = Date().addingTimeInterval(2)
        while port == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard port != 0 else {
            listener.cancel()
            self.listener = nil
            throw ServerError.failedToStart
        }

        return port
    }

    /// Non-blocking restart on the same port (called from stateUpdateHandler on `queue`).
    private func restartListener(on requestedPort: NWEndpoint.Port) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requestedPort)
        let newListener = try NWListener(using: parameters, on: requestedPort)

        newListener.stateUpdateHandler = makeStateHandler()
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        newListener.start(queue: queue)
        self.listener = newListener
    }

    private func makeStateHandler() -> (NWListener.State) -> Void {
        return { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.restartAttempts = 0
                if let port = self.listener?.port?.rawValue {
                    self.port = port
                }
            case .failed, .waiting:
                let restartPort = self.port
                self.listener?.cancel()
                self.listener = nil
                self.port = 0
                guard self.restartAttempts < Self.maxRestartAttempts else { return }
                self.restartAttempts += 1
                if restartPort != 0,
                   let nwPort = NWEndpoint.Port(rawValue: restartPort) {
                    try? self.restartListener(on: nwPort)
                }
            default:
                break
            }
        }
    }

    /// Ensures the server is running on a fresh random high port when needed.
    /// Callers that cache `baseURL` should refresh it after calling this.
    @discardableResult
    func ensureRunning() -> Bool {
        if listener != nil, port != 0 { return true }
        listener?.cancel()
        listener = nil
        port = 0
        restartAttempts = 0
        return (try? start()) != nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    var baseURL: URL? {
        guard port != 0 else { return nil }
        return URL(string: "http://localhost:\(port)")
    }

    enum ServerError: LocalizedError {
        case failedToStart

        var errorDescription: String? {
            "Failed to start local web server"
        }
    }

    // MARK: - Parsed HTTP Request

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: String? // raw query string after '?'
        let headers: [String: String]
        let body: Data?
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveFullRequest(on: connection, accumulated: Data())
    }

    /// Receives data until we have a complete HTTP request (headers + body based on Content-Length).
    private func receiveFullRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard let data, error == nil else { connection.cancel(); return }

            var buffer = accumulated
            buffer.append(data)

            // Check if we have the full headers
            guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete {
                    connection.cancel()
                } else {
                    self.receiveFullRequest(on: connection, accumulated: buffer)
                }
                return
            }

            let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]
            let bodyStart = headerEndRange.upperBound
            let currentBody = buffer[bodyStart...]

            // Parse Content-Length to know if we need more body data
            let headerString = String(data: Data(headerData), encoding: .utf8) ?? ""
            let contentLength = self.parseContentLength(from: headerString)

            // Reject oversized request bodies early to prevent memory exhaustion.
            if contentLength > Self.maxBodySize {
                let resp = self.buildResponse(statusCode: 413, statusText: "Payload Too Large",
                                              body: Data("Request body too large".utf8), contentType: "text/plain")
                self.sendResponse(resp, on: connection)
                return
            }

            let bodyNeeded = contentLength - currentBody.count

            if bodyNeeded > 0 && !isComplete {
                // Need more body data
                self.receiveFullRequest(on: connection, accumulated: buffer)
                return
            }

            // We have enough data — parse and handle
            let request = self.parseHTTPRequest(headerString: headerString, body: Data(currentBody))
            self.routeRequest(request, on: connection)
        }
    }

    private static let tmpPathPrefix = "/__doufu_tmp__/"
    private static let appDataPathPrefix = "/__doufu_appdata__/"
    private static let staticBundlePathPrefix = "/__doufu_static__/"

    /// Validates that the Host header matches localhost or 127.0.0.1 with our port.
    /// Blocks DNS rebinding attacks where an external domain rebinds to 127.0.0.1
    /// and tries to access our endpoints.
    private func isValidHost(_ request: HTTPRequest) -> Bool {
        guard let host = request.headers["Host"] ?? request.headers["host"] else {
            return true // No Host header (e.g. HTTP/1.0) — allow
        }
        let allowed = ["localhost:\(port)", "127.0.0.1:\(port)", "localhost", "127.0.0.1"]
        return allowed.contains(host)
    }

    private func routeRequest(_ request: HTTPRequest, on connection: NWConnection) {
        if !isValidHost(request) {
            let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                         body: Data("Invalid Host header".utf8), contentType: "text/plain")
            sendResponse(response, on: connection)
            return
        }

        if request.path == "/__doufu_proxy__" {
            guard hasValidAuthToken(request) else {
                let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                              body: Data("Missing or invalid token".utf8), contentType: "text/plain")
                sendResponse(response, on: connection)
                return
            }
            handleProxyRequest(request) { [weak self] response in
                self?.sendResponse(response, on: connection)
            }
        } else if request.path.hasPrefix(Self.tmpPathPrefix) {
            guard hasValidAuthToken(request) else {
                let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                             body: Data("Missing or invalid token".utf8), contentType: "text/plain")
                sendResponse(response, on: connection)
                return
            }
            let response = handleTmpFileRequest(request)
            sendResponse(response, on: connection)
        } else if request.path.hasPrefix(Self.appDataPathPrefix) {
            // OPTIONS preflight cannot carry custom query params — skip token check.
            if request.method != "OPTIONS" {
                guard hasValidAuthToken(request) else {
                    let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                                  body: Data("Missing or invalid token".utf8), contentType: "text/plain")
                    sendResponse(response, on: connection)
                    return
                }
            }
            let response = handleAppDataRequest(request)
            sendResponse(response, on: connection)
        } else if request.path.hasPrefix(Self.staticBundlePathPrefix) {
            guard hasValidAuthToken(request) else {
                let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                             body: Data("Missing or invalid token".utf8), contentType: "text/plain")
                sendResponse(response, on: connection)
                return
            }
            let response = handleStaticBundleRequest(request)
            sendResponse(response, on: connection)
        } else {
            guard hasValidAuthToken(request) else {
                let response = buildResponse(statusCode: 403, statusText: "Forbidden",
                                             body: Data("Missing or invalid token".utf8), contentType: "text/plain")
                sendResponse(response, on: connection)
                return
            }
            let response = handleStaticFileRequest(request)
            sendResponse(response, on: connection)
        }
    }

    private func sendResponse(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP Parsing

    private func parseContentLength(from headerString: String) -> Int {
        for line in headerString.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func parseHTTPRequest(headerString: String, body: Data) -> HTTPRequest {
        let lines = headerString.components(separatedBy: "\r\n")
        let requestLineParts = (lines.first ?? "").split(separator: " ", maxSplits: 2)

        let method = requestLineParts.count > 0 ? String(requestLineParts[0]) : "GET"
        let rawPath = requestLineParts.count > 1 ? String(requestLineParts[1]) : "/"

        var path = rawPath
        var query: String?
        if let qIndex = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<qIndex])
            query = String(rawPath[rawPath.index(after: qIndex)...])
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body.isEmpty ? nil : body
        )
    }

    private func parseQueryParam(named name: String, from query: String?) -> String? {
        guard let query else { return nil }
        for pair in query.components(separatedBy: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    private func parseHeader(named name: String, from request: HTTPRequest) -> String? {
        if let exact = request.headers[name] {
            return exact
        }
        let target = name.lowercased()
        for (key, value) in request.headers where key.lowercased() == target {
            return value
        }
        return nil
    }

    private func parseCookie(named name: String, from request: HTTPRequest) -> String? {
        guard let cookieHeader = parseHeader(named: "Cookie", from: request) else {
            return nil
        }
        for part in cookieHeader.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            return String(pair[1]).trimmingCharacters(in: .whitespaces).removingPercentEncoding
        }
        return nil
    }

    private func hasValidAuthToken(_ request: HTTPRequest) -> Bool {
        if parseQueryParam(named: "__dt", from: request.query) == authToken {
            return true
        }
        if parseHeader(named: Self.requestTokenHeaderName, from: request) == authToken {
            return true
        }
        if parseCookie(named: Self.tokenCookieName, from: request) == authToken {
            return true
        }
        return false
    }

    private func authCookieHeaderValue() -> String {
        "\(Self.tokenCookieName)=\(authToken); Path=/; HttpOnly; SameSite=Strict"
    }

    // MARK: - Proxy

    private static let skipRequestHeaders: Set<String> = [
        "host", "origin", "referer", "connection", "accept-encoding"
    ]

    private static let skipResponseHeaders: Set<String> = [
        "content-encoding", "transfer-encoding", "content-length", "connection"
    ]

    private func handleProxyRequest(_ request: HTTPRequest, completion: @escaping (Data) -> Void) {
        // Extract target URL from query: /__doufu_proxy__?url=<encoded>
        guard let targetURLString = parseQueryParam(named: "url", from: request.query),
              let targetURL = URL(string: targetURLString) else {
            completion(buildResponse(
                statusCode: 400,
                statusText: "Bad Request",
                body: Data("Missing or invalid 'url' parameter".utf8),
                contentType: "text/plain"
            ))
            return
        }

        // Only allow http/https — block file://, ftp://, and other schemes
        // to prevent local file system access via the proxy endpoint.
        guard let scheme = targetURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            completion(buildResponse(
                statusCode: 403,
                statusText: "Forbidden",
                body: Data("Proxy only supports http and https URLs".utf8),
                contentType: "text/plain"
            ))
            return
        }

        // Block requests targeting localhost / loopback to prevent cross-project
        // data theft (Project A using proxy to read Project B's server).
        // Uses getaddrinfo to catch all numeric encodings (hex, octal, short-form).
        if let host = targetURL.host, Self.isLoopbackOrLocalHost(host) {
            completion(buildResponse(
                statusCode: 403,
                statusText: "Forbidden",
                body: Data("Proxy cannot target localhost".utf8),
                contentType: "text/plain"
            ))
            return
        }

        let shouldCache = parseQueryParam(named: "cache", from: request.query) == "1"

        // If caching is enabled, try returning from disk cache first
        if shouldCache, let cached = cdnCache.read(for: targetURLString) {
            completion(self.buildResponse(
                statusCode: cached.statusCode,
                statusText: "OK",
                body: cached.data,
                contentType: cached.contentType
            ))
            return
        }

        var urlRequest = URLRequest(url: targetURL)
        urlRequest.httpMethod = request.method

        // Forward request headers (skip internal/browser ones)
        for (key, value) in request.headers {
            guard !Self.skipRequestHeaders.contains(key.lowercased()) else { continue }
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body

        urlSession.dataTask(with: urlRequest) { [weak self] data, response, error in
            guard let self else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                // Network failed — try stale cache as offline fallback
                if shouldCache, let cached = self.cdnCache.read(for: targetURLString) {
                    completion(self.buildResponse(
                        statusCode: cached.statusCode,
                        statusText: "OK",
                        body: cached.data,
                        contentType: cached.contentType
                    ))
                    return
                }
                let errorMessage = error?.localizedDescription ?? "Proxy request failed"
                completion(self.buildResponse(
                    statusCode: 502,
                    statusText: "Bad Gateway",
                    body: Data(errorMessage.utf8),
                    contentType: "text/plain"
                ))
                return
            }

            let responseBody = data ?? Data()

            // Cache successful responses for CDN resources
            if shouldCache, (200..<300).contains(httpResponse.statusCode) {
                let ct = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
                self.cdnCache.write(
                    for: targetURLString,
                    data: responseBody,
                    contentType: ct,
                    statusCode: httpResponse.statusCode
                )
            }

            // Build raw HTTP response, forwarding status and headers
            let statusText = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            var header = "HTTP/1.1 \(httpResponse.statusCode) \(statusText)\r\n"

            for (key, value) in httpResponse.allHeaderFields {
                let keyStr = String(describing: key)
                guard !Self.skipResponseHeaders.contains(keyStr.lowercased()) else { continue }
                header += "\(keyStr): \(value)\r\n"
            }
            header += "Content-Length: \(responseBody.count)\r\n"
            header += "Connection: close\r\n"
            header += "\r\n"

            var responseData = Data(header.utf8)
            responseData.append(responseBody)
            completion(responseData)
        }.resume()
    }

    /// Returns `true` when `host` resolves to a loopback (127.0.0.0/8, ::1)
    /// or unspecified (0.0.0.0, ::) address.  Handles hex (`0x7f000001`),
    /// octal (`0177.0.0.1`), decimal (`2130706433`), short-form (`127.1`),
    /// IPv4-mapped IPv6, and DNS hostnames that resolve to loopback.
    private static func isLoopbackOrLocalHost(_ host: String) -> Bool {
        let cleaned = (host.hasPrefix("[") && host.hasSuffix("]"))
            ? String(host.dropFirst().dropLast()) : host

        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(cleaned, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }

        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let info = cur {
            defer { cur = info.pointee.ai_next }
            switch info.pointee.ai_family {
            case AF_INET:
                var sa = sockaddr_in()
                memcpy(&sa, info.pointee.ai_addr!, MemoryLayout<sockaddr_in>.size)
                let ip = UInt32(bigEndian: sa.sin_addr.s_addr)
                // 127.0.0.0/8 or 0.0.0.0
                if ip >> 24 == 127 || ip == 0 { return true }
            case AF_INET6:
                var sa = sockaddr_in6()
                memcpy(&sa, info.pointee.ai_addr!, MemoryLayout<sockaddr_in6>.size)
                var addr = sa.sin6_addr
                let b = withUnsafeBytes(of: &addr) { Array<UInt8>($0) }
                // ::1 (loopback)
                if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
                // :: (unspecified)
                if b.allSatisfy({ $0 == 0 }) { return true }
                // ::ffff:127.x.x.x or ::ffff:0.0.0.0 (IPv4-mapped)
                if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
                    if b[12] == 127 || b[12..<16].allSatisfy({ $0 == 0 }) { return true }
                }
            default: break
            }
        }
        return false
    }

    // MARK: - Static File Serving

    private func handleStaticFileRequest(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed",
                                 body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }

        var path = request.path.removingPercentEncoding ?? request.path
        if path == "/" { path = "/index.html" }

        // Prevent directory traversal and symlink escape
        let resolved = projectURL.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        let projectPath = projectURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = resolved.path
        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"

        guard resolvedPath == projectPath || resolvedPath.hasPrefix(prefix) else {
            return buildResponse(statusCode: 403, statusText: "Forbidden",
                                 body: Data("Forbidden".utf8), contentType: "text/plain")
        }

        // Directory → index.html
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir)
        let finalURL = (exists && isDir.boolValue)
            ? resolved.appendingPathComponent("index.html")
            : resolved

        guard FileManager.default.fileExists(atPath: finalURL.path),
              let fileData = try? Data(contentsOf: finalURL) else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        let ext = finalURL.pathExtension.lowercased()
        let contentType = mimeType(for: ext)

        // Rewrite external URLs in HTML/CSS so CDN resources go through the local proxy
        let body: Data
        if (ext == "html" || ext == "htm"), let text = String(data: fileData, encoding: .utf8) {
            body = Data(rewriteExternalURLsInHTML(text).utf8)
        } else if ext == "css", let text = String(data: fileData, encoding: .utf8) {
            body = Data(rewriteExternalURLsInCSS(text).utf8)
        } else {
            body = fileData
        }

        return buildResponse(
            statusCode: 200,
            statusText: "OK",
            body: body,
            contentType: contentType,
            additionalHeaders: ["Set-Cookie": authCookieHeaderValue()]
        )
    }

    // MARK: - Tmp File Serving

    /// Serves files from `tmpDirectoryURL` under the `/__doufu_tmp__/` path prefix.
    /// No URL rewriting is applied (these are binary assets like images).
    private func handleTmpFileRequest(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed",
                                 body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }

        guard let baseURL = tmpDirectoryURL else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        // Strip the /__doufu_tmp__/ prefix to get the relative path
        let relativePath = String(request.path.dropFirst(Self.tmpPathPrefix.count))
        let decoded = relativePath.removingPercentEncoding ?? relativePath

        // Prevent directory traversal
        let resolved = baseURL.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = baseURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = resolved.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        guard resolvedPath == basePath || resolvedPath.hasPrefix(prefix) else {
            return buildResponse(statusCode: 403, statusText: "Forbidden",
                                 body: Data("Forbidden".utf8), contentType: "text/plain")
        }

        guard FileManager.default.fileExists(atPath: resolved.path),
              let fileData = try? Data(contentsOf: resolved) else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        let ext = resolved.pathExtension.lowercased()
        let contentType = mimeType(for: ext)
        return buildResponse(statusCode: 200, statusText: "OK", body: fileData, contentType: contentType)
    }

    // MARK: - App Data File Serving (GET/PUT/OPTIONS)

    /// Serves and accepts files from `appDataDirectoryURL` under the `/__doufu_appdata__/` path prefix.
    /// GET reads a file, PUT writes a file (creating intermediate directories), OPTIONS returns CORS headers.
    private func handleAppDataRequest(_ request: HTTPRequest) -> Data {
        // OPTIONS — all requests are same-origin so CORS headers are not needed.
        // Returning 204 without ACAO prevents cross-origin iframes from accessing appdata.
        if request.method == "OPTIONS" {
            var header = "HTTP/1.1 204 No Content\r\n"
            header += "Content-Length: 0\r\n"
            header += "Connection: close\r\n"
            header += "\r\n"
            return Data(header.utf8)
        }

        guard request.method == "GET" || request.method == "PUT" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed",
                                 body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }

        guard let baseURL = appDataDirectoryURL else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        let relativePath = String(request.path.dropFirst(Self.appDataPathPrefix.count))
        let decoded = relativePath.removingPercentEncoding ?? relativePath

        // Prevent directory traversal
        let resolved = baseURL.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        let basePath = baseURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedPath = resolved.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"

        guard resolvedPath == basePath || resolvedPath.hasPrefix(prefix) else {
            return buildResponse(statusCode: 403, statusText: "Forbidden",
                                 body: Data("Forbidden".utf8), contentType: "text/plain")
        }

        if request.method == "GET" {
            guard FileManager.default.fileExists(atPath: resolved.path),
                  let fileData = try? Data(contentsOf: resolved) else {
                return buildResponse(statusCode: 404, statusText: "Not Found",
                                     body: Data("Not Found".utf8), contentType: "text/plain")
            }
            return buildResponse(statusCode: 200, statusText: "OK",
                                 body: fileData, contentType: "application/octet-stream")
        } else {
            // PUT — write body to file
            let body = request.body ?? Data()
            let parentDir = resolved.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            do {
                try body.write(to: resolved, options: .atomic)
            } catch {
                return buildResponse(statusCode: 500, statusText: "Internal Server Error",
                                     body: Data("Write failed".utf8), contentType: "text/plain")
            }
            // 204 No Content
            var header = "HTTP/1.1 204 No Content\r\n"
            header += "Content-Length: 0\r\n"
            header += "Connection: close\r\n"
            header += "\r\n"
            return Data(header.utf8)
        }
    }

    // MARK: - Static Bundle File Serving

    /// Serves whitelisted files from the app bundle under the `/__doufu_static__/` path prefix.
    /// Used for immutable resources like sql-wasm.js and sql-wasm.wasm.
    private func handleStaticBundleRequest(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed",
                                 body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }

        let relativePath = String(request.path.dropFirst(Self.staticBundlePathPrefix.count))
        let decoded = relativePath.removingPercentEncoding ?? relativePath

        // Whitelist of allowed bundle files
        let allowedFiles: Set<String> = ["sql-wasm.js", "sql-wasm.wasm"]
        guard allowedFiles.contains(decoded) else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        let components = decoded.split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let url = Bundle.main.url(forResource: String(components[0]), withExtension: String(components[1])),
              let fileData = try? Data(contentsOf: url) else {
            return buildResponse(statusCode: 404, statusText: "Not Found",
                                 body: Data("Not Found".utf8), contentType: "text/plain")
        }

        let ext = String(components[1]).lowercased()
        let contentType = ext == "wasm" ? "application/wasm" : "application/javascript; charset=utf-8"

        // Immutable bundle resources — cache aggressively
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(fileData.count)\r\n"
        header += "Cache-Control: public, max-age=31536000, immutable\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(fileData)
        return response
    }

    // MARK: - Response Builder

    private func buildResponse(
        statusCode: Int,
        statusText: String,
        body: Data,
        contentType: String,
        additionalHeaders: [String: String] = [:]
    ) -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Cache-Control: no-cache\r\n"
        for (name, value) in additionalHeaders {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    // MARK: - CDN Cache

    private lazy var cdnCache = CDNResourceCache()

    /// Clears all cached CDN resources from disk.
    func clearCDNCache() {
        cdnCache.clearAll()
    }

    // MARK: - URL Rewriting

    /// Rewrites external `https://` URLs in HTML content to go through the local proxy.
    private func rewriteExternalURLsInHTML(_ html: String) -> String {
        var result = html

        // Rewrite src="https://..." and href="https://..."
        let attrPattern = #"((?:src|href)\s*=\s*["'])(https://[^"']+)(["'])"#
        result = rewriteMatches(in: result, pattern: attrPattern, urlGroup: 2, prefixGroup: 1, suffixGroup: 3)

        // Rewrite url(https://...) in inline styles
        result = rewriteExternalURLsInCSS(result)

        return result
    }

    /// Rewrites external `https://` URLs in CSS `url(...)` references.
    private func rewriteExternalURLsInCSS(_ css: String) -> String {
        let urlPattern = #"(url\(\s*["']?)(https://[^"')]+)(["']?\s*\))"#
        return rewriteMatches(in: css, pattern: urlPattern, urlGroup: 2, prefixGroup: 1, suffixGroup: 3)
    }

    /// Replaces regex matches, percent-encoding the captured URL into a proxy path.
    private func rewriteMatches(in source: String, pattern: String, urlGroup: Int, prefixGroup: Int, suffixGroup: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
        let nsString = source as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var result = ""
        var lastEnd = 0

        regex.enumerateMatches(in: source, range: fullRange) { match, _, _ in
            guard let match else { return }
            let prefixRange = match.range(at: prefixGroup)
            let urlRange = match.range(at: urlGroup)
            let suffixRange = match.range(at: suffixGroup)

            // Append text before this match
            result += nsString.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))

            let prefix = nsString.substring(with: prefixRange)
            let rawURL = nsString.substring(with: urlRange)
            let suffix = nsString.substring(with: suffixRange)

            // Must encode &, =, ?, #, + so the URL doesn't break the proxy query string
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=?#+")
            let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawURL
            result += "\(prefix)/__doufu_proxy__?url=\(encoded)&cache=1\(suffix)"

            lastEnd = match.range.location + match.range.length
        }

        // Append remaining text
        result += nsString.substring(from: lastEnd)
        return result
    }

    // MARK: - MIME Types

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm":   return "text/html; charset=utf-8"
        case "css":           return "text/css; charset=utf-8"
        case "js", "mjs":     return "application/javascript; charset=utf-8"
        case "json":          return "application/json; charset=utf-8"
        case "png":           return "image/png"
        case "jpg", "jpeg":   return "image/jpeg"
        case "gif":           return "image/gif"
        case "svg":           return "image/svg+xml"
        case "webp":          return "image/webp"
        case "ico":           return "image/x-icon"
        case "woff":          return "font/woff"
        case "woff2":         return "font/woff2"
        case "ttf":           return "font/ttf"
        case "otf":           return "font/otf"
        case "mp3":           return "audio/mpeg"
        case "wav":           return "audio/wav"
        case "mp4":           return "video/mp4"
        case "webm":          return "video/webm"
        case "wasm":          return "application/wasm"
        case "xml":           return "application/xml"
        case "txt":           return "text/plain; charset=utf-8"
        case "md":            return "text/markdown; charset=utf-8"
        case "pdf":           return "application/pdf"
        default:              return "application/octet-stream"
        }
    }
}

// MARK: - CDN Resource Disk Cache

/// Disk-based cache for CDN resources, stored in `Caches/CDNCache/`.
/// Thread-safe via a serial dispatch queue. Enforces a 200 MB cap with LRU eviction.
private final class CDNResourceCache: @unchecked Sendable {

    struct CachedEntry {
        let data: Data
        let contentType: String
        let statusCode: Int
    }

    private nonisolated struct Meta: Codable {
        let contentType: String
        let statusCode: Int
        let url: String
    }

    private let cacheDir: URL
    private let queue = DispatchQueue(label: "com.doufu.cdncache")
    private let maxBytes: Int = 200 * 1024 * 1024       // 200 MB
    private let evictTargetBytes: Int = 150 * 1024 * 1024 // 150 MB

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("CDNCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: Key derivation

    private func cacheKey(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func dataFile(for key: String) -> URL { cacheDir.appendingPathComponent("\(key).data") }
    private func metaFile(for key: String) -> URL { cacheDir.appendingPathComponent("\(key).meta") }

    // MARK: Read

    func read(for url: String) -> CachedEntry? {
        queue.sync {
            let key = cacheKey(for: url)
            let df = dataFile(for: key)
            let mf = metaFile(for: key)

            guard let data = try? Data(contentsOf: df),
                  let metaData = try? Data(contentsOf: mf),
                  let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else {
                return nil
            }

            // Touch access date for LRU
            let now = Date()
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: df.path)
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: mf.path)

            return CachedEntry(data: data, contentType: meta.contentType, statusCode: meta.statusCode)
        }
    }

    // MARK: Write

    func write(for url: String, data: Data, contentType: String, statusCode: Int) {
        queue.async { [self] in
            let key = cacheKey(for: url)
            let meta = Meta(contentType: contentType, statusCode: statusCode, url: url)

            try? data.write(to: dataFile(for: key), options: .atomic)
            if let metaData = try? JSONEncoder().encode(meta) {
                try? metaData.write(to: metaFile(for: key), options: .atomic)
            }

            evictIfNeeded()
        }
    }

    // MARK: Clear

    func clearAll() {
        queue.async { [self] in
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
    }

    // MARK: Eviction

    private func evictIfNeeded() {
        // dispatchPrecondition(condition: .onQueue(queue)) — called from queue.async already
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }

        var totalSize: Int = 0
        struct FileInfo {
            let url: URL
            let size: Int
            let modified: Date
        }
        var infos: [FileInfo] = []

        for file in files {
            guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let size = vals.fileSize ?? 0
            let date = vals.contentModificationDate ?? .distantPast
            totalSize += size
            infos.append(FileInfo(url: file, size: size, modified: date))
        }

        guard totalSize > maxBytes else { return }

        // Sort oldest-accessed first
        infos.sort { $0.modified < $1.modified }

        for info in infos {
            guard totalSize > evictTargetBytes else { break }
            try? fm.removeItem(at: info.url)
            totalSize -= info.size
        }
    }
}
