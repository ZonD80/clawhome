import Foundation
import AppKit
import ClawVMCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ClawVMRunnerDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let (title, enabled): (String, Bool) = MainActor.assumeIsolated {
            let name = ClawVMManager.shared.displayNameForRunningVM ?? "VM"
            return ("Paste to \(name)'s home", ClawVMManager.shared.hasRunningVM)
        }
        let item = NSMenuItem(title: title, action: #selector(pasteIntoVM), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return menu
    }

    @objc private func pasteIntoVM() {
        Task { @MainActor in
            ClawVMManager.shared.pasteIntoGuest()
        }
    }
}

@main
struct ClawVMRunnerApp {
    private static func gracefulShutdownAndExit(vmId: String) {
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { sem.signal() }
            do {
                try await ClawVMManager.shared.stopVM(id: vmId, force: true)
            } catch {}
            fflush(stdout)
            NSApp.terminate(nil)
        }
        _ = sem.wait(timeout: .now() + 30)
    }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2, !args[1].isEmpty else {
            print("[ClawVMRunner] Usage: ClawVMRunner <vmId>")
            exit(1)
        }
        let vmId = args[1]
        print("[ClawVMRunner] Starting VM \(vmId)")
        fflush(stdout)

        let app = NSApplication.shared
        let appDelegate = ClawVMRunnerDelegate()
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)

        signal(SIGTERM, SIG_IGN)
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        sigtermSource.setEventHandler {
            print("[ClawVMRunner] SIGTERM received, stopping VM and exiting")
            fflush(stdout)
            sigtermSource.cancel()
            gracefulShutdownAndExit(vmId: vmId)
        }
        sigtermSource.resume()

        // Self-closure: when user confirms VM window close, poll isAboutToClose; when VM has stopped, quit cleanly
        let selfCloseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if ClawVMManager.shared.isAboutToClose, !ClawVMManager.shared.hasRunningVM {
                    print("[ClawVMRunner] VM stopped, exiting")
                    fflush(stdout)
                    NSApp.terminate(nil)
                }
            }
        }
        RunLoop.main.add(selfCloseTimer, forMode: .common)

        // Defer startVM until after run loop starts. Manager shows installer during HTTP handling
        // (run loop active); Runner was calling startVM before app.run(), so VZVirtualMachineView
        // never received display updates. Must create window while run loop is running.
        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    try await ClawVMManager.shared.startVM(id: vmId)
                    print("[ClawVMRunner] VM started, entering run loop")
                    fflush(stdout)
                } catch {
                    print("[ClawVMRunner] Failed to start VM: \(error)")
                    fflush(stdout)
                    exit(1)
                }
            }
        }

        app.run()
    }
}
