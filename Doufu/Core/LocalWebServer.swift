//
//  LocalWebServer.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation
import Network

/// A lightweight HTTP server that serves static files from a project directory
/// over localhost. Also provides a reverse proxy endpoint (`/__doufu_proxy__`)
/// so that web apps can make cross-origin requests through the host app,
/// bypassing CORS restrictions transparently.
final class LocalWebServer: @unchecked Sendable {

    private let projectURL: URL
    private let preferredPort: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.doufu.localwebserver", qos: .userInitiated)
    private let urlSession: URLSession
    private(set) var port: UInt16 = 0

    init(projectURL: URL) {
        self.projectURL = projectURL
        self.preferredPort = Self.stablePort(for: projectURL.lastPathComponent)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config)
    }

    /// Derive a stable port (10000–59999) from the project ID so that
    /// the localhost origin stays the same across launches, preserving
    /// IndexedDB and other origin-keyed browser storage.
    private static func stablePort(for projectID: String) -> UInt16 {
        var hash: UInt64 = 5381
        for byte in projectID.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return UInt16(10000 + (hash % 50000))
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() throws -> UInt16 {
        // Try the stable preferred port first; fall back to any available port.
        if let p = try? startListener(on: NWEndpoint.Port(rawValue: preferredPort)!) {
            return p
        }
        return try startListener(on: .any)
    }

    private func startListener(on requestedPort: NWEndpoint.Port) throws -> UInt16 {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: requestedPort)

        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener?.port?.rawValue {
                self?.port = port
            }
        }

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

    private func routeRequest(_ request: HTTPRequest, on connection: NWConnection) {
        if request.path == "/__doufu_proxy__" {
            handleProxyRequest(request) { [weak self] response in
                self?.sendResponse(response, on: connection)
            }
        } else {
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

            // Build raw HTTP response, forwarding status and headers
            let statusText = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            var header = "HTTP/1.1 \(httpResponse.statusCode) \(statusText)\r\n"

            for (key, value) in httpResponse.allHeaderFields {
                let keyStr = String(describing: key)
                guard !Self.skipResponseHeaders.contains(keyStr.lowercased()) else { continue }
                header += "\(keyStr): \(value)\r\n"
            }
            header += "Content-Length: \(responseBody.count)\r\n"
            header += "Access-Control-Allow-Origin: *\r\n"
            header += "Connection: close\r\n"
            header += "\r\n"

            var responseData = Data(header.utf8)
            responseData.append(responseBody)
            completion(responseData)
        }.resume()
    }

    // MARK: - Static File Serving

    private func handleStaticFileRequest(_ request: HTTPRequest) -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed",
                                 body: Data("Method Not Allowed".utf8), contentType: "text/plain")
        }

        var path = request.path.removingPercentEncoding ?? request.path
        if path == "/" { path = "/index.html" }

        // Prevent directory traversal
        let resolved = projectURL.appendingPathComponent(path).standardizedFileURL
        let projectPath = projectURL.standardizedFileURL.path
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

        let contentType = mimeType(for: finalURL.pathExtension)
        return buildResponse(statusCode: 200, statusText: "OK", body: fileData, contentType: contentType)
    }

    // MARK: - Response Builder

    private func buildResponse(statusCode: Int, statusText: String, body: Data, contentType: String) -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = Data(header.utf8)
        response.append(body)
        return response
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
