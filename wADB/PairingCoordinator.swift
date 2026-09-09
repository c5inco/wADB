import Foundation
import OSLog

enum PairingCoordinatorError: LocalizedError {
    case expired
    case pairingFailed(String)
    case connectionTimedOut

    var errorDescription: String? {
        switch self {
        case .expired: "The QR code expired. Close this window and try pairing again."
        case let .pairingFailed(detail): "Pairing failed. \(detail)"
        case .connectionTimedOut: "Pairing succeeded, but the wireless ADB connection did not appear. Keep Wireless debugging enabled and try again."
        }
    }
}

final class PairingCoordinator {
    typealias Completion = (Result<LastVerifiedDevice, Error>?) -> Void
    static let connectedPresentationDuration: TimeInterval = 2.5

    private enum Phase {
        case preparing, scanning, pairing, waitingForConnection, finishing, finished
    }

    private let adb: ADBManager
    private let logger = Logger(subsystem: "local.c5inco.wADB", category: "pairing")
    private let windowController = PairingWindowController()
    private let completion: Completion
    private var credentials: ADBQRPayload?
    private var phase = Phase.preparing
    private var baselinePairingServices = Set<String>()
    private var pairingService: BonjourService?
    private var connectService: BonjourService?
    private var services: [BonjourService] = []
    private var transports: [ADBTransport] = []
    private var baselineAuthorizedSerials = Set<String>()
    private var expiryWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var nativeGraceWorkItem: DispatchWorkItem?
    private var finishWorkItem: DispatchWorkItem?
    private var explicitConnectStarted = false

    init(adb: ADBManager, completion: @escaping Completion) {
        self.adb = adb
        self.completion = completion
        windowController.onClose = { [weak self] in self?.cancel() }
    }

    func start(currentServices: [BonjourService]) {
        guard phase == .preparing else { return }
        services = currentServices
        baselinePairingServices = Set(currentServices.filter {
            $0.type == BonjourService.pairingType
        }.map(\.identity))
        do {
            let credentials = try ADBQRPayload.random()
            self.credentials = credentials
            var payload = credentials.encoded()
            defer {
                if !payload.isEmpty { payload.resetBytes(in: 0..<payload.count) }
            }
            try windowController.show(qrPayload: payload)
            phase = .scanning
            let expiry = DispatchWorkItem { [weak self] in self?.expire() }
            expiryWorkItem = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: expiry)
        } catch {
            finish(.failure(error), closeDelay: 0)
        }
    }

    func update(services: [BonjourService]) {
        self.services = services
        if let pairingService,
           let refreshed = services.first(where: { $0.identity == pairingService.identity }) {
            self.pairingService = refreshed
        }
        if let pairingService = self.pairingService {
            connectService = BonjourCorrelator.connectService(for: pairingService, among: services)
        }
        if phase == .scanning,
           let discovered = services.first(where: {
               $0.type == BonjourService.pairingType
                   && !baselinePairingServices.contains($0.identity)
                   && credentials?.matches(serviceName: $0.name) == true
           }) {
            beginPairing(with: discovered)
        } else if phase == .waitingForConnection {
            completeIfAuthorized()
            if nativeGraceWorkItem == nil { connectIfNeeded() }
        }
    }

    func update(transports: [ADBTransport]) {
        self.transports = transports
        if phase == .scanning {
            baselineAuthorizedSerials.formUnion(
                transports.lazy.filter { $0.state == .authorized }.map(\.serial)
            )
        }
        if phase == .waitingForConnection { completeIfAuthorized() }
    }

    func cancel() {
        guard phase != .finished else { return }
        phase = .finished
        eraseCredentials()
        cancelTimers()
        adb.cancelPairingAttempt()
        adb.cancelConnectionAttempt()
        windowController.closeWithoutCancelling()
        completion(nil)
    }

    private func beginPairing(with service: BonjourService) {
        guard phase == .scanning, let credentials else { return }
        logger.info("Detected the requested QR pairing service")
        phase = .pairing
        pairingService = service
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        windowController.setStatus("QR code detected. Pairing securely…")
        windowController.clearQRCode()
        let input = credentials.passwordInput()
        eraseCredentials()
        adb.pair(to: service.endpoint, passwordInput: input) { [weak self] result in
            self?.handlePairResult(result)
        }
    }

    private func handlePairResult(_ result: Result<ADBProcessResult, Error>) {
        guard phase == .pairing else { return }
        switch result {
        case let .failure(error):
            logger.error("Could not launch adb pair: \(error.localizedDescription, privacy: .public)")
            finish(.failure(error), closeDelay: 2)
        case let .success(processResult):
            let output = processResult.combinedOutput.lowercased()
            guard processResult.status == 0, output.contains("successfully paired") else {
                logger.error("adb pair failed with status \(processResult.status, privacy: .public)")
                let detail = processResult.combinedOutput.isEmpty ? "adb did not accept the QR credentials." : processResult.combinedOutput
                finish(.failure(PairingCoordinatorError.pairingFailed(detail)), closeDelay: 3)
                return
            }
            logger.info("adb pair succeeded; waiting for an authorized transport")
            phase = .waitingForConnection
            windowController.setStatus("Paired. Waiting for an authorized connection…")
            connectService = pairingService.flatMap {
                BonjourCorrelator.connectService(for: $0, among: services)
            }
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .waitingForConnection else { return }
                self.logger.error("Timed out waiting for the paired wireless transport")
                self.finish(.failure(PairingCoordinatorError.connectionTimedOut), closeDelay: 3)
            }
            connectionTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            completeIfAuthorized()
            guard phase == .waitingForConnection else { return }
            let grace = DispatchWorkItem { [weak self] in
                self?.nativeGraceWorkItem = nil
                self?.connectIfNeeded()
            }
            nativeGraceWorkItem = grace
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: grace)
        }
    }

    private func connectIfNeeded() {
        guard phase == .waitingForConnection, !explicitConnectStarted,
              let connectService else { return }
        if completeIfAuthorized() { return }
        logger.info("Native auto-connect did not complete; trying the correlated connect service")
        explicitConnectStarted = true
        adb.connect(to: connectService.endpoint) { [weak self] _ in
            guard let self, self.phase == .waitingForConnection else { return }
            self.completeIfAuthorized()
        }
    }

    @discardableResult
    private func completeIfAuthorized() -> Bool {
        guard phase == .waitingForConnection,
              let (connectService, transport) = resolvedAuthorizedConnection() else { return false }
        self.connectService = connectService
        logger.info("Pairing completed with an authorized ADB transport")
        adb.cancelConnectionAttempt()
        let verified = LastVerifiedDevice(
            endpoint: connectService.endpoint,
            host: connectService.host,
            serviceName: connectService.name,
            displayName: transport.modelDisplayName,
            fingerprint: transport.fingerprint
        )
        windowController.showConnected(to: verified.displayName)
        finish(.success(verified), closeDelay: Self.connectedPresentationDuration)
        return true
    }

    private func resolvedAuthorizedConnection() -> (BonjourService, ADBTransport)? {
        Self.resolveAuthorizedConnection(
            transports: transports,
            services: services,
            preferredService: connectService,
            pairingService: pairingService,
            excludingAuthorizedSerials: baselineAuthorizedSerials
        )
    }

    static func resolveAuthorizedConnection(
        transports: [ADBTransport],
        services: [BonjourService],
        preferredService: BonjourService?,
        pairingService: BonjourService?,
        excludingAuthorizedSerials: Set<String>
    ) -> (BonjourService, ADBTransport)? {
        let newlyAuthorized = transports.filter {
            $0.state == .authorized
                && !excludingAuthorizedSerials.contains($0.serial)
                && WirelessDeviceResolver.isWireless(
                    $0,
                    services: services,
                    rememberedDevices: []
                )
        }
        if let resolved = matchAuthorized(
            newlyAuthorized,
            services: services,
            preferredService: preferredService
        ) {
            return resolved
        }

        // Pairing can legitimately succeed for a phone that the shared server
        // already connected. Adopt it only when Bonjour correlates the pairing
        // and connect advertisements by numeric or stable target hostname.
        guard let pairingService else { return nil }
        let authorized = transports.filter {
            $0.state == .authorized
                && WirelessDeviceResolver.isWireless(
                    $0,
                    services: services,
                    rememberedDevices: []
                )
        }
        guard let service = BonjourCorrelator.connectService(
            for: pairingService,
            among: services
        ), let transport = authorized.first(where: {
            $0.connectServiceName == service.name || service.endpoints.contains($0.serial)
        }) else { return nil }
        return (service, transport)
    }

    private static func matchAuthorized(
        _ authorized: [ADBTransport],
        services: [BonjourService],
        preferredService: BonjourService?
    ) -> (BonjourService, ADBTransport)? {
        guard !authorized.isEmpty else { return nil }
        if let preferredService,
           let transport = authorized.first(where: {
               $0.connectServiceName == preferredService.name
                   || preferredService.endpoints.contains($0.serial)
           }) {
            return (preferredService, transport)
        }
        for transport in authorized {
            if let service = services.first(where: {
                $0.type == BonjourService.connectType
                    && ($0.name == transport.connectServiceName
                        || $0.endpoints.contains(transport.serial))
            }) {
                return (service, transport)
            }
        }
        return nil
    }

    private func expire() {
        guard phase == .scanning else { return }
        finish(.failure(PairingCoordinatorError.expired), closeDelay: 3)
    }

    private func finish(_ result: Result<LastVerifiedDevice, Error>, closeDelay: TimeInterval) {
        guard phase != .finishing, phase != .finished else { return }
        phase = .finishing
        eraseCredentials()
        cancelTimers()
        adb.cancelPairingAttempt()
        if case .success = result { adb.cancelConnectionAttempt() }
        switch result {
        case .success:
            break
        case let .failure(error):
            windowController.clearQRCode()
            windowController.setStatus(error.localizedDescription)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .finishing else { return }
            self.phase = .finished
            self.windowController.closeWithoutCancelling()
            self.completion(result)
        }
        finishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay, execute: work)
    }

    private func eraseCredentials() {
        credentials?.erase()
        credentials = nil
        windowController.clearQRCode()
    }

    private func cancelTimers() {
        expiryWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        nativeGraceWorkItem?.cancel()
        finishWorkItem?.cancel()
        expiryWorkItem = nil
        connectionTimeoutWorkItem = nil
        nativeGraceWorkItem = nil
        finishWorkItem = nil
    }
}
