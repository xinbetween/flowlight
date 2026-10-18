import Darwin
import Foundation

/// One spelling for a destination everywhere a blocking decision is made.
///
/// DNS names are case-insensitive and may arrive with a root-label dot or in Unicode. A signed pack, the app
/// previewing it, and the extension enforcing it must not disagree about any of those spellings.
enum HostCanonicalizer {
    static func host(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
        if let address = address(value) { return address }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = value
        guard let ascii = components.url?.host?.lowercased(), !ascii.isEmpty, ascii.utf8.count <= 253 else {
            return nil
        }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy(validLabel) else { return nil }
        return ascii
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

    private static func validLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
        return label.utf8.allSatisfy {
            ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D
        }
    }
}
