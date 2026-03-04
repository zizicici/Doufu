//
//  OpenAICodexOAuthService.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import CryptoKit
import Foundation
import Network

final class OpenAICodexOAuthService {

    struct SignInResult {
        let baseURLString: String
        let bearerToken: String
        let idToken: String
        let accessToken: String
        let refreshToken: String
    }

    enum ServiceError: LocalizedError {
        case alreadyRunning
        case callbackServerStartFailed
        case callbackStateMismatch
        case callbackMissingCode
        case exchangeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                return "登录流程已在进行中。"
            case .callbackServerStartFailed:
                return "无法启动本地回调服务，请稍后重试。"
            case .callbackStateMismatch:
                return "登录校验失败（state mismatch）。"
            case .callbackMissingCode:
                return "登录回调缺少授权码。"
            case let .exchangeFailed(message):
                return message
            case .cancelled:
                return "登录已取消。"
            }
        }
    }

    private struct PKCE {
        let verifier: String
        let challenge: String
    }

    private struct AuthorizationTokens: Decodable {
        let id_token: String
        let access_token: String
        let refresh_token: String
    }

    private struct TokenExchangeResponse: Decodable {
        let access_token: String
    }

    private let issuer = URL(string: "https://auth.openai.com")!
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let originator = "codex_cli_rs"
    private let callbackPath = "/auth/callback"

    private var callbackServer: LocalhostOAuthCallbackServer?
    private var expectedState: String?
    private var pkce: PKCE?
    private var completion: ((Result<SignInResult, Error>) -> Void)?
    private var exchangeTask: Task<Void, Never>?
    private var finished = false

    deinit {
        cancel()
    }

    func start(
        completion: @escaping (Result<SignInResult, Error>) -> Void
    ) throws -> URL {
        guard self.completion == nil else {
            throw ServiceError.alreadyRunning
        }

        self.completion = completion
        finished = false

        let pkce = Self.generatePKCE()
        let state = Self.generateState()
        self.pkce = pkce
        self.expectedState = state

        let callbackServer = LocalhostOAuthCallbackServer(port: 1455, callbackPath: callbackPath)
        do {
            try callbackServer.start { [weak self] callbackURL in
                self?.handleCallbackURL(callbackURL, callbackPort: callbackServer.port)
            }
        } catch {
            self.completion = nil
            throw ServiceError.callbackServerStartFailed
        }
        self.callbackServer = callbackServer

        return buildAuthorizeURL(
            callbackPort: callbackServer.port,
            state: state,
            pkceChallenge: pkce.challenge
        )
    }

    func cancel() {
        exchangeTask?.cancel()
        exchangeTask = nil
        callbackServer?.stop()
        callbackServer = nil

        if completion != nil && !finished {
            complete(.failure(ServiceError.cancelled))
        }
    }

    private func buildAuthorizeURL(
        callbackPort: UInt16,
        state: String,
        pkceChallenge: String
    ) -> URL {
        var components = URLComponents(url: issuer.appending(path: "/oauth/authorize"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURIString(callbackPort: callbackPort)),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: pkceChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator)
        ]
        return components?.url ?? issuer
    }

    private func handleCallbackURL(_ callbackURL: URL, callbackPort: UInt16) {
        guard !finished else {
            return
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        let state = items.first(where: { $0.name == "state" })?.value

        guard let expectedState, state == expectedState else {
            complete(.failure(ServiceError.callbackStateMismatch))
            return
        }

        guard let code, !code.isEmpty else {
            complete(.failure(ServiceError.callbackMissingCode))
            return
        }

        guard let pkce else {
            complete(.failure(ServiceError.exchangeFailed("登录状态无效，请重试。")))
            return
        }

        exchangeTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let redirectURI = self.redirectURIString(callbackPort: callbackPort)
                let tokens = try await self.exchangeAuthorizationCode(
                    code: code,
                    redirectURI: redirectURI,
                    codeVerifier: pkce.verifier
                )
                let bearerToken = try await self.resolvePreferredBearerToken(
                    idToken: tokens.id_token,
                    accessToken: tokens.access_token
                )

                let result = SignInResult(
                    baseURLString: "https://api.openai.com",
                    bearerToken: bearerToken,
                    idToken: tokens.id_token,
                    accessToken: tokens.access_token,
                    refreshToken: tokens.refresh_token
                )
                complete(.success(result))
            } catch is CancellationError {
                complete(.failure(ServiceError.cancelled))
            } catch {
                complete(.failure(error))
            }
        }
    }

    private func exchangeAuthorizationCode(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> AuthorizationTokens {
        let bodyItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        return try await postFormAndDecode(
            path: "/oauth/token",
            bodyItems: bodyItems,
            responseType: AuthorizationTokens.self,
            defaultErrorPrefix: "授权码换取 token 失败"
        )
    }

    private func exchangeForAPIKey(idToken: String, accessToken: String) async throws -> String {
        do {
            return try await requestAPIKeyToken(idToken: idToken, organizationID: nil)
        } catch {
            guard isMissingOrganizationIDExchangeError(error) else {
                throw error
            }

            let organizationIDs = organizationIDCandidates(idToken: idToken, accessToken: accessToken)
            var lastError: Error = error

            for organizationID in organizationIDs {
                do {
                    return try await requestAPIKeyToken(idToken: idToken, organizationID: organizationID)
                } catch {
                    lastError = error
                    guard isMissingOrganizationIDExchangeError(error) else {
                        throw error
                    }
                }
            }

            if organizationIDs.isEmpty {
                throw ServiceError.exchangeFailed(
                    "Bearer Token 获取失败：登录信息缺少 organization_id。请确认账号已开通 OpenAI Platform 并重试。"
                )
            }

            throw lastError
        }
    }

    private func resolvePreferredBearerToken(idToken: String, accessToken: String) async throws -> String {
        if let apiKeyLikeToken = try? await exchangeForAPIKey(idToken: idToken, accessToken: accessToken) {
            let normalizedAPIKeyLikeToken = apiKeyLikeToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedAPIKeyLikeToken.isEmpty {
                return normalizedAPIKeyLikeToken
            }
        }

        let normalizedAccessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAccessToken.isEmpty else {
            throw ServiceError.exchangeFailed("登录成功，但未获取到可用的 Bearer Token。")
        }
        return normalizedAccessToken
    }

    private func requestAPIKeyToken(idToken: String, organizationID: String?) async throws -> String {
        var bodyItems = [
            URLQueryItem(
                name: "grant_type",
                value: "urn:ietf:params:oauth:grant-type:token-exchange"
            ),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "requested_token", value: "openai-api-key"),
            URLQueryItem(name: "subject_token", value: idToken),
            URLQueryItem(
                name: "subject_token_type",
                value: "urn:ietf:params:oauth:token-type:id_token"
            )
        ]

        if let organizationID {
            bodyItems.append(URLQueryItem(name: "organization_id", value: organizationID))
        }

        let exchangeResponse: TokenExchangeResponse = try await postFormAndDecode(
            path: "/oauth/token",
            bodyItems: bodyItems,
            responseType: TokenExchangeResponse.self,
            defaultErrorPrefix: "Bearer Token 获取失败"
        )
        return exchangeResponse.access_token
    }

    private func isMissingOrganizationIDExchangeError(_ error: Error) -> Bool {
        guard let serviceError = error as? ServiceError else {
            return false
        }
        guard case let .exchangeFailed(message) = serviceError else {
            return false
        }

        let loweredMessage = message.lowercased()
        let mentionsOrganizationID =
            loweredMessage.contains("organization_id") ||
            loweredMessage.contains("organization id")
        return mentionsOrganizationID && loweredMessage.contains("missing")
    }

    private func organizationIDCandidates(idToken: String, accessToken: String) -> [String] {
        var candidates: [String] = []
        var seen = Set<String>()
        let claimsList = [
            parseOpenAIAuthClaims(fromJWT: idToken),
            parseOpenAIAuthClaims(fromJWT: accessToken)
        ]

        for claims in claimsList {
            appendCandidate(value: claims["organization_id"], to: &candidates, seen: &seen)
            appendCandidate(value: claims["org_id"], to: &candidates, seen: &seen)
            appendCandidate(value: claims["default_organization_id"], to: &candidates, seen: &seen)

            if let ids = claims["organization_ids"] as? [String] {
                ids.forEach { appendCandidate(value: $0, to: &candidates, seen: &seen) }
            }

            if let organizations = claims["organizations"] as? [[String: Any]] {
                for organization in organizations {
                    appendCandidate(value: organization["organization_id"], to: &candidates, seen: &seen)
                    appendCandidate(value: organization["id"], to: &candidates, seen: &seen)
                }
            }
        }

        for claims in claimsList {
            appendCandidate(value: claims["chatgpt_account_id"], to: &candidates, seen: &seen)
            appendCandidate(value: claims["account_id"], to: &candidates, seen: &seen)
        }

        return candidates
    }

    private func appendCandidate(value: Any?, to candidates: inout [String], seen: inout Set<String>) {
        guard let rawValue = value as? String else {
            return
        }
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            return
        }
        guard !seen.contains(candidate) else {
            return
        }
        seen.insert(candidate)
        candidates.append(candidate)
    }

    private func parseOpenAIAuthClaims(fromJWT token: String) -> [String: Any] {
        guard
            let payload = Self.decodeJWTPayload(token),
            let payloadObject = payload as? [String: Any]
        else {
            return [:]
        }

        if let authClaims = payloadObject["https://api.openai.com/auth"] as? [String: Any] {
            return authClaims
        }
        return payloadObject
    }

    private static func decodeJWTPayload(_ token: String) -> Any? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }
        guard let payloadData = decodeBase64URL(String(parts[1])) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: payloadData)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        if paddingLength > 0 {
            base64.append(String(repeating: "=", count: paddingLength))
        }
        return Data(base64Encoded: base64)
    }

    private func postFormAndDecode<ResponseType: Decodable>(
        path: String,
        bodyItems: [URLQueryItem],
        responseType: ResponseType.Type,
        defaultErrorPrefix: String
    ) async throws -> ResponseType {
        let endpoint = issuer.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.encodeFormBody(bodyItems)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.exchangeFailed("\(defaultErrorPrefix)：服务响应无效。")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = parseEndpointErrorMessage(data: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ServiceError.exchangeFailed("\(defaultErrorPrefix)：\(message)")
        }

        do {
            return try JSONDecoder().decode(responseType, from: data)
        } catch {
            throw ServiceError.exchangeFailed("\(defaultErrorPrefix)：响应解析失败。")
        }
    }

    private func parseEndpointErrorMessage(data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorDescription = json["error_description"] as? String,
            !errorDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return errorDescription
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObject = json["error"] as? [String: Any],
            let message = errorObject["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorCode = json["error"] as? String,
            !errorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return errorCode
        }

        if let rawText = String(data: data, encoding: .utf8) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    private func redirectURIString(callbackPort: UInt16) -> String {
        "http://localhost:\(callbackPort)\(callbackPath)"
    }

    private func complete(_ result: Result<SignInResult, Error>) {
        guard !finished else {
            return
        }
        finished = true

        exchangeTask?.cancel()
        exchangeTask = nil

        callbackServer?.stop()
        callbackServer = nil

        let completion = self.completion
        self.completion = nil

        DispatchQueue.main.async {
            completion?(result)
        }
    }

    private static func encodeFormBody(_ items: [URLQueryItem]) -> Data? {
        let body = items
            .map { item -> String in
                let value = item.value ?? ""
                return "\(percentEncode(item.name))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private static func percentEncode(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    private static func generateState() -> String {
        randomURLSafeBase64(byteCount: 32)
    }

    private static func generatePKCE() -> PKCE {
        let verifier = randomURLSafeBase64(byteCount: 32)
        let verifierData = Data(verifier.utf8)
        let hashed = SHA256.hash(data: verifierData)
        let challenge = Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return PKCE(verifier: verifier, challenge: challenge)
    }

    private static func randomURLSafeBase64(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class LocalhostOAuthCallbackServer {

    enum ServerError: Error {
        case listenerSetupFailed
        case invalidRequest
    }

    private let portValue: UInt16
    private let callbackPath: String
    private let queue = DispatchQueue(label: "com.zizicici.doufu.oauth-callback")

    private var listener: NWListener?
    private var callback: ((URL) -> Void)?
    private var completed = false

    init(port: UInt16, callbackPath: String) {
        self.portValue = port
        self.callbackPath = callbackPath
    }

    var port: UInt16 {
        portValue
    }

    func start(callback: @escaping (URL) -> Void) throws {
        guard listener == nil else {
            throw ServerError.listenerSetupFailed
        }

        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw ServerError.listenerSetupFailed
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: nwPort)
        } catch {
            throw ServerError.listenerSetupFailed
        }

        self.callback = callback
        self.listener = listener
        self.completed = false

        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.stop()
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        callback = nil
        completed = false
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }

            if let requestText = String(data: buffer, encoding: .utf8), requestText.contains("\r\n\r\n") {
                handleParsedRequest(requestText, connection: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func handleParsedRequest(_ requestText: String, connection: NWConnection) {
        let requestLine = requestText.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTMLResponse(connection: connection, statusCode: 400, html: "<html><body>Bad Request</body></html>")
            return
        }

        let target = String(parts[1])
        guard target.hasPrefix(callbackPath) else {
            sendHTMLResponse(connection: connection, statusCode: 404, html: "<html><body>Not Found</body></html>")
            return
        }

        let callbackURL = URL(string: "http://localhost:\(portValue)\(target)")
        sendHTMLResponse(
            connection: connection,
            statusCode: 200,
            html: "<html><body><h3>Login complete.</h3><p>You can return to Doufu now.</p></body></html>"
        )

        guard let callbackURL else {
            return
        }

        guard !completed else {
            return
        }
        completed = true

        DispatchQueue.main.async { [weak self] in
            self?.callback?(callbackURL)
        }
    }

    private func sendHTMLResponse(
        connection: NWConnection,
        statusCode: Int,
        html: String
    ) {
        let reasonPhrase: String
        switch statusCode {
        case 200:
            reasonPhrase = "OK"
        case 400:
            reasonPhrase = "Bad Request"
        case 404:
            reasonPhrase = "Not Found"
        default:
            reasonPhrase = "OK"
        }

        let body = Data(html.utf8)
        let headers = """
        HTTP/1.1 \(statusCode) \(reasonPhrase)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """

        var responseData = Data(headers.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
