import Foundation
import XCTest
@testable import ChannelDeck

final class ACMECertificateManagerTests: XCTestCase {
    func testIssuesAfterDNSPropagationAndRetryAfterThenCleansUp() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let certificate = fixtureCertificate(now: now)
        let acme = MockACMEClient(
            challenges: [ACMEDNSChallenge(id: "challenge", recordName: "_acme-challenge.relay.example.com", value: "txt-secret")],
            validationResults: [
                ACMEValidationResult(state: .pending, retryAfter: 11),
                ACMEValidationResult(state: .valid, retryAfter: nil)
            ],
            certificate: certificate
        )
        let dns = MockDNSProvider()
        let store = MemoryCertificateStore()
        let clock = TestACMEClock(now: now)
        let manager = ACMECertificateManager(
            configuration: configuration(propagation: 3, poll: 5, timeout: 60),
            client: acme,
            dnsProvider: dns,
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: store,
            clock: clock
        )

        let result = try await manager.ensureCertificate(for: "Relay.Example.com.")
        let sleeps = await clock.recordedSleeps()
        let dnsEvents = await dns.recordedEvents()
        let preparedHostnames = await acme.prepareHostnames()
        let validationCount = await acme.validationCount()
        let finalizationCount = await acme.finalizationCount()
        let stored = await store.loadCertificate()

        XCTAssertEqual(result, certificate)
        XCTAssertEqual(sleeps, [3, 11])
        XCTAssertEqual(
            dnsEvents,
            [
                .present(name: "_acme-challenge.relay.example.com", value: "txt-secret"),
                .remove(id: "dns-record-0", name: "_acme-challenge.relay.example.com")
            ]
        )
        XCTAssertEqual(preparedHostnames, ["relay.example.com"])
        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(finalizationCount, 1)
        XCTAssertEqual(stored, certificate)
    }

    func testReturnsExistingCertificateOutsideRenewalWindow() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let existing = fixtureCertificate(now: now, lifetime: 31 * 24 * 60 * 60)
        let store = MemoryCertificateStore(certificate: existing)
        let acme = MockACMEClient(certificate: fixtureCertificate(now: now))
        let manager = ACMECertificateManager(
            configuration: configuration(renewalThreshold: 30 * 24 * 60 * 60),
            client: acme,
            dnsProvider: MockDNSProvider(),
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: store,
            clock: TestACMEClock(now: now)
        )

        let result = try await manager.ensureCertificate(for: "relay.example.com")
        let preparedHostnames = await acme.prepareHostnames()

        XCTAssertEqual(result, existing)
        XCTAssertTrue(preparedHostnames.isEmpty)
    }

    func testRenewsAtThresholdAndWhenHostnameChanges() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let replacement = fixtureCertificate(now: now, hostname: "relay.example.com")
        let atThreshold = fixtureCertificate(
            now: now,
            lifetime: 30 * 24 * 60 * 60,
            hostname: "relay.example.com"
        )
        let store = MemoryCertificateStore(certificate: atThreshold)
        let acme = MockACMEClient(
            validationResults: [.init(state: .valid, retryAfter: nil)],
            certificate: replacement
        )
        let manager = ACMECertificateManager(
            configuration: configuration(renewalThreshold: 30 * 24 * 60 * 60),
            client: acme,
            dnsProvider: MockDNSProvider(),
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: store,
            clock: TestACMEClock(now: now)
        )

        _ = try await manager.ensureCertificate(for: "relay.example.com")
        let preparedHostnames = await acme.prepareHostnames()
        XCTAssertEqual(preparedHostnames, ["relay.example.com"])

        let changedPolicy = CertificateRenewalPolicy(threshold: 1)
        XCTAssertTrue(
            changedPolicy.needsRenewal(
                replacement,
                hostname: "different.example.com",
                now: now
            )
        )
    }

    func testTimeoutHonorsBudgetAndCleansUpWithoutFinalizing() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let acme = MockACMEClient(
            validationResults: [
                .init(state: .pending, retryAfter: nil),
                .init(state: .pending, retryAfter: nil),
                .init(state: .pending, retryAfter: nil)
            ],
            certificate: fixtureCertificate(now: now)
        )
        let dns = MockDNSProvider()
        let manager = ACMECertificateManager(
            configuration: configuration(poll: 5, timeout: 9),
            client: acme,
            dnsProvider: dns,
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: MemoryCertificateStore(),
            clock: TestACMEClock(now: now)
        )

        do {
            _ = try await manager.ensureCertificate(for: "relay.example.com")
            XCTFail("Expected validation timeout")
        } catch {
            XCTAssertEqual(error as? ACMECertificateError, .challengeTimedOut)
        }

        let validationCount = await acme.validationCount()
        let finalizationCount = await acme.finalizationCount()
        let removalCount = await dns.removalCount()
        XCTAssertEqual(validationCount, 2)
        XCTAssertEqual(finalizationCount, 0)
        XCTAssertEqual(removalCount, 1)
    }

    func testRejectedChallengeCleansUpAndDoesNotFinalize() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let acme = MockACMEClient(
            validationResults: [.init(state: .invalid, retryAfter: nil)],
            certificate: fixtureCertificate(now: now)
        )
        let dns = MockDNSProvider()
        let manager = ACMECertificateManager(
            configuration: configuration(),
            client: acme,
            dnsProvider: dns,
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: MemoryCertificateStore(),
            clock: TestACMEClock(now: now)
        )

        do {
            _ = try await manager.ensureCertificate(for: "relay.example.com")
            XCTFail("Expected rejection")
        } catch {
            XCTAssertEqual(error as? ACMECertificateError, .challengeRejected)
        }
        let removalCount = await dns.removalCount()
        let finalizationCount = await acme.finalizationCount()
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(finalizationCount, 0)
    }

    func testPartialDNSCreationFailureCleansUpAlreadyCreatedRecords() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let acme = MockACMEClient(
            challenges: [
                .init(id: "one", recordName: "_acme-challenge.one.example.com", value: "one"),
                .init(id: "two", recordName: "_acme-challenge.two.example.com", value: "two")
            ],
            certificate: fixtureCertificate(now: now)
        )
        let dns = MockDNSProvider(failPresentationNumber: 2)
        let manager = ACMECertificateManager(
            configuration: configuration(),
            client: acme,
            dnsProvider: dns,
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: MemoryCertificateStore(),
            clock: TestACMEClock(now: now)
        )

        do {
            _ = try await manager.ensureCertificate(for: "relay.example.com")
            XCTFail("Expected DNS failure")
        } catch {
            XCTAssertEqual(error as? ACMECertificateError, .dnsUpdateFailed)
        }
        let removalCount = await dns.removalCount()
        XCTAssertEqual(removalCount, 1)
    }

    func testInvalidHostnameAndInsecureDirectoryAreRejectedBeforeNetwork() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let acme = MockACMEClient(certificate: fixtureCertificate(now: now))
        let insecure = ACMEConfiguration(
            directory: .custom(URL(string: "http://acme.example/directory")!),
            contactEmail: nil,
            dnsPropagationDelay: 0,
            pollingInterval: 1,
            operationTimeout: 10,
            renewalThreshold: 1
        )
        let manager = ACMECertificateManager(
            configuration: insecure,
            client: acme,
            dnsProvider: MockDNSProvider(),
            propagationChecker: ImmediateDNSPropagationChecker(),
            certificateStore: MemoryCertificateStore(),
            clock: TestACMEClock(now: now)
        )

        do {
            _ = try await manager.ensureCertificate(for: "not a host")
            XCTFail("Expected invalid configuration")
        } catch {
            XCTAssertEqual(error as? ACMECertificateError, .invalidConfiguration)
        }
        let preparedHostnames = await acme.prepareHostnames()
        XCTAssertTrue(preparedHostnames.isEmpty)
    }

    func testWaitsForExactTXTVisibilityBeforeRequestingValidation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let challenge = ACMEDNSChallenge(
            id: "challenge",
            recordName: "_acme-challenge.relay.example.com",
            value: "expected-proof"
        )
        let acme = MockACMEClient(
            challenges: [challenge],
            validationResults: [.init(state: .valid, retryAfter: nil)],
            certificate: fixtureCertificate(now: now)
        )
        let propagation = MockDNSPropagationChecker(
            statuses: [.pending, .pending, .visible]
        )
        let clock = TestACMEClock(now: now)
        let manager = ACMECertificateManager(
            configuration: configuration(propagation: 2, poll: 4, timeout: 30),
            client: acme,
            dnsProvider: MockDNSProvider(),
            propagationChecker: propagation,
            certificateStore: MemoryCertificateStore(),
            clock: clock
        )

        _ = try await manager.ensureCertificate(for: "relay.example.com")

        let observations = await propagation.observations()
        let sleeps = await clock.recordedSleeps()
        let validationCount = await acme.validationCount()

        XCTAssertEqual(observations, [
            .init(name: challenge.recordName, value: challenge.value),
            .init(name: challenge.recordName, value: challenge.value),
            .init(name: challenge.recordName, value: challenge.value),
        ])
        XCTAssertEqual(sleeps, [2, 4, 4])
        XCTAssertEqual(validationCount, 1)
    }

    func testPropagationTimeoutCleansUpWithoutNotifyingACMEServer() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let acme = MockACMEClient(certificate: fixtureCertificate(now: now))
        let dns = MockDNSProvider()
        let propagation = MockDNSPropagationChecker(statuses: [.pending])
        let manager = ACMECertificateManager(
            configuration: configuration(poll: 5, timeout: 9),
            client: acme,
            dnsProvider: dns,
            propagationChecker: propagation,
            certificateStore: MemoryCertificateStore(),
            clock: TestACMEClock(now: now)
        )

        do {
            _ = try await manager.ensureCertificate(for: "relay.example.com")
            XCTFail("Expected propagation timeout")
        } catch {
            XCTAssertEqual(error as? ACMECertificateError, .challengeTimedOut)
        }

        let observationCount = await propagation.observations().count
        let validationCount = await acme.validationCount()
        let finalizationCount = await acme.finalizationCount()
        let removalCount = await dns.removalCount()
        XCTAssertEqual(observationCount, 2)
        XCTAssertEqual(validationCount, 0)
        XCTAssertEqual(finalizationCount, 0)
        XCTAssertEqual(removalCount, 1)
    }

    func testErrorsAndMaterialDescriptionsAreRedacted() {
        let secret = "secret-token-and-url"
        for error in [
            ACMECertificateError.issuanceFailed,
            .dnsUpdateFailed,
            .invalidCertificateMaterial,
            .secureStorageFailed
        ] {
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("http"))
        }
        let material = fixtureCertificate(now: .now, key: secret)
        XCTAssertEqual(String(describing: material), "<redacted relay certificate>")
        XCTAssertFalse(String(reflecting: material).contains(secret))
    }

    private func configuration(
        propagation: TimeInterval = 0,
        poll: TimeInterval = 1,
        timeout: TimeInterval = 30,
        renewalThreshold: TimeInterval = 30 * 24 * 60 * 60
    ) -> ACMEConfiguration {
        ACMEConfiguration(
            directory: .letsEncryptStaging,
            contactEmail: nil,
            dnsPropagationDelay: propagation,
            pollingInterval: poll,
            operationTimeout: timeout,
            renewalThreshold: renewalThreshold
        )
    }

    private func fixtureCertificate(
        now: Date,
        lifetime: TimeInterval = 90 * 24 * 60 * 60,
        hostname: String = "relay.example.com",
        key: String = "private-key"
    ) -> IssuedCertificateMaterial {
        IssuedCertificateMaterial(
            hostname: hostname,
            privateKeyPEM: key,
            certificateChainPEM: ["certificate"],
            issuedAt: now,
            notAfter: now.addingTimeInterval(lifetime)
        )
    }
}

final class ACMEDNS01Tests: XCTestCase {
    func testTXTValueUsesSHA256Base64URLWithoutPadding() {
        XCTAssertEqual(
            DNS01.txtValue(forKeyAuthorization: "abc.def"),
            "67MSe_XHxLTkK1FxD0lGwcHQWzMdI3ndFeOlQx7ZNBY"
        )
    }

    func testRecordNameNormalizesHostnameAndWildcard() throws {
        XCTAssertEqual(
            try DNS01.recordName(for: "*.Relay.Example.com."),
            "_acme-challenge.relay.example.com"
        )
    }

    func testDirectoryPresetsAndCustomEndpointIsolation() {
        XCTAssertEqual(
            ACMEDirectoryEndpoint.letsEncryptStaging.url.absoluteString,
            "https://acme-staging-v02.api.letsencrypt.org/directory"
        )
        XCTAssertEqual(
            ACMEDirectoryEndpoint.letsEncryptProduction.url.absoluteString,
            "https://acme-v02.api.letsencrypt.org/directory"
        )
        let first = ACMEDirectoryEndpoint.custom(URL(string: "https://one.example/directory")!)
        let second = ACMEDirectoryEndpoint.custom(URL(string: "https://two.example/directory")!)
        XCTAssertNotEqual(first.storageIdentifier, second.storageIdentifier)
        XCTAssertFalse(first.storageIdentifier.contains("one.example"))
    }
}

private actor MockACMEClient: ACMEClientProtocol {
    private let challenges: [ACMEDNSChallenge]
    private var results: [ACMEValidationResult]
    private let certificate: IssuedCertificateMaterial
    private var prepared: [String] = []
    private var validations = 0
    private var finalizations = 0

    init(
        challenges: [ACMEDNSChallenge] = [
            .init(id: "challenge", recordName: "_acme-challenge.relay.example.com", value: "value")
        ],
        validationResults: [ACMEValidationResult] = [.init(state: .valid, retryAfter: nil)],
        certificate: IssuedCertificateMaterial
    ) {
        self.challenges = challenges
        self.results = validationResults
        self.certificate = certificate
    }

    func prepareOrder(hostname: String) -> ACMEPreparedOrder {
        prepared.append(hostname)
        return ACMEPreparedOrder(id: "order", challenges: challenges)
    }

    func validateDNSChallenges(orderID: String) -> ACMEValidationResult {
        validations += 1
        if results.count > 1 { return results.removeFirst() }
        return results.first ?? .init(state: .pending, retryAfter: nil)
    }

    func finalizeOrder(orderID: String) -> IssuedCertificateMaterial {
        finalizations += 1
        return certificate
    }

    func prepareHostnames() -> [String] { prepared }
    func validationCount() -> Int { validations }
    func finalizationCount() -> Int { finalizations }
}

private actor MockDNSProvider: DNSChallengeProviding {
    enum Event: Equatable, Sendable {
        case present(name: String, value: String)
        case remove(id: String, name: String)
    }

    private var events: [Event] = []
    private var presentationCount = 0
    private let failPresentationNumber: Int?

    init(failPresentationNumber: Int? = nil) {
        self.failPresentationNumber = failPresentationNumber
    }

    func presentTXTRecord(name: String, value: String) throws -> DNSChallengeRecord {
        presentationCount += 1
        if presentationCount == failPresentationNumber {
            throw MockError.failed
        }
        events.append(.present(name: name, value: value))
        return DNSChallengeRecord(id: "dns-record-\(presentationCount - 1)", name: name)
    }

    func removeTXTRecord(_ record: DNSChallengeRecord) {
        events.append(.remove(id: record.id, name: record.name))
    }

    func recordedEvents() -> [Event] { events }
    func removalCount() -> Int { events.filter { if case .remove = $0 { true } else { false } }.count }
}

private struct ImmediateDNSPropagationChecker: DNSPropagationChecking {
    func checkTXTRecord(name: String, value: String) -> DNSPropagationStatus {
        .visible
    }
}

private actor MockDNSPropagationChecker: DNSPropagationChecking {
    struct Observation: Equatable, Sendable {
        let name: String
        let value: String
    }

    private var statuses: [DNSPropagationStatus]
    private var recordedObservations: [Observation] = []

    init(statuses: [DNSPropagationStatus]) {
        self.statuses = statuses
    }

    func checkTXTRecord(name: String, value: String) -> DNSPropagationStatus {
        recordedObservations.append(.init(name: name, value: value))
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses.first ?? .pending
    }

    func observations() -> [Observation] { recordedObservations }
}

private actor MemoryCertificateStore: RelayCertificateStoring {
    private var certificate: IssuedCertificateMaterial?

    init(certificate: IssuedCertificateMaterial? = nil) {
        self.certificate = certificate
    }

    func loadCertificate() -> IssuedCertificateMaterial? { certificate }
    func saveCertificate(_ certificate: IssuedCertificateMaterial) { self.certificate = certificate }
    func removeCertificate() { certificate = nil }
    func loadIdentity() -> RelayTLSIdentity? { nil }
}

private actor TestACMEClock: ACMEClock {
    private var current: Date
    private var sleeps: [TimeInterval] = []

    init(now: Date) { current = now }

    func now() -> Date { current }

    func sleep(for interval: TimeInterval) throws {
        guard interval >= 0 else { throw MockError.failed }
        sleeps.append(interval)
        current = current.addingTimeInterval(interval)
    }

    func recordedSleeps() -> [TimeInterval] { sleeps }
}

private enum MockError: Error {
    case failed
}
