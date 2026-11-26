import CryptoKit
import Foundation
import Security
import TechPomodoroCore

/// The APNs auth key the Mac signs its pushes with. Never in the repo: imported once from the .p8 file
/// Apple lets you download, and kept in the login Keychain.
public struct APNsCredentials: Codable, Equatable, Sendable {
    public var privateKeyPEM: String
    public var keyID: String
    public var teamID: String

    public init(privateKeyPEM: String, keyID: String, teamID: String) {
        self.privateKeyPEM = privateKeyPEM
        self.keyID = keyID
        self.teamID = teamID
    }

    /// Parses the key, so a bad file is refused at import rather than at the first push.
    public func signingKey() throws -> P256.Signing.PrivateKey {
        try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
    }

    /// `AuthKey_ABCDE12345.p8` → `ABCDE12345`.
    public static func keyID(fromFileName name: String) -> String? {
        guard let match = name.range(of: #"AuthKey_([A-Z0-9]{10})\.p8$"#, options: .regularExpression) else { return nil }
        return String(name[match].dropFirst("AuthKey_".count).dropLast(".p8".count))
    }

    /// The Team ID this app is signed with, so the field needs no typing. Nil for an unsigned build.
    public static func signingTeamID() -> String? {
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

// MARK: - Keychain

/// Where the credentials' bytes live. The Keychain in the app; an in-memory store in the tests.
public protocol APNsSecretStore: Sendable {
    func read(_ account: String) -> Data?
    func write(_ account: String, _ data: Data) throws
    func delete(_ account: String)
}

/// Generic-password items in the login Keychain under one service.
public struct KeychainSecretStore: APNsSecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func write(_ account: String, _ data: Data) throws {
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

    public func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    public struct KeychainError: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? {
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
        }
    }
}

/// The credentials as ONE Keychain item holding a JSON blob, so the key, Key ID and Team ID are
/// written together or not at all: a failed save can never leave a mismatched set behind.
///
/// Builds up to 1.0.30 kept three items (`privateKey`, `keyID`, `teamID`). A complete legacy set is
/// read once, rewritten as the blob, and the old items removed; an incomplete one is ignored.
public struct APNsKeychain: Sendable {

    public static let standard = APNsKeychain(store: KeychainSecretStore(service: "com.jsglazer.tech-pomodoro.apns"))

    static let blobAccount = "credentials"
    static let legacyAccounts = ["privateKey", "keyID", "teamID"]

    private let store: any APNsSecretStore

    public init(store: any APNsSecretStore) {
        self.store = store
    }

    public func load() -> APNsCredentials? {
        if let data = store.read(Self.blobAccount) {
            return try? JSONDecoder().decode(APNsCredentials.self, from: data)
        }
        let legacy = Self.legacyAccounts.map { store.read($0).flatMap { String(data: $0, encoding: .utf8) } }
        guard let pem = legacy[0], let keyID = legacy[1], let teamID = legacy[2] else { return nil }
        let credentials = APNsCredentials(privateKeyPEM: pem, keyID: keyID, teamID: teamID)
        // Best effort: on failure the legacy items stay and this runs again next launch.
        try? save(credentials)
        return credentials
    }

    public func save(_ credentials: APNsCredentials) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.write(Self.blobAccount, try encoder.encode(credentials))
        for account in Self.legacyAccounts { store.delete(account) }
    }

    public func delete() {
        store.delete(Self.blobAccount)
        for account in Self.legacyAccounts { store.delete(account) }
    }
}

// MARK: - Errors

/// An APNs rejection, worded for the status line.
public struct APNsError: LocalizedError, Equatable {
    public let status: Int
    public let reason: String

    public init(status: Int, reason: String) {
        self.status = status
        self.reason = reason
    }

    public var errorDescription: String? { "APNs \(status): \(reason)" }

    /// APNs reasons meaning the broadcast channel no longer exists on Apple's side.
    static let badChannelReasons: Set<String> = ["BadChannelId", "ChannelNotRegistered"]
    /// APNs reasons meaning the provider token (JWT) itself was refused.
    static let providerTokenReasons: Set<String> = ["ExpiredProviderToken", "InvalidProviderToken"]

    /// The channel is gone on Apple's side; the next push creates a new one. Only the specific
    /// reasons (or 410 Gone): a malformed request such as `MissingChannelId` is a bug, and making a
    /// fresh channel for it would orphan every activity on the old one.
    public var isBadChannel: Bool {
        status == 410 || Self.badChannelReasons.contains(reason)
    }

    /// The cached JWT was refused: sign a fresh one.
    public var isProviderTokenRejected: Bool {
        status == 403 && Self.providerTokenReasons.contains(reason)
    }

    /// A push-to-start token that is not hex never leaves this Mac.
    public static let invalidDeviceToken = APNsError(status: 0, reason: "Invalid push-to-start token (not hex)")
}

// MARK: - Client

/// Sends Live Activity pushes over HTTP/2 with token-based (JWT) auth. `URLSession` negotiates HTTP/2
/// with Apple's hosts on its own.
public actor APNsClient {

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let bundleID = "com.jsglazer.tech-pomodoro.ios"
    public static let liveActivityTopic = "\(bundleID).push-type.liveactivity"
    /// APNs refuses a token older than an hour and throttles a new one more often than every 20 minutes.
    static let tokenLifetime: TimeInterval = 40 * 60

    private let transport: Transport
    private let now: @Sendable () -> Date

    /// The JWT is cached per key: Key ID, Team ID and the key itself, so correcting any one of them
    /// signs the very next request with the new values, whatever order the reset arrives in.
    private struct TokenKey: Equatable {
        let keyID: String
        let teamID: String
        let pem: String

        init(_ credentials: APNsCredentials) {
            keyID = credentials.keyID
            teamID = credentials.teamID
            pem = credentials.privateKeyPEM
        }
    }

    private var cachedToken: (jwt: String, issuedAt: Date, key: TokenKey)?

    public init(transport: Transport? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        if let transport {
            self.transport = transport
        } else {
            let session = URLSession(configuration: .ephemeral)
            self.transport = { request in try await session.data(for: request) }
        }
        self.now = now
    }

    // MARK: Pushes

    /// A push-to-start to one iPhone's token.
    public func start(token: String, environment: APNsEnvironment, payload: Data, credentials: APNsCredentials) async throws {
        guard Self.isValidDeviceToken(token),
              let url = URL(string: "https://\(Self.pushHost(environment))/3/device/\(token)") else {
            throw APNsError.invalidDeviceToken
        }
        var request = URLRequest(url: url)
        request.setValue(Self.liveActivityTopic, forHTTPHeaderField: "apns-topic")
        try await send(request, body: payload, credentials: credentials)
    }

    /// One update or end to every activity subscribed to the channel.
    public func broadcast(channelID: String, environment: APNsEnvironment, payload: Data, credentials: APNsCredentials) async throws {
        guard let url = URL(string: "https://\(Self.pushHost(environment))/4/broadcasts/apps/\(Self.bundleID)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(channelID, forHTTPHeaderField: "apns-channel-id")
        try await send(request, body: payload, credentials: credentials)
    }

    /// Creates a broadcast channel that keeps its most recent message, so an iPhone that was offline
    /// gets the current state when it reconnects. Returns the channel id.
    public func createChannel(environment: APNsEnvironment, credentials: APNsCredentials) async throws -> String {
        var request = URLRequest(url: Self.channelsURL(environment))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"message-storage-policy":1,"push-type":"LiveActivity"}"#.utf8)
        let (data, http) = try await perform(request, credentials: credentials)
        guard (200..<300).contains(http.statusCode),
              let channelID = http.value(forHTTPHeaderField: "apns-channel-id"), !channelID.isEmpty else {
            throw Self.error(status: http.statusCode, data: data)
        }
        return channelID
    }

    /// Deletes a channel this Mac no longer uses (lost a claim race, or replaced for another
    /// environment), so they do not pile up against Apple's per-app channel limit. A channel Apple
    /// already forgot counts as deleted.
    public func deleteChannel(channelID: String, environment: APNsEnvironment, credentials: APNsCredentials) async throws {
        var request = URLRequest(url: Self.channelsURL(environment))
        request.httpMethod = "DELETE"
        request.setValue(channelID, forHTTPHeaderField: "apns-channel-id")
        let (data, http) = try await perform(request, credentials: credentials)
        guard (200..<300).contains(http.statusCode) || http.statusCode == 404 || http.statusCode == 410 else {
            let error = Self.error(status: http.statusCode, data: data)
            if error.isBadChannel { return }
            throw error
        }
    }

    private func send(_ request: URLRequest, body: Data, credentials: APNsCredentials) async throws {
        var request = request
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        // Every mirror push is a state change the user just made or a boundary they should see now.
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, http) = try await perform(request, credentials: credentials)
        guard http.statusCode == 200 else { throw Self.error(status: http.statusCode, data: data) }
    }

    /// Signs and sends. A 403 that refuses the provider token drops the cached JWT and tries once more
    /// with a fresh one, rather than reusing the refused token until it ages out.
    private func perform(_ request: URLRequest, credentials: APNsCredentials) async throws -> (Data, HTTPURLResponse) {
        let first = try await signedSend(request, credentials: credentials)
        guard Self.error(status: first.1.statusCode, data: first.0).isProviderTokenRejected else { return first }
        resetToken()
        return try await signedSend(request, credentials: credentials)
    }

    private func signedSend(_ request: URLRequest, credentials: APNsCredentials) async throws -> (Data, HTTPURLResponse) {
        var signed = request
        signed.setValue("bearer \(try jwt(credentials))", forHTTPHeaderField: "authorization")
        let (data, response) = try await transport(signed)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    static func error(status: Int, data: Data) -> APNsError {
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
        return APNsError(status: status, reason: reason ?? (String(data: data, encoding: .utf8) ?? "no reason given"))
    }

    // MARK: Validation

    /// Push-to-start tokens are hex of even length (32 bytes for device tokens; push-to-start tokens
    /// run longer). Anything else would be interpolated into the URL path, so it is refused.
    public static func isValidDeviceToken(_ token: String) -> Bool {
        guard (16...1024).contains(token.count), token.count.isMultiple(of: 2) else { return false }
        return token.allSatisfy(\.isHexDigit)
    }

    // MARK: Hosts

    public static func pushHost(_ environment: APNsEnvironment) -> String {
        environment == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    public static func channelHost(_ environment: APNsEnvironment) -> String {
        environment == .production ? "api-manage-broadcast.push.apple.com:2196" : "api-manage-broadcast.sandbox.push.apple.com:2195"
    }

    static func channelsURL(_ environment: APNsEnvironment) -> URL {
        // Both parts are constants, so this always parses.
        URL(string: "https://\(channelHost(environment))/1/apps/\(bundleID)/channels")!
    }

    // MARK: Provider token

    /// An ES256 JWT, reused for 40 minutes for the same credentials.
    func jwt(_ credentials: APNsCredentials) throws -> String {
        let now = now()
        let key = TokenKey(credentials)
        if let cached = cachedToken, cached.key == key, now.timeIntervalSince(cached.issuedAt) < Self.tokenLifetime {
            return cached.jwt
        }
        let header = Self.base64URL(try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID], options: [.sortedKeys]))
        let claims = Self.base64URL(try JSONSerialization.data(withJSONObject: ["iss": credentials.teamID, "iat": Int(now.timeIntervalSince1970)], options: [.sortedKeys]))
        let signingInput = "\(header).\(claims)"
        let signature = try credentials.signingKey().signature(for: Data(signingInput.utf8))
        let token = "\(signingInput).\(Self.base64URL(signature.rawRepresentation))"
        cachedToken = (token, now, key)
        return token
    }

    public func resetToken() {
        cachedToken = nil
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
