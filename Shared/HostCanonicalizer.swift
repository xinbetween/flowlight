import Darwin
import Foundation

/// One spelling for a destination everywhere a blocking decision is made.
///
/// DNS names are case-insensitive and may arrive with a root-label dot or in Unicode. A signed pack, the app
/// previewing it, and the extension enforcing it must not disagree about any of those spellings.
enum HostCanonicalizer {
    /// A hostname that has already crossed the canonicalization boundary. The initializer is deliberately hidden so
    /// PSL consumers can skip repeated canonicalization without accepting an unchecked string.
    struct CanonicalHost: Hashable, Sendable {
        let value: String

        fileprivate init(_ value: String) { self.value = value }
    }

    static func canonicalHost(_ input: String) -> CanonicalHost? {
        guard let value = host(input) else { return nil }
        return CanonicalHost(value)
    }

    static func host(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if let address = address(value) { return address }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }

        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return validatedDNSName(value.lowercased())
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard let ascii = components.url?.host?.lowercased() else { return nil }
        return validatedDNSName(ascii)
    }

    static func address(_ input: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, input, &v4) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, input, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buffer)
        }
        return nil
    }

    private static func validatedDNSName(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy(validLabel) else { return nil }
        return value
    }

    private static func validLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
        return label.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D
        }
    }
}
