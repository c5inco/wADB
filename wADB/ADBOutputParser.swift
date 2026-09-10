import Foundation

enum ADBOutputParser {
    /// `adb connect` exits 0 even when it fails ("failed to connect to ..."),
    /// so the output is the only trustworthy signal.
    static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        guard !text.contains("failed to connect"),
              !text.contains("cannot connect"),
              !text.contains("unable to connect") else { return false }
        return text.contains("connected to")
    }

    /// `adb pair` reports success only with exit status 0 and a
    /// "Successfully paired to <endpoint>" line; any other combination is a
    /// failure regardless of what else it printed.
    static func pairSucceeded(_ result: ADBProcessResult) -> Bool {
        result.status == 0
            && result.combinedOutput.lowercased().contains("successfully paired")
    }

    /// `adb connect` prints "failed to authenticate to <endpoint>" when the
    /// device has the pairing key but the user has not yet approved this host.
    static func connectRequiresAuthorization(_ output: String) -> Bool {
        output.lowercased().contains("failed to authenticate")
    }

    /// `adb connect` appends a reason when the socket itself fails
    /// ("failed to connect to '<endpoint>': Connection refused"). When TCP
    /// succeeds but the phone rejects the TLS handshake, the server prints
    /// only "failed to connect to <endpoint>". The missing reason is the one
    /// client-visible hint that the phone reached this host and turned it
    /// away.
    static func connectWasRejectedWithoutReason(_ output: String) -> Bool {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count == 1 else { return false }
        let line = lines[0].lowercased()
        let prefix = "failed to connect to "
        guard line.hasPrefix(prefix) else { return false }
        var remainder = Substring(line.dropFirst(prefix.count))
        if remainder.hasPrefix("'") {
            remainder = remainder.dropFirst()
            guard let closingQuote = remainder.firstIndex(of: "'") else { return false }
            let trailing = remainder[remainder.index(after: closingQuote)...]
            return trailing.trimmingCharacters(in: .whitespaces).isEmpty
        }
        // An endpoint never contains whitespace; an appended reason always does.
        return !remainder.isEmpty && !remainder.contains(where: \.isWhitespace)
    }

    static func parseDeviceList(_ output: String) -> [ADBTransport] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parseTransportLine(String(line))
        }
    }

    static func collapsePhysicalDevices(_ transports: [ADBTransport]) -> [ADBPhysicalDevice] {
        var order: [String] = []
        var grouped: [String: [ADBTransport]] = [:]
        for transport in transports {
            let key = transport.fingerprint
                ?? transport.connectServiceName.map { "service:\($0)" }
                ?? "serial:\(transport.serial)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(transport)
        }
        return order.compactMap { key in
            grouped[key].map { ADBPhysicalDevice(key: key, transports: $0) }
        }
    }

    private static func parseTransportLine(_ line: String) -> ADBTransport? {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 2, fields[0] != "List" else { return nil }
        var attributes: [String: String] = [:]
        for field in fields.dropFirst(2) {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = String(field[..<colon])
            let value = String(field[field.index(after: colon)...])
            attributes[key] = value
        }
        return ADBTransport(
            serial: fields[0],
            state: ADBTransportState(adbValue: fields[1]),
            attributes: attributes
        )
    }
}

enum TrackDevicesParserError: LocalizedError {
    case invalidFrameHeader
    case oversizedFrame

    var errorDescription: String? {
        switch self {
        case .invalidFrameHeader: "ADB transport observer returned an invalid frame."
        case .oversizedFrame: "ADB transport observer returned an unexpectedly large frame."
        }
    }
}

struct TrackDevicesFrameParser {
    private var buffer = Data()

    mutating func append<D: DataProtocol>(_ bytes: D) throws -> [[ADBTransport]] {
        buffer.append(contentsOf: bytes)
        var snapshots: [[ADBTransport]] = []
        while buffer.count >= 4 {
            guard let header = String(data: buffer.prefix(4), encoding: .utf8),
                  let length = Int(header, radix: 16) else {
                throw TrackDevicesParserError.invalidFrameHeader
            }
            guard length <= 1_048_576 else { throw TrackDevicesParserError.oversizedFrame }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            let text = String(decoding: payload, as: UTF8.self)
            snapshots.append(ADBOutputParser.parseDeviceList(text))
        }
        return snapshots
    }
}
