import Foundation
import Testing
@testable import ChannelDeck

@Suite("AirPlay relay preferences")
struct RelayPreferencesTests {
    @Test("Each installation gets a stable generated hostname label")
    @MainActor
    func stableInstallationHostname() throws {
        let suiteName = "ChannelDeckTests.relay-preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AirPlayRelayPreferencesStore(defaults: defaults)
        var first = store.loadOrCreate()
        #expect(first.hostLabel.hasPrefix("iptv-"))
        #expect(first.hostLabel.count == 13)

        first.zoneDomain = "Example.COM."
        first.accountID = "account"
        store.save(first)

        let second = AirPlayRelayPreferencesStore(defaults: defaults).loadOrCreate()
        #expect(second.installationID == first.installationID)
        #expect(second.hostLabel == first.hostLabel)
        #expect(second.hostname == "\(first.hostLabel).example.com")
    }

    @Test("Generated labels use exactly four random bytes")
    func deterministicRandomLabel() {
        let preferences = AirPlayRelayPreferences.fresh(
            installationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            randomBytes: { [0x01, 0x23, 0xab, 0xff] }
        )
        #expect(preferences.hostLabel == "iptv-0123abff")
    }

    @Test("Clearing keeps ownership identity but removes the domain")
    @MainActor
    func clearPreservesInstallationIdentity() throws {
        let suiteName = "ChannelDeckTests.relay-clear.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AirPlayRelayPreferencesStore(defaults: defaults)
        var configured = store.loadOrCreate()
        configured.zoneDomain = "beertini.com"
        configured.accountID = "abc"
        configured.certificateEnvironment = .staging
        store.save(configured)

        let cleared = store.clearConfiguration()
        #expect(cleared.installationID == configured.installationID)
        #expect(cleared.hostLabel == configured.hostLabel)
        #expect(cleared.zoneDomain.isEmpty)
        #expect(cleared.accountID.isEmpty)
        #expect(cleared.certificateEnvironment == .production)
    }
}
