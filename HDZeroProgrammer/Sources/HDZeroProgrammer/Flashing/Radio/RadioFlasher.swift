import Foundation

/// HDZero Radio update: programs the ELRS TX (ESP32), ELRS backpack (ESP32-C3),
/// and the STM32 MCU, mirroring program_radio.py + the RADIO_* states in
/// ch341.py. Firmware ships as a zip containing elrs_tx/, elrs_backpack/, and
/// hdzero_radio_stm32.bin.
///
/// ⚠️ Hardware-unverified — serial AT handshakes, esptool ROM flashing, and
/// XMODEM are all reimplemented from scratch and need a real radio to validate.
@MainActor
enum RadioFlasher {

    struct Fail: LocalizedError { let m: String; init(_ m: String){ self.m = m }; var errorDescription: String? { m } }

    static func flash(source: URL, controller c: DeviceController) async {
        c.resetForRun()
        c.phase = .preparing
        c.appendLog("== HDZero Radio update ==\n")

        // Extract the firmware zip into a working dir.
        let root: URL
        do { root = try extractRadioZip(source) }
        catch { c.fail("Could not extract radio firmware: \(error.localizedDescription)"); return }

        let log: @Sendable (String) -> Void = { line in Task { @MainActor in c.appendLog(line) } }
        let progress: @Sendable (OperationPhase, Double) -> Void = { p, f in
            Task { @MainActor in c.phase = p; c.progress = min(max(f, 0), 1) }
        }

        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                // 1. ELRS TX (ESP32)
                log("\n— ELRS TX (ESP32) —\n")
                try programELRS(stmCommand: "ATPGTX", subdir: "elrs_tx",
                                offsets: [("bootloader.bin", 0x1000), ("partitions.bin", 0x8000),
                                          ("boot_app0.bin", 0xe000), ("firmware.bin", 0x10000)],
                                root: root, log: log) { progress(.flashing, $0 * 0.33) }

                // 2. ELRS backpack (ESP32-C3)
                log("\n— ELRS backpack (ESP32-C3) —\n")
                try programELRS(stmCommand: "ATPGBP", subdir: "elrs_backpack",
                                offsets: [("bootloader.bin", 0x0000), ("partitions.bin", 0x8000),
                                          ("boot_app0.bin", 0xe000), ("firmware.bin", 0x10000)],
                                root: root, log: log) { progress(.flashing, 0.33 + $0 * 0.33) }

                // 3. STM32 via XMODEM
                log("\n— STM32 (XMODEM) —\n")
                try programSTM32(root: root, log: log) { progress(.flashing, 0.66 + $0 * 0.34) }
                return .success(())
            } catch { return .failure(error) }
        }.value

        switch result {
        case .success:        c.succeed("Radio updated — repower the radio now.")
        case .failure(let e): c.fail(e.localizedDescription)
        }
    }

    // MARK: ELRS (ESP32 / ESP32-C3) via esptool ROM loader

    private nonisolated static func programELRS(stmCommand: String, subdir: String,
                                    offsets: [(String, Int)], root: URL,
                                    log: @escaping (String) -> Void,
                                    onProgress: (Double) -> Void) throws {
        // Put the radio's ESP into bootloader via the STM32 AT command.
        guard let stm = SerialPort.find(keyword: "STMicroelectronics") else {
            throw Fail("STM32 serial port not found.")
        }
        let stmPort = SerialPort()
        try stmPort.open(stm.path, baud: 115200)
        try stmPort.write("\(stmCommand)\r\n")
        Thread.sleep(forTimeInterval: 0.3)
        stmPort.close()
        Thread.sleep(forTimeInterval: 1.0)

        guard let elrs = SerialPort.find(keyword: "CH340") else {
            throw Fail("ELRS (CH340) serial port not found after \(stmCommand).")
        }
        let port = SerialPort()
        try port.open(elrs.path, baud: 460800)
        defer { port.close() }

        let esp = Esptool(port, log: log)
        esp.enterBootloader()
        try esp.sync()
        let total = offsets.count
        for (i, (file, offset)) in offsets.enumerated() {
            let url = root.appendingPathComponent("\(subdir)/\(file)")
            guard let data = try? [UInt8](Data(contentsOf: url)) else {
                throw Fail("Missing \(subdir)/\(file)")
            }
            log("flashing \(file) @ 0x\(String(offset, radix: 16)) (\(data.count) bytes)\n")
            try esp.flashImage(data, at: offset) { f in
                onProgress((Double(i) + f) / Double(total))
            }
        }
        try esp.finish(reboot: true)
    }

    // MARK: STM32 via XMODEM

    private nonisolated static func programSTM32(root: URL, log: @escaping (String) -> Void,
                                     onProgress: (Double) -> Void) throws {
        // Enter bootloader: ATPROG ×3, then reopen and send "XXX".
        guard let stm = SerialPort.find(keyword: "STMicroelectronics") else {
            throw Fail("STM32 serial port not found.")
        }
        let p1 = SerialPort()
        try p1.open(stm.path, baud: 115200)
        for _ in 0..<3 { try p1.write("ATPROG\r\n") }
        Thread.sleep(forTimeInterval: 0.5)
        p1.close()
        Thread.sleep(forTimeInterval: 0.5)

        guard let stm2 = SerialPort.find(keyword: "STMicroelectronics") else {
            throw Fail("STM32 port disappeared after ATPROG.")
        }
        let port = SerialPort()
        try port.open(stm2.path, baud: 115200)
        defer { port.close() }
        Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<3 { try port.write("XXX") }
        Thread.sleep(forTimeInterval: 0.5)
        _ = port.drain(timeout: 0.2)

        let binURL = root.appendingPathComponent("hdzero_radio_stm32.bin")
        guard let data = try? [UInt8](Data(contentsOf: binURL)) else {
            throw Fail("Missing hdzero_radio_stm32.bin")
        }
        log("XMODEM sending \(data.count) bytes…\n")
        try XMODEM.send(data, over: port, onProgress: onProgress)
        for _ in 0..<3 { try port.write("ccc") }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: Zip extraction

    private nonisolated static func extractRadioZip(_ source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdzero_radio_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if source.pathExtension.lowercased() == "zip" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", source.path, "-d", dir.path]
            p.standardError = Pipe(); p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw Fail("unzip exit \(p.terminationStatus)") }
        }
        // The zip may extract into a subfolder; find the dir containing the STM32 bin.
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("hdzero_radio_stm32.bin").path) {
            return dir
        }
        if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in en where u.lastPathComponent == "hdzero_radio_stm32.bin" {
                return u.deletingLastPathComponent()
            }
        }
        return dir
    }
}
