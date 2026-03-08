//
//  LocalWebServer.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import Foundation
import Network

/// A lightweight HTTP server that serves static files from a project directory
/// over localhost. This enables ES Modules, fetch(), Service Workers, and other
/// features that require an HTTP origin instead of file://.
final class LocalWebServer: @unchecked Sendable {

    private let projectURL: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.doufu.localwebserver", qos: .userInitiated)
    private(set) var port: UInt16 = 0

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    deinit {
        stop()
    }

    /// Start the server on a random available port.
    /// Returns the port number.
    @discardableResult
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: .any)

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

        // Wait briefly for the listener to become ready and get its port.
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

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }

            if let requestString = String(data: data, encoding: .utf8) {
                let response = self.handleHTTPRequest(requestString)
                self.sendResponse(response, on: connection)
            } else {
                connection.cancel()
            }

            if isComplete {
                connection.cancel()
            }
        }
    }

    private func sendResponse(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - HTTP Parsing & Response

    private func handleHTTPRequest(_ request: String) -> Data {
        // Parse the request line: "GET /path HTTP/1.1"
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return buildResponse(statusCode: 400, statusText: "Bad Request", body: "Bad Request".data(using: .utf8)!, contentType: "text/plain")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return buildResponse(statusCode: 405, statusText: "Method Not Allowed", body: "Method Not Allowed".data(using: .utf8)!, contentType: "text/plain")
        }

        var path = String(parts[1])

        // Strip query string
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<queryIndex])
        }

        // URL-decode the path
        path = path.removingPercentEncoding ?? path

        // Default to index.html
        if path == "/" {
            path = "/index.html"
        }

        // Resolve the file path, preventing directory traversal.
        let resolved = projectURL.appendingPathComponent(path).standardizedFileURL
        let projectPath = projectURL.standardizedFileURL.path
        let resolvedPath = resolved.path

        let prefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard resolvedPath == projectPath || resolvedPath.hasPrefix(prefix) else {
            return buildResponse(statusCode: 403, statusText: "Forbidden", body: "Forbidden".data(using: .utf8)!, contentType: "text/plain")
        }

        // If it's a directory, try index.html inside it
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir)

        let finalURL: URL
        if exists && isDir.boolValue {
            finalURL = resolved.appendingPathComponent("index.html")
        } else {
            finalURL = resolved
        }

        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            return buildResponse(statusCode: 404, statusText: "Not Found", body: "Not Found".data(using: .utf8)!, contentType: "text/plain")
        }

        guard let fileData = try? Data(contentsOf: finalURL) else {
            return buildResponse(statusCode: 500, statusText: "Internal Server Error", body: "Read Error".data(using: .utf8)!, contentType: "text/plain")
        }

        let contentType = mimeType(for: finalURL.pathExtension)
        return buildResponse(statusCode: 200, statusText: "OK", body: fileData, contentType: contentType)
    }

    private func buildResponse(statusCode: Int, statusText: String, body: Data, contentType: String) -> Data {
        var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"

        var response = header.data(using: .utf8)!
        response.append(body)
        return response
    }

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
