import Foundation
import Security

enum ADBQRPayloadError: LocalizedError {
    case invalidCredential
    case randomGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidCredential: "Could not create valid wADB QR credentials."
        case .randomGenerationFailed: "Secure random data generation failed."
        }
    }
}

final class ADBQRPayload {
    private final class SecureBuffer {
        private(set) var data: Data

        init(_ data: Data) { self.data = data }

        func erase() {
            guard !data.isEmpty else { return }
            data.resetBytes(in: 0..<data.count)
            data.removeAll(keepingCapacity: false)
        }

        deinit { erase() }
    }

    private let instanceName: SecureBuffer
    private let password: SecureBuffer

    init(instanceName: Data, password: Data) throws {
        guard Self.isSafe(instanceName), Self.isSafe(password),
              instanceName.starts(with: Data("studio-".utf8)) else {
            throw ADBQRPayloadError.invalidCredential
        }
        self.instanceName = SecureBuffer(instanceName)
        self.password = SecureBuffer(password)
    }

    static func random() throws -> ADBQRPayload {
        var name = Data("studio-".utf8)
        name.append(try randomQRSafeBytes(count: 10))
        return try ADBQRPayload(instanceName: name, password: randomQRSafeBytes(count: 10))
    }

    func encoded() -> Data {
        var result = Data("WIFI:T:ADB;S:".utf8)
        result.append(instanceName.data)
        result.append(Data(";P:".utf8))
        result.append(password.data)
        result.append(Data(";;".utf8))
        return result
    }

    func passwordInput() -> NSMutableData {
        let result = NSMutableData(data: password.data)
        var newline: UInt8 = 0x0A
        result.append(&newline, length: 1)
        return result
    }

    func matches(serviceName: String) -> Bool {
        instanceName.data == Data(serviceName.utf8)
    }

    func erase() {
        instanceName.erase()
        password.erase()
    }

    deinit { erase() }

    static func isValid(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8),
              text.hasPrefix("WIFI:T:ADB;S:"), text.hasSuffix(";;") else { return false }
        let content = text.dropFirst("WIFI:T:ADB;S:".count).dropLast(2)
        guard let separator = content.range(of: ";P:") else { return false }
        let name = Data(content[..<separator.lowerBound].utf8)
        let password = Data(content[separator.upperBound...].utf8)
        return name.starts(with: Data("studio-".utf8)) && isSafe(name) && isSafe(password)
    }

    private static func isSafe(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.allSatisfy { byte in
            (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 45
                || byte == 95
        }
    }

    private static func randomQRSafeBytes(count: Int) throws -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        var random = [UInt8](repeating: 0, count: count)
        defer {
            _ = random.withUnsafeMutableBytes { bytes in
                bytes.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }
        let status = random.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ADBQRPayloadError.randomGenerationFailed
        }
        var result = Data(count: count)
        result.withUnsafeMutableBytes { output in
            let outputBytes = output.bindMemory(to: UInt8.self)
            for index in random.indices {
                outputBytes[index] = alphabet[Int(random[index]) % alphabet.count]
            }
        }
        return result
    }
}
