import Darwin
import Foundation
import dnssd

enum BonjourDiscoveryError: LocalizedError {
    case browseFailed(DNSServiceErrorType)
    case resolveFailed(DNSServiceErrorType)

    var errorDescription: String? {
        switch self {
        case let .browseFailed(code): "Bonjour discovery could not start (error \(code))."
        case let .resolveFailed(code): "A wADB Bonjour service could not be resolved (error \(code))."
        }
    }
}

final class BonjourDiscovery {
    var onServicesChanged: (([BonjourService]) -> Void)?
    var onError: ((Error) -> Void)?

    private struct ServiceKey: Hashable {
        let name: String
        let type: String
        let domain: String
        let interfaceIndex: UInt32
    }

    private final class Resolution {
        weak var owner: BonjourDiscovery?
        let key: ServiceKey
        var resolveRef: DNSServiceRef?
        var addressRef: DNSServiceRef?
        var targetHost: String?
        var port: UInt16?
        var addresses = Set<String>()

        init(owner: BonjourDiscovery, key: ServiceKey) {
            self.owner = owner
            self.key = key
        }

        func stop() {
            if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
            if let addressRef { DNSServiceRefDeallocate(addressRef) }
            resolveRef = nil
            addressRef = nil
            addresses.removeAll()
        }

        deinit { stop() }
    }

    private let queue = DispatchQueue(label: "local.c5inco.wADB.bonjour")
    private var browserRefs: [String: DNSServiceRef] = [:]
    private var resolutions: [ServiceKey: Resolution] = [:]
    private var isRunning = false

    func start(completion: (() -> Void)? = nil) {
        queue.async {
            guard !self.isRunning else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            do {
                try self.startBrowserLocked(type: BonjourService.pairingType)
                try self.startBrowserLocked(type: BonjourService.connectType)
                self.isRunning = true
                if let completion { DispatchQueue.main.async(execute: completion) }
            } catch {
                self.stopLocked()
                DispatchQueue.main.async { self.onError?(error) }
            }
        }
    }

    func refresh() {
        queue.async {
            self.stopLocked()
            do {
                try self.startBrowserLocked(type: BonjourService.pairingType)
                try self.startBrowserLocked(type: BonjourService.connectType)
                self.isRunning = true
            } catch {
                self.stopLocked()
                DispatchQueue.main.async { self.onError?(error) }
            }
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func startBrowserLocked(type: String) throws {
        var reference: DNSServiceRef?
        let error = DNSServiceBrowse(
            &reference,
            0,
            0,
            type,
            nil,
            { _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, context in
                guard let context else { return }
                let owner = Unmanaged<BonjourDiscovery>.fromOpaque(context).takeUnretainedValue()
                owner.handleBrowse(
                    flags: flags,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    serviceName: serviceName,
                    type: regtype,
                    domain: replyDomain
                )
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let reference else {
            throw BonjourDiscoveryError.browseFailed(error)
        }
        DNSServiceSetDispatchQueue(reference, queue)
        browserRefs[type] = reference
    }

    private func handleBrowse(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        serviceName: UnsafePointer<CChar>?,
        type: UnsafePointer<CChar>?,
        domain: UnsafePointer<CChar>?
    ) {
        guard errorCode == kDNSServiceErr_NoError,
              let serviceName, let type, let domain else {
            if errorCode != kDNSServiceErr_NoError {
                DispatchQueue.main.async { self.onError?(BonjourDiscoveryError.browseFailed(errorCode)) }
            }
            return
        }
        let key = ServiceKey(
            name: String(cString: serviceName),
            type: String(cString: type),
            domain: String(cString: domain),
            interfaceIndex: interfaceIndex
        )
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            guard resolutions[key] == nil else { return }
            let resolution = Resolution(owner: self, key: key)
            resolutions[key] = resolution
            beginResolve(resolution)
        } else {
            resolutions.removeValue(forKey: key)?.stop()
            publishLocked()
        }
    }

    private func beginResolve(_ resolution: Resolution) {
        var reference: DNSServiceRef?
        let key = resolution.key
        let error = DNSServiceResolve(
            &reference,
            0,
            key.interfaceIndex,
            key.name,
            key.type,
            key.domain,
            { _, _, interfaceIndex, errorCode, _, hostTarget, port, _, _, context in
                guard let context else { return }
                let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                resolution.owner?.handleResolve(
                    resolution,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    hostTarget: hostTarget,
                    networkPort: port
                )
            },
            Unmanaged.passUnretained(resolution).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let reference else {
            resolutions.removeValue(forKey: key)
            DispatchQueue.main.async { self.onError?(BonjourDiscoveryError.resolveFailed(error)) }
            return
        }
        resolution.resolveRef = reference
        DNSServiceSetDispatchQueue(reference, queue)
    }

    private func handleResolve(
        _ resolution: Resolution,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        hostTarget: UnsafePointer<CChar>?,
        networkPort: UInt16
    ) {
        guard errorCode == kDNSServiceErr_NoError, let hostTarget else {
            DispatchQueue.main.async { self.onError?(BonjourDiscoveryError.resolveFailed(errorCode)) }
            return
        }
        if let resolveRef = resolution.resolveRef {
            DNSServiceRefDeallocate(resolveRef)
            resolution.resolveRef = nil
        }
        resolution.targetHost = String(cString: hostTarget)
        resolution.port = UInt16(bigEndian: networkPort)
        var reference: DNSServiceRef?
        let error = DNSServiceGetAddrInfo(
            &reference,
            0,
            interfaceIndex,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            hostTarget,
            { _, flags, interfaceIndex, errorCode, _, address, _, context in
                guard let context else { return }
                let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                resolution.owner?.handleAddress(
                    resolution,
                    flags: flags,
                    interfaceIndex: interfaceIndex,
                    errorCode: errorCode,
                    address: address
                )
            },
            Unmanaged.passUnretained(resolution).toOpaque()
        )
        guard error == kDNSServiceErr_NoError, let reference else {
            DispatchQueue.main.async { self.onError?(BonjourDiscoveryError.resolveFailed(error)) }
            return
        }
        resolution.addressRef = reference
        DNSServiceSetDispatchQueue(reference, queue)
    }

    private func handleAddress(
        _ resolution: Resolution,
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        guard errorCode == kDNSServiceErr_NoError, let address,
              var host = Self.numericHost(address) else {
            if Self.shouldPublishAddressResults(
                flags: flags,
                errorCode: errorCode,
                hasResolvedAddresses: !resolution.addresses.isEmpty
            ) {
                publishLocked()
            }
            if errorCode != kDNSServiceErr_NoError {
                DispatchQueue.main.async { self.onError?(BonjourDiscoveryError.resolveFailed(errorCode)) }
            }
            return
        }
        if host.hasPrefix("fe80:"), !host.contains("%"),
           let interfaceName = Self.interfaceName(interfaceIndex) {
            host += "%\(interfaceName)"
        }
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            resolution.addresses.insert(host)
        } else {
            resolution.addresses.remove(host)
        }
        // DNSServiceGetAddrInfo may deliver the address families as one batch.
        // Wait for its final callback so reconnection sees every candidate
        // before it starts dialing the preferred address.
        if Self.shouldPublishAddressResults(
            flags: flags,
            errorCode: errorCode,
            hasResolvedAddresses: !resolution.addresses.isEmpty
        ) {
            publishLocked()
        }
    }

    static func shouldPublishAddressResults(
        flags: DNSServiceFlags,
        errorCode: DNSServiceErrorType,
        hasResolvedAddresses: Bool
    ) -> Bool {
        guard flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 else { return false }
        return errorCode == kDNSServiceErr_NoError || hasResolvedAddresses
    }

    private func publishLocked() {
        let services = resolutions.values.compactMap { resolution -> BonjourService? in
            guard let port = resolution.port else { return nil }
            let hosts = Array(resolution.addresses)
            guard !hosts.isEmpty else { return nil }
            let key = resolution.key
            return BonjourService(
                name: key.name,
                type: key.type,
                domain: key.domain,
                hosts: hosts,
                targetHost: resolution.targetHost,
                port: port,
                interfaceIndex: key.interfaceIndex
            )
        }.sorted { $0.identity < $1.identity }
        DispatchQueue.main.async { self.onServicesChanged?(services) }
    }

    private func stopLocked() {
        browserRefs.values.forEach(DNSServiceRefDeallocate)
        browserRefs.removeAll()
        resolutions.values.forEach { $0.stop() }
        resolutions.removeAll()
        isRunning = false
        DispatchQueue.main.async { self.onServicesChanged?([]) }
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        var storage = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t
        switch Int32(address.pointee.sa_family) {
        case AF_INET: length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return nil
        }
        guard getnameinfo(address, length, &storage, socklen_t(storage.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: storage)
    }

    private static func interfaceName(_ index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &name) != nil else { return nil }
        return String(cString: name)
    }
}
