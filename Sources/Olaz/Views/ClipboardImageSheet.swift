import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot the clipboard at paste time; later copies cannot change the pending image.
struct ClipboardImages: Identifiable {
    let id = UUID()
    let conversationId: String
    let conversationName: String
    let images: [NSImage]

    @MainActor static func read(from board: NSPasteboard) -> [NSImage] {
        // Finder copies include file URLs. Read image files as images, never as text paths.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = urls.filter { url in
                guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
            if !files.isEmpty {
                let loaded = files.compactMap { NSImage(contentsOf: $0) }
                if !loaded.isEmpty { return loaded }
            }
        }
        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], !images.isEmpty {
            return images
        }
        if NSImage.canInit(with: board), let image = NSImage(pasteboard: board) {
            return [image]
        }
        return []
    }

    /// A private directory per send keeps repeated pastes from overwriting an in-flight upload.
    @MainActor func writeFiles() throws -> (directory: URL, files: [URL]) {
        ScreenCapture.prune()
        let directory = ScreenCapture.directory
            .appendingPathComponent("Olaz-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let files = try images.enumerated().map { index, image in
                guard let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let url = directory.appendingPathComponent("clipboard-\(index + 1).png")
                try data.write(to: url, options: .atomic)
                return url
            }
            return (directory, files)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// Pasting does not send anything until the user confirms, and leaves the text draft intact.
struct ClipboardImageSheet: View {
    let selection: ClipboardImages
    @Environment(ZaloEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Gửi ảnh tới \(selection.conversationName)") { if !busy { dismiss() } }
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(selection.images.indices, id: \.self) { index in
                        Image(nsImage: selection.images[index])
                            .resizable().scaledToFit()
                            .frame(width: 320, height: 260)
                            .accessibilityLabel("Ảnh \(index + 1)")
                    }
                }.padding(16)
            }
            Divider()
            SheetFooter(message: message, action: "Gửi", busy: busy, disabled: selection.images.isEmpty,
                        cancel: { if !busy { dismiss() } }) {
                Task { await send() }
            }
        }
        .frame(width: 420)
        .interactiveDismissDisabled(busy)
    }

    @MainActor private func send() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let pick = try selection.writeFiles()
            let outcome = await engine.sendMedia(pick.files, to: selection.conversationId)
            // The adapter returns after photo processing; upload can continue in the page.
            // Keep files under the same six-hour retention policy as captured screenshots.
            switch outcome {
            case .done: dismiss()
            case .cancelled: break
            case .failed(let text): message = text
            case .pending:
                engine.report(outcome, in: selection.conversationId)
                dismiss()
            }
        } catch {
            message = "Không đọc được ảnh từ clipboard. Hãy sao chép ảnh và thử lại."
        }
    }
}
