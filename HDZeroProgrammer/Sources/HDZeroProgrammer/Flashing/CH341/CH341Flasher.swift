import Foundation

/// Monitor + Event-VRX flashing over the native CH341 driver, mirroring the
/// multi-chip / GPIO bank-switch logic in ch341.py. USB calls are blocking, so
/// the work runs on a detached task and posts progress back to the main actor.
///
/// ⚠️ Hardware-unverified, and depends on the unverified `setOutput` (0xA1)
/// bank-switch. Validate with a real Monitor / Event-VRX before relying on it.
@MainActor
enum CH341Flasher {

    // MARK: Monitor (three chips: 5680 / FPGA / 8339)

    static func flashMonitor(source: URL, controller c: DeviceController) async {
        c.resetForRun()
        c.phase = .preparing
        c.appendLog("== HDZero Monitor flash ==\n")

        let fw: MonitorFW
        do {
            let binURL = try FirmwareImage.resolveBin(from: source)
            fw = try MonitorFW(contentsOf: binURL)
            c.appendLog("→ 5680=\(fw.b5680.count)  FPGA=\(fw.bFPGA.count)  8339=\(fw.b8339.count) bytes\n")
        } catch {
            c.fail("Firmware parse failed: \(error.localizedDescription)"); return
        }

        let total = max(1, fw.b5680.count + fw.bFPGA.count + fw.b8339.count)
        await runUSB(controller: c, connecting: "Connecting Monitor…") { spi, progress in
            try spi.setStream(mode: 0x80)
            try spi.flashSwitch1()
            let id = try spi.flashReadID()
            guard id == 0xEF4018 else {
                throw Fail("Monitor not detected (flash id 0x\(String(id, radix: 16))).")
            }
            var written = 0
            try spi.flashSwitch0(); try writeChip(spi, fw.b5680) { written += $0; progress(.flashing, Double(written)/Double(total)) }
            try spi.flashSwitch1(); try writeChip(spi, fw.bFPGA) { written += $0; progress(.flashing, Double(written)/Double(total)) }
            try spi.flashSwitch2(); try writeChip(spi, fw.b8339) { written += $0; progress(.flashing, Double(written)/Double(total)) }
            try spi.flashRelease()
        } onDone: {
            c.succeed("Monitor firmware written — repower the Monitor now.")
        }
    }

    /// Erase-as-you-go page writer (fw_write_to_flash): erase each 64 KiB block
    /// at its boundary, then program 256-byte pages.
    private static func writeChip(_ spi: CH341SPI, _ data: [UInt8], onProgress: (Int) -> Void) throws {
        let pages = (data.count + 255) / 256
        for page in 0..<pages {
            let base = page << 8
            if (base & 0xFFFF) == 0 {           // 64 KiB boundary → erase block
                try spi.flashWriteEnable()
                try spi.flashEraseBlock64(base)
                try spi.flashWaitBusy()
                try spi.flashWriteDisable()
            }
            let end = min(base + 256, data.count)
            try spi.flashWriteEnable()
            try spi.flashWritePage(base, data[base..<end])
            try spi.flashWriteDisable()
            try spi.flashWaitBusy()
            onProgress(end - base)
        }
    }

    // MARK: Event-VRX (two chips: 5680 + FPGA, via FLASH_SET_* selects)

    static func flashEventVRX(source: URL, controller c: DeviceController) async {
        c.resetForRun()
        c.phase = .preparing
        c.appendLog("== Event-VRX flash ==\n")

        let fw: EventVRXFW
        do {
            let binURL = try FirmwareImage.resolveBin(from: source)
            fw = try EventVRXFW(contentsOf: binURL)
            c.appendLog("→ 5680=\(fw.size5680)  FPGA=\(fw.bFPGA.count) bytes\n")
        } catch {
            c.fail("Firmware parse failed: \(error.localizedDescription)"); return
        }

        let total = max(1, fw.b5680.count + fw.bFPGA.count)
        await runUSB(controller: c, connecting: "Connecting Event-VRX…") { spi, progress in
            try spi.setStream(mode: 0x80)
            // Erase both chips, then write. The hardware needs a long settle
            // after the FPGA chip-erase (~65 s in the Python).
            progress(.erasing, 0)
            try spi.flashSet5680(); spi.delay(ms: 10); try chipErase(spi)
            spi.delay(ms: 1000)
            try spi.flashSetFPGA(); spi.delay(ms: 10); try chipErase(spi)
            spi.delay(ms: 65_000)

            var written = 0
            try spi.flashSet5680()
            try writeSPIPaged(spi, fw.b5680) { written += $0; progress(.flashing, Double(written)/Double(total)) }
            try spi.flashSetFPGA()
            try writeSPIPaged(spi, fw.bFPGA) { written += $0; progress(.flashing, Double(written)/Double(total)) }
        } onDone: {
            c.succeed("Event-VRX firmware written — repower now.")
        }
    }

    private static func chipErase(_ spi: CH341SPI) throws {
        // FlashChipErase: WREN, CHIP_ERASE(0xC7), WRDI on the 5680-select line.
        try spi.streamSPI4(chipSelect: 0x80, [0x06])
        try spi.streamSPI4(chipSelect: 0x80, [0xC7])
        try spi.streamSPI4(chipSelect: 0x80, [0x04])
    }

    /// write_SPI: PAGE_PROGRAM in 256-byte pages (no erase — chip pre-erased).
    private static func writeSPIPaged(_ spi: CH341SPI, _ data: [UInt8], onProgress: (Int) -> Void) throws {
        let pages = (data.count + 255) / 256
        for page in 0..<pages {
            let base = page << 8
            let end = min(base + 256, data.count)
            try spi.streamSPI4(chipSelect: 0x80, [0x06])  // WREN
            var p: [UInt8] = [0x02, UInt8((base >> 16) & 0xFF), UInt8((base >> 8) & 0xFF), UInt8(base & 0xFF)]
            p.append(contentsOf: data[base..<end])
            try spi.streamSPI4(chipSelect: 0x80, p)
            try spi.streamSPI4(chipSelect: 0x80, [0x04])  // WRDI
            spi.delay(ms: 2)
            onProgress(end - base)
        }
    }

    // MARK: USB session helper

    struct Fail: LocalizedError { let m: String; init(_ m: String){self.m=m}; var errorDescription: String?{m} }

    /// Open the CH341, run `body` on a background thread, post phase/progress to
    /// the main actor, then either call `onDone` or surface the error.
    private static func runUSB(
        controller c: DeviceController,
        connecting: String,
        body: @escaping (CH341SPI, @escaping (OperationPhase, Double) -> Void) throws -> Void,
        onDone: @escaping () -> Void
    ) async {
        await MainActor.run { c.phase = .connecting; c.appendLog(connecting + "\n") }
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            let dev = CH341Device()
            do {
                try dev.open()
                defer { dev.close() }
                let spi = CH341SPI(dev)
                let progress: (OperationPhase, Double) -> Void = { phase, frac in
                    Task { @MainActor in c.phase = phase; c.progress = min(max(frac, 0), 1) }
                }
                try body(spi, progress)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:        onDone()
        case .failure(let e): c.fail(e.localizedDescription)
        }
    }
}

// MARK: - Firmware parsers (mirror parse_monitor_fw / parse_event_vrx_fw)

/// Monitor firmware: [2 bytes skipped][u32 5680][u32 fpga][u32 8339][buffers…]
struct MonitorFW {
    let b5680: [UInt8]; let bFPGA: [UInt8]; let b8339: [UInt8]
    init(contentsOf url: URL) throws {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count >= 14 else { throw CH341Flasher.Fail("Monitor firmware too small.") }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24 }
        let s5680 = u32(2), sFPGA = u32(6), s8339 = u32(10)
        guard s5680 < 65536, sFPGA < 10_000_000, s8339 < 10_000_000 else {
            throw CH341Flasher.Fail("Monitor firmware header invalid.")
        }
        var off = 14
        func take(_ n: Int) -> [UInt8] { let s = Array(d[off..<min(off+n, d.count)]); off += n; return s }
        b5680 = take(s5680); bFPGA = take(sFPGA); b8339 = take(s8339)
    }
}

/// Event-VRX firmware: [8-byte ASCII int header][5680 data][fpga data].
/// size5680 = int(header) - 2560 ; fpga = fileSize - 8 - size5680.
struct EventVRXFW {
    let b5680: [UInt8]; let bFPGA: [UInt8]; let size5680: Int
    init(contentsOf url: URL) throws {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count > 8 else { throw CH341Flasher.Fail("Event-VRX firmware too small.") }
        let headerStr = String(decoding: d[0..<8], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let headInt = Int(headerStr.filter(\.isNumber)) else {
            throw CH341Flasher.Fail("Event-VRX firmware header invalid.")
        }
        let s5680 = headInt - 2560
        guard s5680 > 0, s5680 < 65536, d.count < 10_000_000 else {
            throw CH341Flasher.Fail("Event-VRX firmware size out of range.")
        }
        size5680 = s5680
        b5680 = Array(d[8..<min(8 + s5680, d.count)])
        bFPGA = Array(d[(8 + s5680)...])
    }
}
