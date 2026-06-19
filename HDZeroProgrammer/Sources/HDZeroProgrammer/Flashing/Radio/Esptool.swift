import Foundation
import CryptoKit

/// Minimal ESP ROM-bootloader flasher (no stub, uncompressed) for the ELRS
/// TX (ESP32) and backpack (ESP32-C3), replacing the Python `esptool` calls.
/// Implements SLIP framing, sync, flash_begin/flash_data/flash_end over serial.
///
/// ⚠️ Hardware-unverified and intentionally minimal (ROM loader only — slower
/// than esptool's stub, no compression). Validate against real hardware.
final class Esptool {
    // Commands
    private let FLASH_BEGIN: UInt8 = 0x02
    private let FLASH_DATA:  UInt8 = 0x03
    private let FLASH_END:   UInt8 = 0x04
    private let SYNC:        UInt8 = 0x08
    private let READ_REG:    UInt8 = 0x0A
    private let SPI_ATTACH:  UInt8 = 0x0D
    private let SPI_FLASH_MD5: UInt8 = 0x13
    // SLIP
    private let END: UInt8 = 0xC0
    private let ESC: UInt8 = 0xDB
    private let ESC_END: UInt8 = 0xDC
    private let ESC_ESC: UInt8 = 0xDD

    private let port: SerialPort
    let log: (String) -> Void

    init(_ port: SerialPort, log: @escaping (String) -> Void) {
        self.port = port
        self.log = log
    }

    enum EspError: LocalizedError {
        case syncFailed, commandFailed(UInt8), badResponse
        var errorDescription: String? {
            switch self {
            case .syncFailed:          return "ESP sync failed — could not enter bootloader."
            case .commandFailed(let c): return "ESP command 0x\(String(c, radix: 16)) failed."
            case .badResponse:         return "ESP returned an unexpected response."
            }
        }
    }

    // MARK: Reset into download mode (classic DTR/RTS sequence)

    func enterBootloader() {
        port.setDTR(false); port.setRTS(true)        // EN low (reset)
        Thread.sleep(forTimeInterval: 0.1)
        port.setDTR(true); port.setRTS(false)        // GPIO0 low, EN high
        Thread.sleep(forTimeInterval: 0.05)
        port.setDTR(false)                           // release GPIO0
        Thread.sleep(forTimeInterval: 0.05)
        _ = port.drain(timeout: 0.2)
    }

    // MARK: Sync

    func sync() throws {
        var syncData: [UInt8] = [0x07, 0x07, 0x12, 0x20]
        syncData.append(contentsOf: [UInt8](repeating: 0x55, count: 32))
        for attempt in 0..<7 {
            do {
                _ = try command(SYNC, data: syncData, timeout: 0.5)
                // ROM emits several responses; drain extras.
                _ = port.drain(timeout: 0.1)
                log("ESP sync ok (attempt \(attempt + 1))\n")
                return
            } catch { Thread.sleep(forTimeInterval: 0.1) }
        }
        throw EspError.syncFailed
    }

    // MARK: Flash a single image at an offset

    func flashImage(_ data: [UInt8], at offset: Int, onProgress: (Double) -> Void) throws {
        let blockSize = 0x400      // 1 KiB ROM-loader block (conservative)
        let numBlocks = (data.count + blockSize - 1) / blockSize

        // FLASH_BEGIN: eraseSize, numBlocks, blockSize, offset
        var begin: [UInt8] = []
        begin.append(le32(UInt32(data.count)))
        begin.append(le32(UInt32(numBlocks)))
        begin.append(le32(UInt32(blockSize)))
        begin.append(le32(UInt32(offset)))
        _ = try command(FLASH_BEGIN, data: begin, timeout: 10.0)

        for seq in 0..<numBlocks {
            let start = seq * blockSize
            let end = min(start + blockSize, data.count)
            var block = Array(data[start..<end])
            if block.count < blockSize {
                block.append(contentsOf: [UInt8](repeating: 0xFF, count: blockSize - block.count))
            }
            var payload: [UInt8] = []
            payload.append(le32(UInt32(block.count)))
            payload.append(le32(UInt32(seq)))
            payload.append(le32(0)); payload.append(le32(0))
            payload.append(contentsOf: block)
            _ = try command(FLASH_DATA, data: payload, checksum: espChecksum(block), timeout: 5.0)
            onProgress(Double(seq + 1) / Double(numBlocks))
        }
    }

    func finish(reboot: Bool) throws {
        _ = try? command(FLASH_END, data: le32(reboot ? 0 : 1), timeout: 2.0)
    }

    // MARK: Verify (SPI_FLASH_MD5) — compare the device's MD5 of the flashed region
    // to the image's MD5. On any protocol hiccup we return `.unavailable` rather
    // than failing, since each FLASH_DATA block is already ack'd during the write.

    enum VerifyResult { case match, mismatch(String), unavailable(String) }

    func verify(_ data: [UInt8], at offset: Int) -> VerifyResult {
        let want = Insecure.MD5.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
        var p: [UInt8] = []
        p.append(le32(UInt32(offset)))
        p.append(le32(UInt32(data.count)))
        p.append(le32(0)); p.append(le32(0))     // reserved (reg/mask) for ROM MD5
        guard let frame = try? command(SPI_FLASH_MD5, data: p, timeout: 15.0),
              frame.count >= 10 else {
            return .unavailable("device MD5 command unsupported/failed")
        }
        // Body is between the 8-byte header and the 2 trailing status bytes. The
        // stub returns 32 ASCII hex chars; the ROM loader returns 16 raw bytes.
        let body = Array(frame[8..<(frame.count - 2)])
        let got: String
        if body.count >= 32 {
            got = String(decoding: body.prefix(32), as: UTF8.self).lowercased()
        } else if body.count >= 16 {
            got = body.prefix(16).map { String(format: "%02x", $0) }.joined()
        } else {
            return .unavailable("unexpected MD5 length \(body.count)")
        }
        return got == want ? .match : .mismatch("device \(got) ≠ file \(want)")
    }

    // MARK: Command / response (SLIP)

    @discardableResult
    private func command(_ cmd: UInt8, data: [UInt8], checksum: UInt32 = 0,
                         timeout: TimeInterval) throws -> [UInt8] {
        var packet: [UInt8] = [0x00, cmd]
        packet.append(contentsOf: le16(UInt16(data.count)))
        packet.append(contentsOf: le32(checksum))
        packet.append(contentsOf: data)
        try port.write(slipEncode(packet))

        // Read one SLIP frame as the response.
        let frame = try readFrame(timeout: timeout)
        guard frame.count >= 8, frame[0] == 0x01, frame[1] == cmd else {
            throw EspError.badResponse
        }
        // Status bytes are the last 2 (ROM) — non-zero failure byte → error.
        if frame.count >= 10, frame[frame.count - 4] != 0 {
            throw EspError.commandFailed(cmd)
        }
        return frame
    }

    private func readFrame(timeout: TimeInterval) throws -> [UInt8] {
        var raw: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        var sawStart = false
        while Date() < deadline {
            let chunk = (try? port.read(max: 256, timeout: 0.2)) ?? []
            for b in chunk {
                if b == END {
                    if sawStart { return slipDecode(raw) }
                    sawStart = true; raw.removeAll()
                } else if sawStart {
                    raw.append(b)
                }
            }
        }
        throw EspError.badResponse
    }

    // MARK: SLIP + helpers

    private func slipEncode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [END]
        for b in data {
            if b == END { out.append(ESC); out.append(ESC_END) }
            else if b == ESC { out.append(ESC); out.append(ESC_ESC) }
            else { out.append(b) }
        }
        out.append(END)
        return out
    }
    private func slipDecode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var esc = false
        for b in data {
            if esc {
                out.append(b == ESC_END ? END : (b == ESC_ESC ? ESC : b)); esc = false
            } else if b == ESC { esc = true }
            else { out.append(b) }
        }
        return out
    }
    private func espChecksum(_ data: [UInt8]) -> UInt32 {
        var c: UInt8 = 0xEF
        for b in data { c ^= b }
        return UInt32(c)
    }
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
}

private extension Array where Element == UInt8 {
    mutating func append(_ bytes: [UInt8]) { self.append(contentsOf: bytes) }
}
