import AppKit
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Syncs clipboard between host and guest via shared directory.
/// Host → Guest: writes to clipboard_from_host.txt when host pasteboard changes
/// Guest → Host: watches clipboard_from_guest.txt, reads and puts in host pasteboard
final class ClipboardSync {
    private let sharedDir: URL
    private let fromHostPath: URL
    private let fromGuestPath: URL
    private var hostPollTimer: Timer?
    private var fileObserver: DispatchSourceFileSystemObject?
    private var lastHostChangeCount: Int = -1
    private var lastGuestContent: String = ""

    init(sharedDirectory: URL) {
        self.sharedDir = sharedDirectory
        self.fromHostPath = sharedDirectory.appendingPathComponent("clipboard_from_host.txt")
        self.fromGuestPath = sharedDirectory.appendingPathComponent("clipboard_from_guest.txt")
    }

    func start() {
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fromHostPath.path, contents: nil)
        FileManager.default.createFile(atPath: fromGuestPath.path, contents: nil)

        // Host → Guest: poll pasteboard changeCount, write to file when changed
        lastHostChangeCount = NSPasteboard.general.changeCount
        hostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.hostPasteboardPoll()
        }
        hostPollTimer?.tolerance = 0.1
        RunLoop.main.add(hostPollTimer!, forMode: .common)

        // Guest → Host: watch file for changes, read and put in host pasteboard
        let fd = open(fromGuestPath.path, O_EVTONLY)
        if fd >= 0 {
            fileObserver = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: .write,
                queue: .main
            )
            fileObserver?.setEventHandler { [weak self] in
                self?.guestFileDidChange()
            }
            fileObserver?.setCancelHandler { close(fd) }
            fileObserver?.resume()
        }
    }

    func stop() {
        hostPollTimer?.invalidate()
        hostPollTimer = nil
        fileObserver?.cancel()
        fileObserver = nil
    }

    private func hostPasteboardPoll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastHostChangeCount else { return }
        lastHostChangeCount = count

        guard let str = NSPasteboard.general.string(forType: .string), !str.isEmpty else { return }
        try? str.write(to: fromHostPath, atomically: true, encoding: .utf8)
    }

    private func guestFileDidChange() {
        guard let content = try? String(contentsOf: fromGuestPath, encoding: .utf8),
              content != lastGuestContent
        else { return }
        lastGuestContent = content
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }
}
