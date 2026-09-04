import Foundation

actor ACMECertificateManager {
    private let configuration: ACMEConfiguration
    private let client: any ACMEClientProtocol
    private let dnsProvider: any DNSChallengeProviding
    private let propagationChecker: any DNSPropagationChecking
    private let certificateStore: any RelayCertificateStoring
    private let clock: any ACMEClock

    init(
        configuration: ACMEConfiguration,
        client: any ACMEClientProtocol,
        dnsProvider: any DNSChallengeProviding,
        propagationChecker: any DNSPropagationChecking = DoHTXTPropagationChecker(),
        certificateStore: any RelayCertificateStoring,
        clock: any ACMEClock = SystemACMEClock()
    ) {
        self.configuration = configuration
        self.client = client
        self.dnsProvider = dnsProvider
        self.propagationChecker = propagationChecker
        self.certificateStore = certificateStore
        self.clock = clock
    }

    /// Returns the installed certificate, renewing it when the hostname changes
    /// or it enters the configured renewal window.
    func ensureCertificate(
        for requestedHostname: String,
        forceRenewal: Bool = false
    ) async throws -> IssuedCertificateMaterial {
        do {
            let certificate = try await performEnsureCertificate(
                for: requestedHostname,
                forceRenewal: forceRenewal
            )
            await client.shutdown()
            return certificate
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func performEnsureCertificate(
        for requestedHostname: String,
        forceRenewal: Bool
    ) async throws -> IssuedCertificateMaterial {
        guard configuration.directory.isSecure,
              configuration.dnsPropagationDelay >= 0,
              configuration.pollingInterval > 0,
              configuration.operationTimeout > 0,
              configuration.renewalThreshold >= 0 else {
            throw ACMECertificateError.invalidConfiguration
        }

        let hostname = try ACMEHostname.normalized(requestedHostname)
        let existing: IssuedCertificateMaterial?
        do {
            existing = try await certificateStore.loadCertificate()
        } catch {
            throw ACMECertificateError.secureStorageFailed
        }

        let now = await clock.now()
        let renewalPolicy = CertificateRenewalPolicy(threshold: configuration.renewalThreshold)
        if !forceRenewal,
           !renewalPolicy.needsRenewal(existing, hostname: hostname, now: now),
           let existing {
            return existing
        }

        let deadline = now.addingTimeInterval(configuration.operationTimeout)
        let order: ACMEPreparedOrder
        do {
            order = try await client.prepareOrder(hostname: hostname)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ACMECertificateError.issuanceFailed
        }
        guard !order.challenges.isEmpty else {
            throw ACMECertificateError.noDNSChallenge
        }

        var records: [DNSChallengeRecord] = []
        do {
            for challenge in order.challenges {
                do {
                    let record = try await dnsProvider.presentTXTRecord(
                        name: challenge.recordName,
                        value: challenge.value
                    )
                    records.append(record)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ACMECertificateError.dnsUpdateFailed
                }
            }

            try await sleepWithinDeadline(
                configuration.dnsPropagationDelay,
                deadline: deadline
            )
            for challenge in order.challenges {
                try await waitForDNSPropagation(challenge, deadline: deadline)
            }
            try await pollValidation(orderID: order.id, deadline: deadline)

            guard await clock.now() < deadline else {
                throw ACMECertificateError.challengeTimedOut
            }
            let certificate: IssuedCertificateMaterial
            do {
                certificate = try await client.finalizeOrder(orderID: order.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ACMECertificateError.issuanceFailed
            }
            guard certificate.hostname.caseInsensitiveCompare(hostname) == .orderedSame,
                  certificate.notAfter > certificate.issuedAt,
                  !certificate.privateKeyPEM.isEmpty,
                  !certificate.certificateChainPEM.isEmpty else {
                throw ACMECertificateError.invalidCertificateMaterial
            }

            if try await cleanup(records) == false {
                throw ACMECertificateError.dnsCleanupFailed
            }
            records.removeAll()

            do {
                try await certificateStore.saveCertificate(certificate)
            } catch {
                throw ACMECertificateError.secureStorageFailed
            }
            return certificate
        } catch {
            _ = try? await cleanup(records)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? ACMECertificateError { throw error }
            throw ACMECertificateError.issuanceFailed
        }
    }

    private func waitForDNSPropagation(
        _ challenge: ACMEDNSChallenge,
        deadline: Date
    ) async throws {
        while true {
            guard await clock.now() < deadline else {
                throw ACMECertificateError.challengeTimedOut
            }

            let status: DNSPropagationStatus
            do {
                status = try await propagationChecker.checkTXTRecord(
                    name: challenge.recordName,
                    value: challenge.value
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A failed resolver observation is inconclusive. Retrying under
                // the operation deadline avoids prematurely notifying the CA.
                try await sleepWithinDeadline(configuration.pollingInterval, deadline: deadline)
                continue
            }

            switch status {
            case .visible:
                return
            case .pending:
                try await sleepWithinDeadline(configuration.pollingInterval, deadline: deadline)
            }
        }
    }

    private func pollValidation(orderID: String, deadline: Date) async throws {
        while true {
            guard await clock.now() < deadline else {
                throw ACMECertificateError.challengeTimedOut
            }

            let result: ACMEValidationResult
            do {
                result = try await client.validateDNSChallenges(orderID: orderID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ACMECertificateError.issuanceFailed
            }

            switch result.state {
            case .valid:
                return
            case .invalid:
                throw ACMECertificateError.challengeRejected
            case .pending:
                let suggested = result.retryAfter ?? configuration.pollingInterval
                let delay = suggested > 0 ? suggested : configuration.pollingInterval
                try await sleepWithinDeadline(delay, deadline: deadline)
            }
        }
    }

    private func sleepWithinDeadline(_ interval: TimeInterval, deadline: Date) async throws {
        guard interval > 0 else {
            try Task.checkCancellation()
            return
        }
        let remaining = deadline.timeIntervalSince(await clock.now())
        guard remaining > 0, interval <= remaining else {
            throw ACMECertificateError.challengeTimedOut
        }
        try await clock.sleep(for: interval)
    }

    /// Attempts every deletion even if one provider call fails.
    private func cleanup(_ records: [DNSChallengeRecord]) async throws -> Bool {
        var succeeded = true
        for record in records.reversed() {
            do {
                try await dnsProvider.removeTXTRecord(record)
            } catch is CancellationError {
                succeeded = false
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}
