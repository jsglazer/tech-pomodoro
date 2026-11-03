import CryptoKit
import Foundation
import Security
import TechPomodoroCore

/// The APNs auth key the Mac signs its pushes with. Never in the repo: imported once from the .p8 file
/// Apple lets you download, and kept in the login Keychain.
struct APNsCredentials: Equatable, Sendable {
    var privateKeyPEM: String
    var keyID: String
    var teamID: String

    /// Parses the key, so a bad file is refused at import rather than at the first push.
    func signingKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }

    /// `AuthKey_ABCDE12345.p8` → `ABCDE12345`.
    static func keyID(fromFileName name: String) -> String? {
        guard let match = name.range(of: #"AuthKey_([A-Z0-9]{10})\.p8$"#, options: .regularExpression) else { return nil }
        return String(name[match].dropFirst("AuthKey_".count).dropLast(".p8".count))
    }

    /// The Team ID this app is signed with, so the field needs no typing. Nil for an unsigned build.
    static func signingTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// Generic-password items in the login Keychain, one per field.
enum APNsKeychain {
    private static let service = "com.jsglazer.tech-pomodoro.apns"

    static func load() -> APNsCredentials? {
        guard let pem = read("privateKey"), let keyID = read("keyID"), let teamID = read("teamID") else { return nil }
        return APNsCredentials(privateKeyPEM: pem, keyID: keyID, teamID: teamID)
    }

    static func save(_ credentials: APNsCredentials) throws {
        try write("privateKey", credentials.privateKeyPEM)
        try write("keyID", credentials.keyID)
        try write("teamID", credentials.teamID)
    }

    static func delete() {
        for account in ["privateKey", "keyID", "teamID"] {
            SecItemDelete(query(account) as CFDictionary)
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ account: String, _ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "tech-pomodoro APNs \(account)"
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// An APNs rejection, worded for the status line.
struct APNsError: LocalizedError {
    let status: Int
    let reason: String
    var errorDescription: String? { "APNs \(status): \(reason)" }

    /// The channel is gone on Apple's side; the next push creates a new one.
    var isBadChannel: Bool { reason.localizedCaseInsensitiveContains("channel") }
}

/// Sends Live Activity pushes over HTTP/2 with token-based (JWT) auth. `URLSession` negotiates HTTP/2
/// with Apple's hosts on its own.
actor APNsClient {

    static let bundleID = "com.jsglazer.tech-pomodoro.ios"
    static let liveActivityTopic = "\(bundleID).push-type.liveactivity"

    private let session = URLSession(configuration: .ephemeral)
    private var cachedToken: (jwt: String, issuedAt: Date, keyID: String)?

    // MARK: - Pushes

    /// A push-to-start to one iPhone's token.
    func start(token: String, environment: APNsEnvironment, payload: Data, credentials: APNsCredentials) async throws {
        let url = URL(string: "https://\(Self.pushHost(environment))/3/device/\(token)")!
        var request = URLRequest(url: url)
        request.setValue(Self.liveActivityTopic, forHTTPHeaderField: "apns-topic")
        try await send(request, body: payload, credentials: credentials)
    }

    /// One update or end to every activity subscribed to the channel.
    func broadcast(channelID: String, environment: APNsEnvironment, payload: Data, credentials: APNsCredentials) async throws {
        let url = URL(string: "https://\(Self.pushHost(environment))/4/broadcasts/apps/\(Self.bundleID)")!
        var request = URLRequest(url: url)
        request.setValue(channelID, forHTTPHeaderField: "apns-channel-id")
        try await send(request, body: payload, credentials: credentials)
    }

    /// Creates a broadcast channel that keeps its most recent message, so an iPhone that was offline
    /// gets the current state when it reconnects. Returns the channel id.
    func createChannel(environment: APNsEnvironment, credentials: APNsCredentials) async throws -> String {
        let url = URL(string: "https://\(Self.channelHost(environment))/1/apps/\(Self.bundleID)/channels")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(try jwt(credentials))", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"message-storage-policy":1,"push-type":"LiveActivity"}"#.utf8)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard let http, (200..<300).contains(http.statusCode),
              let channelID = http.value(forHTTPHeaderField: "apns-channel-id"), !channelID.isEmpty else {
            throw Self.error(status: http?.statusCode ?? 0, data: data)
        }
        return channelID
    }

    private func send(_ request: URLRequest, body: Data, credentials: APNsCredentials) async throws {
        var request = request
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("bearer \(try jwt(credentials))", forHTTPHeaderField: "authorization")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        // Every mirror push is a state change the user just made or a boundary they should see now.
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.error(status: status, data: data) }
    }

    private static func error(status: Int, data: Data) -> APNsError {
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
        return APNsError(status: status, reason: reason ?? (String(data: data, encoding: .utf8) ?? "no reason given"))
    }

    // MARK: - Hosts

    static func pushHost(_ environment: APNsEnvironment) -> String {
        environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    static func channelHost(_ environment: APNsEnvironment) -> String {
        environment == .production ? "api-manage-broadcast.push.apple.com:2196" : "api-manage-broadcast.sandbox.push.apple.com:2195"
    }

    // MARK: - Provider token

    /// An ES256 JWT, reused for 40 minutes: APNs refuses one older than an hour and throttles a new
    /// one more often than every 20 minutes.
    private func jwt(_ credentials: APNsCredentials) throws -> String {
        let now = Date()
        if let cached = cachedToken, cached.keyID == credentials.keyID, now.timeIntervalSince(cached.issuedAt) < 40 * 60 {
            return cached.jwt
        }
        let header = Self.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID], options: [.sortedKeys]))
        let claims = Self.base64URL(try JSONSerialization.data(withJSONObject: ["iss": credentials.teamID, "iat": Int(now.timeIntervalSince1970)], options: [.sortedKeys]))
        let signingInput = "\(header).\(claims)"
        let signature = try credentials.signingKey().signature(for: Data(signingInput.utf8))
        let token = "\(signingInput).\(Self.base64URL(signature.rawRepresentation))"
        cachedToken = (token, now, credentials.keyID)
        return token
    }

    func resetToken() {
        cachedToken = nil
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
