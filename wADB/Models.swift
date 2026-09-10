import Foundation

enum ADBTransportState: Equatable {
    case authorized
    case unauthorized
    case offline
    case other(String)

    init(adbValue: String) {
        switch adbValue {
        case "device": self = .authorized
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        default: self = .other(adbValue)
        }
    }
}

struct ADBTransport: Equatable {
    let serial: String
    let state: ADBTransportState
    let attributes: [String: String]

    var fingerprint: String? {
        let values = [attributes["product"], attributes["model"], attributes["device"]]
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.map { $0 ?? "" }.joined(separator: "|")
    }

    var modelDisplayName: String {
        (attributes["model"] ?? attributes["device"] ?? "Android device")
            .replacingOccurrences(of: "_", with: " ")
    }

    var connectServiceName: String? {
        let suffix = ".\(BonjourService.connectType)"
        guard serial.hasSuffix(suffix) else { return nil }
        return String(serial.dropLast(suffix.count))
    }
}

struct ADBPhysicalDevice: Equatable {
    let key: String
    let transports: [ADBTransport]

    var isAuthorized: Bool { transports.contains { $0.state == .authorized } }
    var displayName: String { transports.first?.modelDisplayName ?? "Android device" }
}

/// Non-sensitive identity retained after a successful QR pairing. Connection
/// state is never persisted; endpoint and host are only fallback correlation
/// hints for older ADB Wi-Fi implementations.
struct LastVerifiedDevice: Codable, Equatable {
    let endpoint: String
    let host: String
    let serviceName: String
    let displayName: String
    let fingerprint: String?
}

struct BonjourService: Hashable {
    static let pairingType = "_adb-tls-pairing._tcp"
    static let connectType = "_adb-tls-connect._tcp"

    let name: String
    let type: String
    let domain: String
    let hosts: [String]
    let targetHost: String?
    let port: UInt16
    let interfaceIndex: UInt32

    init(
        name: String,
        type: String,
        domain: String,
        host: String,
        targetHost: String? = nil,
        port: UInt16,
        interfaceIndex: UInt32
    ) {
        self.init(
            name: name,
            type: type,
            domain: domain,
            hosts: [host],
            targetHost: targetHost,
            port: port,
            interfaceIndex: interfaceIndex
        )
    }

    init(
        name: String,
        type: String,
        domain: String,
        hosts: [String],
        targetHost: String? = nil,
        port: UInt16,
        interfaceIndex: UInt32
    ) {
        precondition(!hosts.isEmpty, "A resolved Bonjour service must have at least one address")
        self.name = name
        self.type = type.hasSuffix(".") ? String(type.dropLast()) : type
        self.domain = domain
        self.hosts = Self.orderedHosts(hosts)
        self.targetHost = targetHost
        self.port = port
        self.interfaceIndex = interfaceIndex
    }

    var host: String { hosts[0] }

    var endpoint: String {
        Self.endpoint(host: host, port: port)
    }

    var endpoints: [String] { hosts.map { Self.endpoint(host: $0, port: port) } }

    var identity: String {
        "\(name)|\(type)|\(domain)|\(interfaceIndex)"
    }

    var normalizedHost: String {
        normalizedHosts[0]
    }

    var normalizedHosts: [String] { hosts.map(Self.normalizedHost) }

    var normalizedTargetHost: String? {
        guard var value = targetHost?.lowercased(), !value.isEmpty else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func endpoint(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    private static func orderedHosts(_ hosts: [String]) -> [String] {
        hosts.sorted { left, right in
            let leftRank = addressRank(left)
            let rightRank = addressRank(right)
            return leftRank == rightRank ? left < right : leftRank < rightRank
        }
    }

    private static func addressRank(_ host: String) -> Int {
        guard host.contains(":") else { return 0 }
        let unscoped = host.split(separator: "%", maxSplits: 1).first?.lowercased() ?? ""
        return unscoped.hasPrefix("fe80:") ? 2 : 1
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}

enum BonjourCorrelator {
    static func connectService(
        for pairingService: BonjourService,
        among services: [BonjourService]
    ) -> BonjourService? {
        if let exact = services.first(where: {
            $0.type == BonjourService.connectType
                && $0.interfaceIndex == pairingService.interfaceIndex
                && sameDeviceHost($0, pairingService)
        }) {
            return exact
        }
        let sameHost = services.filter {
            $0.type == BonjourService.connectType
                && sameDeviceHost($0, pairingService)
        }
        return sameHost.count == 1 ? sameHost.first : nil
    }

    static func connectService(
        for lastDevice: LastVerifiedDevice,
        among services: [BonjourService]
    ) -> BonjourService? {
        services.first {
            guard $0.type == BonjourService.connectType else { return false }
            return $0.name == lastDevice.serviceName
                || $0.normalizedHosts.contains(normalizedHost(lastDevice.host))
        }
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    private static func sameDeviceHost(
        _ left: BonjourService,
        _ right: BonjourService
    ) -> Bool {
        if let leftTarget = left.normalizedTargetHost,
           let rightTarget = right.normalizedTargetHost,
           leftTarget == rightTarget {
            return true
        }
        return !Set(left.normalizedHosts).isDisjoint(with: right.normalizedHosts)
    }
}

enum WirelessDeviceState: Equatable {
    case connected
    case connecting
    case restartRecommended
    case needsPairing

    var title: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .restartRecommended: "Restart ADB"
        case .needsPairing: "Needs pairing"
        }
    }
}

struct WirelessDevice: Equatable {
    let id: String
    let displayName: String
    let endpoint: String?
    let state: WirelessDeviceState
}

enum WirelessDeviceResolver {
    static func resolve(
        transports: [ADBTransport],
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> [WirelessDevice] {
        let connectServices = services.filter { $0.type == BonjourService.connectType }
        let wirelessTransports = transports.filter {
            isWireless($0, services: connectServices, rememberedDevices: rememberedDevices)
        }
        let transportGroups = groupByWirelessIdentity(
            wirelessTransports,
            services: connectServices,
            rememberedDevices: rememberedDevices
        )
        var devices: [String: WirelessDevice] = [:]

        for group in transportGroups {
            guard let representative = preferredTransport(in: group) else { continue }
            let remembered = rememberedDevices.first { device in
                group.contains {
                    matches($0, rememberedDevice: device, services: connectServices)
                }
            }
            let service = service(
                for: group,
                rememberedDevice: remembered,
                among: connectServices
            )
            let id = service?.name
                ?? representative.connectServiceName
                ?? remembered?.serviceName
                ?? representative.serial
            let displayName = representative.modelDisplayName == "Android device"
                ? (remembered?.displayName ?? "Android device")
                : representative.modelDisplayName
            let state: WirelessDeviceState
            if group.contains(where: { $0.state == .authorized }) {
                state = .connected
            } else if group.contains(where: { $0.state == .unauthorized }) {
                state = .needsPairing
            } else {
                state = .connecting
            }
            devices[id] = WirelessDevice(
                id: id,
                displayName: displayName,
                endpoint: service?.endpoint ?? remembered?.endpoint ?? endpoint(from: representative.serial),
                state: state
            )
        }

        // A QR-paired device may advertise before ADB finishes its transport.
        for remembered in rememberedDevices {
            guard let service = BonjourCorrelator.connectService(
                for: remembered,
                among: connectServices
            ), devices[service.name] == nil else { continue }
            devices[service.name] = WirelessDevice(
                id: service.name,
                displayName: remembered.displayName,
                endpoint: service.endpoint,
                state: .connecting
            )
        }

        return devices.values.sorted {
            if $0.state == $1.state {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return stateRank($0.state) < stateRank($1.state)
        }
    }

    static func isWireless(
        _ transport: ADBTransport,
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> Bool {
        if transport.serial.hasPrefix("emulator-") { return false }
        if transport.connectServiceName != nil { return true }
        if services.contains(where: {
            $0.type == BonjourService.connectType && $0.endpoints.contains(transport.serial)
        }) {
            return true
        }
        return rememberedDevices.contains {
            matches(transport, rememberedDevice: $0, services: services)
        }
    }

    static func matches(
        _ transport: ADBTransport,
        rememberedDevice: LastVerifiedDevice,
        services: [BonjourService]
    ) -> Bool {
        if transport.serial == rememberedDevice.endpoint
            || transport.connectServiceName == rememberedDevice.serviceName {
            return true
        }
        if let service = BonjourCorrelator.connectService(
            for: rememberedDevice,
            among: services
        ), service.endpoints.contains(transport.serial)
            || transport.connectServiceName == service.name {
            return true
        }
        guard let host = endpointHost(transport.serial),
              host == normalizedHost(rememberedDevice.host),
              let fingerprint = rememberedDevice.fingerprint else {
            return false
        }
        return transport.fingerprint == fingerprint
    }

    private static func preferredTransport(in transports: [ADBTransport]) -> ADBTransport? {
        transports.first(where: { $0.state == .authorized })
            ?? transports.first(where: { $0.state == .unauthorized })
            ?? transports.first
    }

    private static func groupByWirelessIdentity(
        _ transports: [ADBTransport],
        services: [BonjourService],
        rememberedDevices: [LastVerifiedDevice]
    ) -> [[ADBTransport]] {
        var order: [String] = []
        var groups: [String: [ADBTransport]] = [:]
        for transport in transports {
            let matchingService = services.first {
                $0.name == transport.connectServiceName || $0.endpoints.contains(transport.serial)
            }
            let remembered = rememberedDevices.first {
                matches(transport, rememberedDevice: $0, services: services)
            }
            let key = matchingService?.name
                ?? transport.connectServiceName
                ?? remembered?.serviceName
                ?? transport.serial
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(transport)
        }
        return order.compactMap { groups[$0] }
    }

    private static func service(
        for transports: [ADBTransport],
        rememberedDevice: LastVerifiedDevice?,
        among services: [BonjourService]
    ) -> BonjourService? {
        for transport in transports {
            if let match = services.first(where: {
                $0.name == transport.connectServiceName || $0.endpoints.contains(transport.serial)
            }) {
                return match
            }
        }
        guard let rememberedDevice else { return nil }
        return BonjourCorrelator.connectService(for: rememberedDevice, among: services)
    }

    private static func endpoint(from serial: String) -> String? {
        endpointHost(serial) == nil ? nil : serial
    }

    private static func endpointHost(_ endpoint: String) -> String? {
        if endpoint.hasPrefix("["), let closingBracket = endpoint.firstIndex(of: "]") {
            return normalizedHost(String(
                endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket]
            ))
        }
        guard let colon = endpoint.lastIndex(of: ":"),
              endpoint[endpoint.index(after: colon)...].allSatisfy(\.isNumber) else {
            return nil
        }
        return normalizedHost(String(endpoint[..<colon]))
    }

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func stateRank(_ state: WirelessDeviceState) -> Int {
        switch state {
        case .connected: 0
        case .restartRecommended: 1
        case .connecting: 2
        case .needsPairing: 3
        }
    }
}

/// Pacing for the level-triggered health check that replaced the old
/// edge-triggered supervisor. Recovery must never depend on `track-devices`
/// reporting an edge: that stream can go silent without erroring, which is
/// indistinguishable from a healthy idle connection.
enum ADBServerRecoveryAction: Equatable {
    case restartObserver
    case startServer
}

enum ADBWatchdogPolicy {
    /// How often the health check runs, regardless of what adb has told us.
    static let tickInterval: TimeInterval = 15

    /// A device refusing a connection says nothing about server health. Only
    /// repeated failures to query the shared server earn an explicit probe.
    static let snapshotFailuresBeforeProbe = 3

    static func shouldProbeServer(snapshotFailures: Int) -> Bool {
        snapshotFailures >= snapshotFailuresBeforeProbe
    }

    static func recoveryAction(serverResponsive: Bool) -> ADBServerRecoveryAction {
        serverResponsive ? .restartObserver : .startServer
    }
}

enum ADBAutomaticReconnectPolicy {
    static func shouldReconnect(
        _ device: LastVerifiedDevice,
        transports: [ADBTransport],
        services: [BonjourService]
    ) -> Bool {
        !transports.contains { transport in
            guard WirelessDeviceResolver.matches(
                transport,
                rememberedDevice: device,
                services: services
            ) else { return false }
            switch transport.state {
            case .authorized, .unauthorized:
                return true
            case .offline, .other:
                return false
            }
        }
    }
}

struct ADBConnectionRetryState: Equatable {
    private(set) var targetIdentity: String?
    private(set) var consecutiveFailures = 0
    private(set) var nextAttemptAt = Date.distantPast

    mutating func shouldAttempt(targetIdentity: String, now: Date) -> Bool {
        resetIfTargetChanged(to: targetIdentity)
        return now >= nextAttemptAt
    }

    mutating func recordFailure(targetIdentity: String, now: Date) -> TimeInterval {
        resetIfTargetChanged(to: targetIdentity)
        consecutiveFailures += 1
        let delay = Self.delay(afterFailureCount: consecutiveFailures)
        nextAttemptAt = now.addingTimeInterval(delay)
        return delay
    }

    static func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        let delays: [TimeInterval] = [15, 30, 60, 120, 300]
        return delays[min(max(failureCount, 1) - 1, delays.count - 1)]
    }

    private mutating func resetIfTargetChanged(to targetIdentity: String) {
        guard self.targetIdentity != targetIdentity else { return }
        self.targetIdentity = targetIdentity
        consecutiveFailures = 0
        nextAttemptAt = .distantPast
    }
}

struct ADBConnectionTarget: Equatable {
    let endpoints: [String]
    /// Stable across IPv4/IPv6 address changes, but changes when Android
    /// rotates the wireless-debugging port.
    let retryIdentity: String

    var endpoint: String { endpoints[0] }

    init(device: LastVerifiedDevice, service: BonjourService?) {
        endpoints = service?.endpoints ?? [device.endpoint]
        let port = service.map { String($0.port) }
            ?? Self.port(from: device.endpoint)
            ?? device.endpoint
        retryIdentity = "\(device.serviceName)|\(port)"
    }

    private static func port(from endpoint: String) -> String? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        let port = endpoint[endpoint.index(after: colon)...]
        return port.allSatisfy(\.isNumber) ? String(port) : nil
    }
}

struct ADBConnectionFailure: Equatable {
    let endpoint: String
    let detail: String
}

enum ADBConnectionFailurePolicy {
    static func combinedDetail(_ failures: [ADBConnectionFailure]) -> String {
        failures.map { "\($0.endpoint): \($0.detail)" }.joined(separator: "; ")
    }

    static func recoveryDetail(
        for endpoint: String,
        failures: [ADBConnectionFailure]
    ) -> String? {
        failures.first { $0.endpoint == endpoint }?.detail
    }
}

struct ADBNetworkEndpoint: Equatable {
    let host: String
    let port: UInt16

    static func parse(_ endpoint: String) -> ADBNetworkEndpoint? {
        if endpoint.hasPrefix("["),
           let closingBracket = endpoint.firstIndex(of: "]") {
            let colon = endpoint.index(after: closingBracket)
            guard colon < endpoint.endIndex, endpoint[colon] == ":" else { return nil }
            let portStart = endpoint.index(after: colon)
            guard portStart < endpoint.endIndex else { return nil }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
            let portText = endpoint[portStart...]
            guard let port = UInt16(portText) else { return nil }
            return ADBNetworkEndpoint(host: host, port: port)
        }
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = UInt16(endpoint[endpoint.index(after: colon)...]) else { return nil }
        let host = String(endpoint[..<colon])
        guard !host.contains(":") else { return nil }
        return ADBNetworkEndpoint(host: host, port: port)
    }
}

enum ADBDeviceRecoveryPolicy {
    static let failuresBeforeReachabilityCheck = 2

    static func shouldCheckEndpoint(
        consecutiveFailures: Int,
        failureDetail: String,
        hasAdvertisedService: Bool
    ) -> Bool {
        guard hasAdvertisedService,
              consecutiveFailures >= failuresBeforeReachabilityCheck else { return false }
        return failureDetail.localizedCaseInsensitiveContains("no route to host")
    }
}

enum ADBConnectionTargetResolver {
    static func resolve(
        device: LastVerifiedDevice,
        services: [BonjourService],
        previous: ADBConnectionTarget?
    ) -> ADBConnectionTarget {
        if let service = BonjourCorrelator.connectService(for: device, among: services) {
            return ADBConnectionTarget(device: device, service: service)
        }
        // DNSServiceGetAddrInfo publishes address-family changes incrementally
        // and refresh briefly publishes no services. Keep the last live target
        // instead of bouncing back to a stale endpoint persisted at pairing.
        return previous ?? ADBConnectionTarget(device: device, service: nil)
    }
}

enum LastVerifiedDeviceStore {
    private static let key = "lastVerifiedDevice"

    static func load(defaults: UserDefaults = .standard) -> LastVerifiedDevice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastVerifiedDevice.self, from: data)
    }

    static func save(_ device: LastVerifiedDevice, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(device) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

enum PairedDeviceStore {
    private static let key = "pairedDevices"

    static func load(defaults: UserDefaults = .standard) -> [LastVerifiedDevice] {
        if let data = defaults.data(forKey: key),
           let devices = try? JSONDecoder().decode([LastVerifiedDevice].self, from: data) {
            return devices
        }
        if let legacy = LastVerifiedDeviceStore.load(defaults: defaults) {
            save([legacy], defaults: defaults)
            return [legacy]
        }
        return []
    }

    static func save(_ devices: [LastVerifiedDevice], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }

    static func upsert(_ device: LastVerifiedDevice, defaults: UserDefaults = .standard) {
        var devices = load(defaults: defaults)
        devices.removeAll { $0.endpoint == device.endpoint || $0.serviceName == device.serviceName }
        devices.append(device)
        save(devices, defaults: defaults)
    }
}
