import Darwin
import Foundation

struct DiagnosticsContext {
    let appVersion: String
    let appBuild: String
    let adbVersion: String?
    let sensitiveValues: [String]
}

enum DiagnosticsExportError: LocalizedError {
    case logCollectionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .logCollectionFailed(detail):
            "The wADB system log could not be collected. \(detail)"
        }
    }
}

enum DiagnosticsExporter {
    static let appLogWindow = "24h"
    static let maximumSourceBytes = 512 * 1024

    static func makeReport(
        context: DiagnosticsContext,
        now: Date = Date(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let appLogs: String
        do {
            appLogs = try collectAppLogs()
        } catch {
            appLogs = "wADB log collection was unavailable: \(error.localizedDescription)"
        }
        let adbLogs = collectADBLogs(environment: environment)
        return buildReport(
            context: context,
            appLogs: appLogs,
            adbLogs: adbLogs,
            now: now
        )
    }

    static func buildReport(
        context: DiagnosticsContext,
        appLogs: String,
        adbLogs: String?,
        now: Date
    ) -> String {
        var redactor = DiagnosticsRedactor(sensitiveValues: context.sensitiveValues)
        let generated = ISO8601DateFormatter().string(from: now)
        let adbVersion = context.adbVersion.map { redactor.redact($0) } ?? "Unavailable"
        let appSection = redactor.redact(appLogs).trimmingCharacters(in: .whitespacesAndNewlines)
        let adbSection = adbLogs.map { redactor.redact($0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        wADB Anonymous Diagnostics
        ==========================

        Generated: \(generated)
        wADB: \(context.appVersion) (\(context.appBuild))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(architectureName)
        ADB: \(adbVersion)

        Privacy
        -------
        This report was created locally and was not uploaded automatically.
        It includes wADB's last 24 hours of unified logs and, when available,
        the most recent \(maximumSourceBytes / 1024) KiB of the local ADB server log.
        Known device identifiers and common personal identifiers were replaced
        with stable placeholders. The placeholders preserve event correlation.
        Review this file before sharing it.

        wADB unified log (last \(appLogWindow))
        ---------------------------------------
        \(appSection.isEmpty ? "No wADB log entries were found." : appSection)

        ADB server log (recent tail)
        ----------------------------
        \(adbSection?.isEmpty == false ? adbSection! : "No local ADB server log was found.")
        """ + "\n"
    }

    private static func collectAppLogs() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show",
            "--style", "compact",
            "--info",
            "--last", appLogWindow,
            "--predicate", "subsystem == 'local.c5inco.wADB'",
        ]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw DiagnosticsExportError.logCollectionFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: data.suffix(4_096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiagnosticsExportError.logCollectionFailed(
                detail.isEmpty ? "The log command exited with status \(process.terminationStatus)." : detail
            )
        }
        return String(decoding: data.suffix(maximumSourceBytes), as: UTF8.self)
    }

    private static func collectADBLogs(environment: [String: String]) -> String? {
        let fileName = "adb.\(getuid()).log"
        var candidates: [URL] = []
        if let temporaryDirectory = environment["TMPDIR"], !temporaryDirectory.isEmpty {
            candidates.append(URL(fileURLWithPath: temporaryDirectory).appendingPathComponent(fileName))
        }
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName))
        candidates.append(URL(fileURLWithPath: "/tmp").appendingPathComponent(fileName))

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            guard let handle = try? FileHandle(forReadingFrom: candidate) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(maximumSourceBytes)
                ? size - UInt64(maximumSourceBytes)
                : 0
            try? handle.seek(toOffset: offset)
            return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        }
        return nil
    }

    private static var architectureName: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}

struct DiagnosticsRedactor {
    private struct Rule {
        let label: String
        let expression: NSRegularExpression
    }

    private let sensitiveValues: [String]
    private let rules: [Rule]
    private var replacements: [String: String] = [:]
    private var nextIndex: [String: Int] = [:]

    init(sensitiveValues: [String]) {
        self.sensitiveValues = Array(Set(sensitiveValues.filter { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
        })).sorted { $0.count > $1.count }
        rules = [
            Self.rule("home", #"/(?:Users|home)/[^/\s]+"#),
            Self.rule("temp", #"/(?:private/)?var/folders/[^/\s]+/[^/\s]+"#),
            Self.rule("email", #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#),
            Self.rule("uuid", #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"#),
            Self.rule("mac", #"(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"#),
            Self.rule("endpoint", #"\[(?=[^\]]*:[^\]]*:)[0-9A-Fa-f:]+(?:%[A-Za-z0-9._-]+)?\](?::\d{1,5})?"#),
            Self.rule("endpoint", #"(?<![A-Za-z0-9])(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?"#),
            Self.rule("host", #"(?i)\b[a-z0-9][a-z0-9._-]*\.local\.?\b"#),
            Self.rule("bonjour", #"(?i)\badb-[a-z0-9._-]{6,}\b"#),
            Self.rule("serial", #"(?m)^\S+(?=\s+(?:device|offline|unauthorized|no permissions)\b)"#),
            Self.rule("serial", #"(?i)(?<=device ')[A-Za-z0-9._:-]{6,}(?=')"#),
        ]
    }

    mutating func redact(_ input: String) -> String {
        var output = input
        for value in sensitiveValues {
            guard output.contains(value) else { continue }
            output = output.replacingOccurrences(
                of: value,
                with: replacement(for: value, label: "device")
            )
        }
        for rule in rules {
            output = redactMatches(in: output, using: rule)
        }
        return output
    }

    private mutating func redactMatches(in input: String, using rule: Rule) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = rule.expression.matches(in: input, range: range)
        guard !matches.isEmpty else { return input }
        var output = input
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: output) else { continue }
            let value = String(output[swiftRange])
            output.replaceSubrange(swiftRange, with: replacement(for: value, label: rule.label))
        }
        return output
    }

    private mutating func replacement(for value: String, label: String) -> String {
        let key = "\(label)\u{0}\(value.lowercased())"
        if let existing = replacements[key] { return existing }
        let index = (nextIndex[label] ?? 0) + 1
        nextIndex[label] = index
        let replacement = "<\(label)-\(index)>"
        replacements[key] = replacement
        return replacement
    }

    private static func rule(_ label: String, _ pattern: String) -> Rule {
        // These literals are covered by unit tests and are programmer-owned.
        Rule(label: label, expression: try! NSRegularExpression(pattern: pattern))
    }
}
