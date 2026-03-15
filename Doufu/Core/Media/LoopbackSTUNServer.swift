//
//  LoopbackSTUNServer.swift
//  Doufu
//
//  Minimal STUN server (RFC 5389) bound to 127.0.0.1.
//  Returns XOR-MAPPED-ADDRESS so WebRTC peers discover loopback srflx candidates,
//  enabling PeerConnection without any real network interface.
//

import Foundation

final class LoopbackSTUNServer: Sendable {

    let port: UInt16

    private let fd: Int32
    private let source: DispatchSourceRead

    private static let magicCookie: UInt32 = 0x2112_A442

    init?() {
        // Create UDP socket
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return nil }

        // Bind to 127.0.0.1:0 (random port)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { close(sock); return nil }

        // Read back the assigned port
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &len)
            }
        }
        guard nameOK == 0 else { close(sock); return nil }

        self.fd = sock
        self.port = UInt16(bigEndian: bound.sin_port)

        // Dispatch source for incoming UDP packets
        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: DispatchQueue.global(qos: .utility))
        self.source = src

        src.setEventHandler { [fd] in
            Self.handlePacket(fd: fd)
        }
        src.setCancelHandler {
            close(sock)
        }
        src.resume()
    }

    deinit {
        source.cancel()
    }

    // MARK: - Packet Handling

    private static func handlePacket(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var srcAddr = sockaddr_in()
        var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buf, buf.count, 0, sa, &srcLen)
            }
        }
        guard n >= 20 else { return }

        // STUN header: Type(2) Length(2) MagicCookie(4) TransactionID(12)
        let msgType = UInt16(buf[0]) << 8 | UInt16(buf[1])
        let cookie = UInt32(buf[4]) << 24 | UInt32(buf[5]) << 16 | UInt32(buf[6]) << 8 | UInt32(buf[7])

        // Only handle Binding Request (0x0001) with correct magic cookie
        guard msgType == 0x0001, cookie == magicCookie else { return }

        // Build Binding Success Response (0x0101)
        let clientPort = srcAddr.sin_port  // network byte order
        let clientAddr = srcAddr.sin_addr.s_addr  // network byte order

        // XOR-MAPPED-ADDRESS attribute (12 bytes)
        let xPort = UInt16(bigEndian: clientPort) ^ UInt16(magicCookie >> 16)
        let xAddr = UInt32(bigEndian: clientAddr) ^ magicCookie

        // Response: 20-byte header + 12-byte attribute = 32 bytes
        var resp = [UInt8](repeating: 0, count: 32)

        // Header
        resp[0] = 0x01; resp[1] = 0x01  // Binding Success Response
        resp[2] = 0x00; resp[3] = 0x0C  // Attributes length = 12
        // Magic cookie
        resp[4] = buf[4]; resp[5] = buf[5]; resp[6] = buf[6]; resp[7] = buf[7]
        // Transaction ID (copy from request)
        for i in 8..<20 { resp[i] = buf[i] }

        // XOR-MAPPED-ADDRESS attribute
        resp[20] = 0x00; resp[21] = 0x20  // Type: XOR-MAPPED-ADDRESS
        resp[22] = 0x00; resp[23] = 0x08  // Length: 8
        resp[24] = 0x00                    // Reserved
        resp[25] = 0x01                    // Family: IPv4
        resp[26] = UInt8(xPort >> 8); resp[27] = UInt8(xPort & 0xFF)
        resp[28] = UInt8(xAddr >> 24); resp[29] = UInt8((xAddr >> 16) & 0xFF)
        resp[30] = UInt8((xAddr >> 8) & 0xFF); resp[31] = UInt8(xAddr & 0xFF)

        // Send response
        _ = withUnsafePointer(to: &srcAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, resp, resp.count, 0, sa, srcLen)
            }
        }
    }
}
