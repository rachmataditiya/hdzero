import Foundation

/// VTX flashing via the bundled `flashrom` + CH341A — the proven macOS path:
///   flashrom -p ch341a_spi -c "W25Q80BV/W25Q80DV" -w padded_1MiB.bin
@MainActor
enum FlashromService {

    static let chip = "W25Q80BV/W25Q80DV"
    static let programmer = "ch341a_spi"

    /// Flash a firmware file/zip to the connected VTX.
    static func flash(source: URL, flashrom: String, controller c: DeviceController) async {
        c.resetForRun()
        c.phase = .preparing
        c.appendLog("== HDZero VTX flash ==\n")

        let padded: URL
        do {
            padded = try FirmwareImage.preparePaddedImage(from: source)
            c.appendLog("→ Prepared 1 MiB image: \(padded.lastPathComponent)\n")
        } catch {
            c.fail(error.localizedDescription); return
        }

        // Build the privileged flashrom command. -c is required on flashrom 1.7.
        let cmd = "\(AdminRunner.shellQuote(flashrom)) -p \(programmer) "
            + "-c \(AdminRunner.shellQuote(chip)) -w \(AdminRunner.shellQuote(padded.path))"
        c.appendLog("→ \(cmd)\n\n")
        c.phase = .connecting

        do {
            let result = try await AdminRunner.run(cmd) { line in
                c.appendLog(line)
                Self.updatePhase(from: line, controller: c)
            }
            if result.status == 0 {
                c.succeed("Firmware written & verified — repower the VTX now.")
            } else {
                c.fail(diagnose(result.output, status: result.status))
            }
        } catch {
            c.fail(error.localizedDescription)
        }
    }

    /// Read the current firmware off the VTX into a user-chosen file (backup).
    static func backup(to destination: URL, flashrom: String, controller c: DeviceController) async {
        c.resetForRun()
        c.phase = .connecting
        c.appendLog("== Backup current VTX firmware ==\n")
        let cmd = "\(AdminRunner.shellQuote(flashrom)) -p \(programmer) "
            + "-c \(AdminRunner.shellQuote(chip)) -r \(AdminRunner.shellQuote(destination.path))"
        c.appendLog("→ \(cmd)\n\n")
        do {
            let result = try await AdminRunner.run(cmd) { line in
                c.appendLog(line)
                Self.updatePhase(from: line, controller: c)
            }
            if result.status == 0 {
                c.succeed("Backup saved to \(destination.lastPathComponent)")
            } else {
                c.fail(diagnose(result.output, status: result.status))
            }
        } catch {
            c.fail(error.localizedDescription)
        }
    }

    // MARK: Output interpretation

    private static func updatePhase(from line: String, controller c: DeviceController) {
        let l = line.lowercased()
        if l.contains("erasing") || l.contains("erase/write") {
            c.phase = .erasing
        } else if l.contains("writing") {
            c.phase = .flashing
        } else if l.contains("verifying") {
            c.phase = .verifying
        } else if l.contains("reading") {
            c.phase = .flashing
        }
    }

    private static func diagnose(_ output: String, status: Int32) -> String {
        let o = output.lowercased()
        if o.contains("no eeprom/flash device found") || o.contains("could not find") {
            return "No flash chip detected. Check the CH341A clip is seated on the VTX and the VTX is powered."
        }
        if o.contains("no programmer") || o.contains("ch341a_spi") && o.contains("error") {
            return "CH341A programmer not found on USB. Replug it and try again."
        }
        if o.contains("verifying") && o.contains("failed") {
            return "Verification failed — the write did not match. Do NOT repower; try flashing again."
        }
        return "flashrom exited with status \(status). See log for details."
    }
}
