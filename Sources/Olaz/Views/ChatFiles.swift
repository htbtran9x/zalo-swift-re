import AppKit
import Foundation
import UniformTypeIdentifiers

/// Utilities for managing chat files (saving to ~/Downloads/Olaz, opening, revealing in Finder, Save As).
enum ChatFiles {
    /// Dedicated download folder: ~/Downloads/Olaz
    static var downloadsDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let dir = downloads.appendingPathComponent(AppBrand.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Prepares the file in ~/Downloads/Olaz with its original display name.
    static func localFile(for url: URL, displayName: String) async throws -> URL {
        let cached = try await MediaLoader.shared.localFile(for: url)
        let fm = FileManager.default
        let safeName = sanitizeFilename(displayName)
        let target = downloadsDirectory.appendingPathComponent(safeName)

        if fm.fileExists(atPath: target.path) {
            let cachedSize = (try? fm.attributesOfItem(atPath: cached.path)[.size] as? Int64) ?? 0
            let targetSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            if cachedSize == targetSize && cachedSize > 0 {
                return target
            }
        }

        try? fm.removeItem(at: target)
        do {
            try fm.copyItem(at: cached, to: target)
            MediaLoader.applyQuarantine(to: target, origin: url)
            return target
        } catch {
            return cached
        }
    }

    static func sanitizeFilename(_ name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if base.isEmpty { base = "Tệp" }
        return base
    }

    /// Shows the file in Finder (downloading first if needed).
    @MainActor
    @discardableResult
    static func showInFinder(url: URL, displayName: String) async -> URL? {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return file
        } catch {
            return nil
        }
    }

    /// Opens the file with the default app (or Finder if executable).
    @MainActor
    @discardableResult
    static func open(url: URL, displayName: String) async -> URL? {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            if FileCard.mayExecute(file, displayName: displayName) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                NSWorkspace.shared.open(file)
            }
            return file
        } catch {
            return nil
        }
    }

    /// Prompts the user with NSSavePanel to save the file to a location of their choice.
    @MainActor
    static func saveAs(url: URL, displayName: String, window: NSWindow? = nil) async {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            let panel = NSSavePanel()
            panel.title = "Lưu tệp về máy"
            panel.prompt = "Lưu"
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = sanitizeFilename(displayName)
            if let type = UTType(filenameExtension: (displayName as NSString).pathExtension) {
                panel.allowedContentTypes = [type]
            }
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                if let window = window ?? NSApp.keyWindow {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    continuation.resume(returning: panel.runModal())
                }
            }
            if response == .OK, let dest = panel.url {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: file, to: dest)
            }
        } catch {}
    }

    /// Copies the file to the system clipboard (as a file URL).
    @MainActor
    static func copyFile(url: URL, displayName: String) async {
        do {
            let file = try await localFile(for: url, displayName: displayName)
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([file as NSURL])
        } catch {}
    }
}
