import Foundation

/// Extracts the SNI hostname from a TLS ClientHello (first outbound record).
enum TLSSNIParser {
    /// Strict parse first; if the ClientHello is truncated (large post-quantum hellos span two TCP
    /// segments and we only see the first), fall back to scanning for a well-formed server_name extension.
    static func serverName(in data: Data) -> String? {
        strictServerName(in: data) ?? scanForServerName(in: data)
    }

    /// Looks for `00 00 | extLen | listLen | 00 | nameLen | name` with self-consistent lengths.
    static func scanForServerName(in data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count > 50, b[0] == 0x16, b.count > 5, b[5] == 0x01 else { return nil }
        var i = 43 // skip record + handshake headers, version and random
        while i + 9 < b.count {
            if b[i] == 0, b[i + 1] == 0 {
                let extLen = Int(b[i + 2]) << 8 | Int(b[i + 3])
                let listLen = Int(b[i + 4]) << 8 | Int(b[i + 5])
                let nameLen = Int(b[i + 7]) << 8 | Int(b[i + 8])
                if b[i + 6] == 0, nameLen >= 3, nameLen <= 253, listLen == nameLen + 3, extLen == listLen + 2,
                   i + 9 + nameLen <= b.count {
                    let nameBytes = b[(i + 9)..<(i + 9 + nameLen)]
                    if nameBytes.allSatisfy({ isHostnameByte($0) }), nameBytes.contains(UInt8(ascii: ".")),
                       let name = String(bytes: nameBytes, encoding: .ascii) {
                        return name.lowercased()
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func isHostnameByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x2E || c == 0x5F
    }

    static func strictServerName(in data: Data) -> String? {
        let b = [UInt8](data)
        var i = 0
        func u8() -> Int? { guard i < b.count else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard i + 1 < b.count else { return nil }; defer { i += 2 }; return Int(b[i]) << 8 | Int(b[i + 1]) }
        func u24() -> Int? { guard i + 2 < b.count else { return nil }; defer { i += 3 }; return Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2]) }
        func skip(_ n: Int) -> Bool { i += n; return i <= b.count }

        // TLS record header: type 0x16 (handshake), version, length
        guard u8() == 0x16, skip(2), u16() != nil else { return nil }
        // Handshake header: type 0x01 (ClientHello), length
        guard u8() == 0x01, u24() != nil else { return nil }
        // client_version + random
        guard skip(2 + 32) else { return nil }
        guard let sessionLen = u8(), skip(sessionLen) else { return nil }
        guard let cipherLen = u16(), skip(cipherLen) else { return nil }
        guard let compLen = u8(), skip(compLen) else { return nil }
        guard let extTotal = u16() else { return nil }
        let extEnd = min(b.count, i + extTotal)

        while i + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { return nil }
            let next = i + len
            if type == 0x0000 { // server_name
                guard u16() != nil else { return nil } // server_name_list length
                while i + 3 <= next {
                    guard let nameType = u8(), let nameLen = u16() else { return nil }
                    guard i + nameLen <= b.count else { return nil }
                    if nameType == 0 {
                        return String(bytes: b[i..<(i + nameLen)], encoding: .ascii)?.lowercased()
                    }
                    i += nameLen
                }
                return nil
            }
            i = next
        }
        return nil
    }
}
