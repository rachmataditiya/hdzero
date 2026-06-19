import SwiftUI

// MARK: - Reusable card panel

/// A titled card used to build the two-column layout on every device page.
struct Panel<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let s = systemImage {
                    Image(systemName: s).font(.caption).foregroundStyle(.tint)
                }
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Labelled field row (label above a compact control)

struct Field<Control: View>: View {
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
            control
        }
    }
}

// MARK: - Online/local firmware picker (non-VTX devices)

import UniformTypeIdentifiers

/// Firmware source picker for Monitor / Event-VRX / Radio: a version dropdown
/// (from the catalog) plus a local-file option. Updates the controller's source.
struct OnlineLocalPicker: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var c: DeviceController
    @State private var useLocal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $useLocal) {
                Text("Online").tag(false)
                Text("Local file").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: useLocal) { _ in c.source = .none }

            if useLocal {
                Field(label: "Firmware file") {
                    HStack(spacing: 8) {
                        Button("Choose…") { choose() }
                        Text(localLabel).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            } else {
                Field(label: "Version") {
                    Picker("", selection: $c.selectedVersion) {
                        Text("Select version…").tag(String?.none)
                        ForEach(app.catalog.versions(for: c.kind), id: \.version) { va in
                            Text(va.version).tag(String?.some(va.version))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: c.selectedVersion) { _ in updateSource() }
                }
                if app.catalog.state == .loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var localLabel: String {
        if case .local(let u) = c.source { return u.lastPathComponent }
        return "No file selected"
    }
    private func updateSource() {
        guard let v = c.selectedVersion,
              let va = app.catalog.versions(for: c.kind).first(where: { $0.version == v })
        else { c.source = .none; return }
        c.source = .online(version: v, url: va.url)
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data, .zip]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { c.source = .local(url) }
    }
}

/// Resolve a controller's selected source to a local file URL, downloading if
/// it's an online asset. Updates the controller phase/log during download.
@MainActor
func resolveSource(_ c: DeviceController) async -> URL? {
    switch c.source {
    case .local(let u): return u
    case .online(_, let url):
        c.phase = .downloading
        c.appendLog("Downloading \(url.lastPathComponent)…\n")
        do { return try await Downloader.download(url) }
        catch { c.fail("Download failed: \(error.localizedDescription)"); return nil }
    case .none: return nil
    }
}

// MARK: - Page scaffold: two equal columns

/// Standard device-page layout: a left configuration column and a right
/// status/action column, sized to fill the tab area compactly.
struct TwoColumnPage<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            left.frame(maxWidth: .infinity)
            right.frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
