import Foundation

/// Extracts the `Host` header from the first plain-HTTP request.
enum HTTPHostParser {
    static func host(in data: Data) -> String? {
        guard let text = String(data: data.prefix(8192), encoding: .isoLatin1) else { return nil }
        let headerBlock = text.components(separatedBy: "\r\n\r\n").first ?? text
        for line in headerBlock.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                var host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
                if host.hasPrefix("[") { // IPv6 literal
                    host = String(host.dropFirst().prefix { $0 != "]" })
                } else if let portColon = host.lastIndex(of: ":") {
                    host = String(host[..<portColon])
                }
                return host.isEmpty ? nil : host
            }
        }
        return nil
    }
}
