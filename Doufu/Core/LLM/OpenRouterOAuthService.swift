//
//  OpenRouterOAuthService.swift
//  Doufu
//
//  Created by Claude on 2026/03/13.
//

import AuthenticationServices
import CryptoKit
import Foundation

/// Implements OpenRouter's OAuth PKCE flow using `ASWebAuthenticationSession`.
///
/// Flow:
///   1. Generate code_verifier / code_challenge (S256)
///   2. `ASWebAuthenticationSession` opens OpenRouter auth page
///   3. User authorises → redirect to `doufu://openrouter/callback?code=…`
///   4. `ASWebAuthenticationSession` intercepts the redirect and returns the URL
///   5. POST code + code_verifier to `https://openrouter.ai/api/v1/auth/keys`
///   6. Response `{ "key": "sk-or-…" }` — regular API key.
final class OpenRouterOAuthService {

    struct SignInResult {
        let apiKey: String
    }

    enum ServiceError: LocalizedError {
        case callbackMissingCode
        case exchangeFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .callbackMissingCode:
                return String(localized: "oauth.error.callback_missing_code")
            case let .exchangeFailed(message):
                return message
            case .cancelled:
                return String(localized: "oauth.error.cancelled")
            }
        }
    }

    // MARK: - Private types

    private struct PKCE {
        let verifier: String
        let challenge: String
    }

    private struct KeyExchangeResponse: Decodable {
        let key: String
    }

    // MARK: - State

    private var webAuthSession: ASWebAuthenticationSession?
    private var exchangeTask: Task<Void, Never>?

    deinit {
        cancel()
    }

    // MARK: - Public API

    /// Starts the PKCE flow. Presents an `ASWebAuthenticationSession` from the
    /// given `contextProvider` (typically the presenting view controller).
    func start(
        contextProvider: ASWebAuthenticationPresentationContextProviding,
        completion: @escaping (Result<SignInResult, Error>) -> Void
    ) {
        let pkce = Self.generatePKCE()
        let authorizeURL = buildAuthorizeURL(pkceChallenge: pkce.challenge)

        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: "doufu"
        ) { [weak self] callbackURL, error in
            guard let self else { return }

            if let error {
                // User tapped "Cancel" in the auth sheet.
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    completion(.failure(ServiceError.cancelled))
                } else {
                    completion(.failure(error))
                }
                return
            }

            guard let callbackURL else {
                completion(.failure(ServiceError.callbackMissingCode))
                return
            }

            let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                completion(.failure(ServiceError.callbackMissingCode))
                return
            }

            self.exchangeTask = Task {
                do {
                    let apiKey = try await self.exchangeCodeForKey(
                        code: code,
                        codeVerifier: pkce.verifier
                    )
                    DispatchQueue.main.async {
                        completion(.success(SignInResult(apiKey: apiKey)))
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async {
                        completion(.failure(ServiceError.cancelled))
                    }
                } catch {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        session.start()
        self.webAuthSession = session
    }

    func cancel() {
        webAuthSession?.cancel()
        webAuthSession = nil
        exchangeTask?.cancel()
        exchangeTask = nil
    }

    // MARK: - Authorize URL

    private func buildAuthorizeURL(pkceChallenge: String) -> URL {
        var components = URLComponents(string: "https://openrouter.ai/auth")!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: "https://doufu.app/auth/callback/openrouter"),
            URLQueryItem(name: "code_challenge", value: pkceChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    // MARK: - Token exchange

    private func exchangeCodeForKey(code: String, codeVerifier: String) async throws -> String {
        let endpoint = URL(string: "https://openrouter.ai/api/v1/auth/keys")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "code": code,
            "code_verifier": codeVerifier,
            "code_challenge_method": "S256"
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.exchangeFailed("Invalid response from OpenRouter.")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(data: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ServiceError.exchangeFailed("OpenRouter: \(message)")
        }

        let decoded = try JSONDecoder().decode(KeyExchangeResponse.self, from: data)
        let key = decoded.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ServiceError.exchangeFailed("OpenRouter returned an empty API key.")
        }
        return key
    }

    private func parseErrorMessage(data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        if let rawText = String(data: data, encoding: .utf8) {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        return nil
    }

    // MARK: - PKCE

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
