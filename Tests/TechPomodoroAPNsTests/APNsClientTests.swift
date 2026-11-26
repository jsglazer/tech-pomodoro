import CryptoKit
import Foundation
import Testing
import TechPomodoroCore
@testable import TechPomodoroAPNs

// APNs signing, Keychain storage and error handling, now reachable from the tests because they live
// in their own library target. Regression tests for the 2026-11-11 audit (Update016).

final class MemorySecretStore: APNsSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failWritesTo: Set<String> = []

    var accounts: Set<String> { lock.withLock { Set(items.keys) } }

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }

    func write(_ account: String, _ data: Data) throws {
        if failWritesTo.contains(account) { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { items[account] = data }
    }

    func delete(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// Answers each request with the next scripted response and keeps the requests.
actor FakeAPNs {
    private var responses: [(status: Int, body: String, headers: [String: String])]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [(status: Int, body: String, headers: [String: String])]) {
        self.responses = responses
    }

    func respond(_ request: URLRequest) -> (Data, URLResponse) {
        requests.append(request)
        let next: (status: Int, body: String, headers: [String: String]) = responses.isEmpty ? (200, "", [:]) : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/2", headerFields: next.headers)!
        return (Data(next.body.utf8), response)
    }
}

private func makeCredentials(teamID: String = "TEAM123456") -> APNsCredentials {
    APNsCredentials(privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, keyID: "KEY1234567", teamID: teamID)
}

private func base64URLDecode(_ text: String) -> Data? {
    var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while !base.count.isMultiple(of: 4) { base += "=" }
    return Data(base64Encoded: base)
}

@Suite("APNs Keychain storage")
struct APNsKeychainTests {
    @Test func credentialsAreOneItem() throws {
        let store = MemorySecretStore()
        let keychain = APNsKeychain(store: store)
        let credentials = makeCredentials()
        try keychain.save(credentials)
        #expect(store.accounts == ["credentials"])
        #expect(keychain.load() == credentials)
    }

    @Test func aFailedSaveLeavesTheOldSetWhole() throws {
        let store = MemorySecretStore()
        let keychain = APNsKeychain(store: store)
        let old = makeCredentials()
        try keychain.save(old)
        store.failWritesTo = ["credentials"]
        #expect(throws: (any Error).self) { try keychain.save(makeCredentials(teamID: "OTHER12345")) }
        #expect(keychain.load() == old)
    }

    @Test func aLegacyThreeItemSetIsMigrated() {
        let store = MemorySecretStore()
        let credentials = makeCredentials()
        try? store.write("privateKey", Data(credentials.privateKeyPEM.utf8))
        try? store.write("keyID", Data(credentials.keyID.utf8))
        try? store.write("teamID", Data(credentials.teamID.utf8))
        let keychain = APNsKeychain(store: store)
        #expect(keychain.load() == credentials)
        #expect(store.accounts == ["credentials"])
    }

    @Test func anIncompleteLegacySetIsIgnored() {
        let store = MemorySecretStore()
        try? store.write("privateKey", Data("pem".utf8))
        try? store.write("keyID", Data("KEY1234567".utf8))
        #expect(APNsKeychain(store: store).load() == nil)
    }

    @Test func deleteRemovesEverything() throws {
        let store = MemorySecretStore()
        let keychain = APNsKeychain(store: store)
        try keychain.save(makeCredentials())
        try? store.write("teamID", Data("stale".utf8))
        keychain.delete()
        #expect(store.accounts.isEmpty)
    }
}

@Suite("APNs provider token")
struct APNsTokenTests {
    @Test func theJWTIsAValidES256Token() async throws {
        let key = P256.Signing.PrivateKey()
        let credentials = APNsCredentials(privateKeyPEM: key.pemRepresentation, keyID: "KEY1234567", teamID: "TEAM123456")
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let client = APNsClient(transport: { _ in throw URLError(.notConnectedToInternet) }, now: { clock.now })
        let jwt = try await client.jwt(credentials)
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: try #require(base64URLDecode(parts[0]))) as? [String: Any]
        let claims = try JSONSerialization.jsonObject(with: try #require(base64URLDecode(parts[1]))) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "KEY1234567")
        #expect(claims?["iss"] as? String == "TEAM123456")
        #expect(claims?["iat"] as? Int == 1_800_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(base64URLDecode(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func theTokenIsCachedPerCredentials() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let client = APNsClient(transport: { _ in throw URLError(.notConnectedToInternet) }, now: { clock.now })
        let credentials = makeCredentials()
        let first = try await client.jwt(credentials)
        clock.advance(60)
        #expect(try await client.jwt(credentials) == first)

        // Correcting only the Team ID must sign the very next push with the new `iss`.
        var corrected = credentials
        corrected.teamID = "NEWTEAM123"
        let second = try await client.jwt(corrected)
        #expect(second != first)
        let claims = try JSONSerialization.jsonObject(with: try #require(base64URLDecode(String(second.split(separator: ".")[1])))) as? [String: Any]
        #expect(claims?["iss"] as? String == "NEWTEAM123")
    }

    @Test func theTokenIsRenewedAfterItsLifetime() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let client = APNsClient(transport: { _ in throw URLError(.notConnectedToInternet) }, now: { clock.now })
        let credentials = makeCredentials()
        let first = try await client.jwt(credentials)
        clock.advance(APNsClient.tokenLifetime + 1)
        #expect(try await client.jwt(credentials) != first)
    }

    @Test func aRefusedProviderTokenIsReplacedAndRetriedOnce() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let fake = FakeAPNs([(403, #"{"reason":"ExpiredProviderToken"}"#, [:]), (200, "", [:])])
        let client = APNsClient(transport: { request in await fake.respond(request) }, now: { clock.now })
        let credentials = makeCredentials()
        // A cached token from earlier in the window.
        _ = try await client.jwt(credentials)
        clock.advance(5)
        try await client.broadcast(channelID: "ch", environment: .production, payload: Data("{}".utf8), credentials: credentials)
        let requests = await fake.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "authorization") != requests[1].value(forHTTPHeaderField: "authorization"))
    }

    @Test func aSecondRefusalIsReported() async {
        let fake = FakeAPNs([(403, #"{"reason":"InvalidProviderToken"}"#, [:]), (403, #"{"reason":"InvalidProviderToken"}"#, [:])])
        let client = APNsClient(transport: { request in await fake.respond(request) })
        await #expect(throws: APNsError(status: 403, reason: "InvalidProviderToken")) {
            try await client.broadcast(channelID: "ch", environment: .production, payload: Data("{}".utf8), credentials: makeCredentials())
        }
        #expect(await fake.requests.count == 2)
    }
}

@Suite("APNs errors and validation")
struct APNsValidationTests {
    @Test func onlyChannelGoneReasonsCountAsABadChannel() {
        #expect(APNsError(status: 400, reason: "BadChannelId").isBadChannel)
        #expect(APNsError(status: 410, reason: "Unregistered").isBadChannel)
        #expect(!APNsError(status: 400, reason: "MissingChannelId").isBadChannel)
        #expect(!APNsError(status: 400, reason: "BadPushChannelTopic").isBadChannel)
    }

    @Test func pushToStartTokensMustBeHex() {
        #expect(APNsClient.isValidDeviceToken(String(repeating: "ab12", count: 16)))
        #expect(!APNsClient.isValidDeviceToken("abc/../3/device"))
        #expect(!APNsClient.isValidDeviceToken("zz" + String(repeating: "0", count: 62)))
        #expect(!APNsClient.isValidDeviceToken(String(repeating: "a", count: 63)))
        #expect(!APNsClient.isValidDeviceToken(""))
    }

    @Test func aMalformedTokenNeverReachesTheNetwork() async {
        let fake = FakeAPNs([])
        let client = APNsClient(transport: { request in await fake.respond(request) })
        await #expect(throws: APNsError.invalidDeviceToken) {
            try await client.start(token: "not a token", environment: .production, payload: Data(), credentials: makeCredentials())
        }
        #expect(await fake.requests.isEmpty)
    }

    @Test func deleteChannelSendsTheChannelID() async throws {
        let fake = FakeAPNs([(204, "", [:]), (404, #"{"reason":"BadChannelId"}"#, [:])])
        let client = APNsClient(transport: { request in await fake.respond(request) })
        try await client.deleteChannel(channelID: "old-channel", environment: .development, credentials: makeCredentials())
        // Already gone counts as deleted.
        try await client.deleteChannel(channelID: "gone", environment: .development, credentials: makeCredentials())
        let request = try #require(await fake.requests.first)
        #expect(request.httpMethod == "DELETE")
        #expect(request.value(forHTTPHeaderField: "apns-channel-id") == "old-channel")
        #expect(request.url?.host == "api-manage-broadcast.sandbox.push.apple.com")
    }
}
