import Darwin
import Foundation

/// Classic BPF opcodes (net/bpf.h). The C macros are not imported into Swift.
enum BPF {
    static let LD: UInt16 = 0x00, LDX: UInt16 = 0x01, ALU: UInt16 = 0x04, JMP: UInt16 = 0x05, RET: UInt16 = 0x06, MISC: UInt16 = 0x07
    static let W: UInt16 = 0x00, H: UInt16 = 0x08, B: UInt16 = 0x10
    static let IMM: UInt16 = 0x00, ABS: UInt16 = 0x20, IND: UInt16 = 0x40, MSH: UInt16 = 0xA0
    static let ADD: UInt16 = 0x00, AND: UInt16 = 0x50, LSH: UInt16 = 0x60, RSH: UInt16 = 0x70
    static let JEQ: UInt16 = 0x10, JSET: UInt16 = 0x40
    static let K: UInt16 = 0x00, X: UInt16 = 0x08
    static let TAX: UInt16 = 0x00

    // ioctl requests: _IOW/_IOR('B', n, type)
    static let BIOCSBLEN: UInt = 0xC004_4266
    static let BIOCSETF: UInt = 0x8010_4267
    static let BIOCGDLT: UInt = 0x4004_426A
    static let BIOCSETIF: UInt = 0x8020_426C
    static let BIOCIMMEDIATE: UInt = 0x8004_4270
    static let BIOCSSEESENT: UInt = 0x8004_4277

    static let DLT_NULL: UInt32 = 0
    static let DLT_EN10MB: UInt32 = 1
}

/// Tiny assembler with symbolic jump targets for building the capture filter.
struct BPFAssembler {
    enum Item {
        case stmt(UInt16, UInt32)
        case jump(UInt16, UInt32, String, String)
        case label(String)
    }
    private(set) var items: [Item] = []

    mutating func stmt(_ code: UInt16, _ k: UInt32 = 0) { items.append(.stmt(code, k)) }
    mutating func jump(_ code: UInt16, _ k: UInt32, _ t: String, _ f: String) { items.append(.jump(code, k, t, f)) }
    mutating func label(_ name: String) { items.append(.label(name)) }

    func assemble() -> [bpf_insn] {
        var positions: [String: Int] = [:]
        var index = 0
        for item in items {
            if case .label(let name) = item { positions[name] = index } else { index += 1 }
        }
        var out: [bpf_insn] = []
        for item in items {
            switch item {
            case .label: continue
            case let .stmt(code, k):
                out.append(bpf_insn(code: code, jt: 0, jf: 0, k: k))
            case let .jump(code, k, t, f):
                let here = out.count
                let jt = positions[t]! - here - 1
                let jf = positions[f]! - here - 1
                precondition(jt >= 0 && jt < 256 && jf >= 0 && jf < 256, "BPF jump out of range")
                out.append(bpf_insn(code: code, jt: UInt8(jt), jf: UInt8(jf), k: k))
            }
        }
        return out
    }
}

enum CaptureFilter {
    static let snapLength: UInt32 = 4096

    /// Accepts only what hostname learning needs: DNS responses (UDP source port 53) and TLS
    /// ClientHellos (TCP to port 443 whose payload starts with a handshake record of type ClientHello),
    /// over IPv4 and IPv6. Everything else is dropped in the kernel, so bulk traffic costs nothing.
    static func program(linkType: UInt32) -> [bpf_insn]? {
        let L: UInt32
        var a = BPFAssembler()
        switch linkType {
        case BPF.DLT_EN10MB:
            L = 14
            a.stmt(BPF.LD | BPF.H | BPF.ABS, 12)
            a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x0800, "v4", "check6")
            a.label("check6")
            a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x86DD, "v6", "reject")
        case BPF.DLT_NULL:
            // 4-byte address family in host (little-endian) order, loaded big-endian.
            L = 4
            a.stmt(BPF.LD | BPF.W | BPF.ABS, 0)
            a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(AF_INET).byteSwapped, "v4", "check6")
            a.label("check6")
            a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(AF_INET6).byteSwapped, "v6", "reject")
        default:
            return nil
        }

        // IPv4
        a.label("v4")
        a.stmt(BPF.LD | BPF.H | BPF.ABS, L + 6)                 // flags + fragment offset
        a.jump(BPF.JMP | BPF.JSET | BPF.K, 0x1FFF, "reject", "v4proto")
        a.label("v4proto")
        a.stmt(BPF.LD | BPF.B | BPF.ABS, L + 9)                 // protocol
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(IPPROTO_UDP), "v4udp", "v4tcpcheck")
        a.label("v4tcpcheck")
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(IPPROTO_TCP), "v4tcp", "reject")
        a.label("v4udp")
        a.stmt(BPF.LDX | BPF.B | BPF.MSH, L)                    // X = IP header length
        a.stmt(BPF.LD | BPF.H | BPF.IND, L)                     // UDP source port
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 53, "accept", "reject")
        a.label("v4tcp")
        a.stmt(BPF.LDX | BPF.B | BPF.MSH, L)
        a.stmt(BPF.LD | BPF.H | BPF.IND, L + 2)                 // TCP destination port
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 443, "v4payload", "reject")
        a.label("v4payload")
        a.stmt(BPF.LD | BPF.B | BPF.IND, L + 12)                // data offset (high nibble)
        a.stmt(BPF.ALU | BPF.RSH | BPF.K, 4)
        a.stmt(BPF.ALU | BPF.LSH | BPF.K, 2)
        a.stmt(BPF.ALU | BPF.ADD | BPF.X)                       // A = IP hdr + TCP hdr
        a.stmt(BPF.MISC | BPF.TAX)
        a.stmt(BPF.LD | BPF.B | BPF.IND, L)                     // first payload byte
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x16, "v4hello", "reject")
        a.label("v4hello")
        a.stmt(BPF.LD | BPF.B | BPF.IND, L + 5)                 // handshake type
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x01, "accept", "reject")

        // IPv6 (no extension headers)
        a.label("v6")
        a.stmt(BPF.LD | BPF.B | BPF.ABS, L + 6)                 // next header
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(IPPROTO_UDP), "v6udp", "v6tcpcheck")
        a.label("v6tcpcheck")
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, UInt32(IPPROTO_TCP), "v6tcp", "reject")
        a.label("v6udp")
        a.stmt(BPF.LD | BPF.H | BPF.ABS, L + 40)
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 53, "accept", "reject")
        a.label("v6tcp")
        a.stmt(BPF.LD | BPF.H | BPF.ABS, L + 42)
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 443, "v6payload", "reject")
        a.label("v6payload")
        a.stmt(BPF.LD | BPF.B | BPF.ABS, L + 52)
        a.stmt(BPF.ALU | BPF.RSH | BPF.K, 4)
        a.stmt(BPF.ALU | BPF.LSH | BPF.K, 2)
        a.stmt(BPF.MISC | BPF.TAX)                              // X = TCP header length
        a.stmt(BPF.LD | BPF.B | BPF.IND, L + 40)
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x16, "v6hello", "reject")
        a.label("v6hello")
        a.stmt(BPF.LD | BPF.B | BPF.IND, L + 45)
        a.jump(BPF.JMP | BPF.JEQ | BPF.K, 0x01, "accept", "reject")

        a.label("accept")
        a.stmt(BPF.RET | BPF.K, snapLength)
        a.label("reject")
        a.stmt(BPF.RET | BPF.K, 0)
        return a.assemble()
    }
}
