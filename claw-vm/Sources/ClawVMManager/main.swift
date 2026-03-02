import Foundation
import AppKit
import Swifter
import ClawVMCore

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ClawVMManagerApp {
    static let clawhomesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("clawhome")
    static let vmPortFile = clawhomesDir.appendingPathComponent("vm.port")

    /// vmId -> Runner process. Manager never runs VMs itself.
    static var runningRunners: [String: Foundation.Process] = [:]
    static let runnersLock = NSLock()

    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let server = HttpServer()

        func jsonResponse(_ data: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
        }

        func syncHandle(_ method: String, _ path: String, _ body: Data?) -> HttpResponse {
            let sem = DispatchSemaphore(value: 0)
            var result: (Int, Data, String)?
            Task { @MainActor in
                result = await handleRequest(method: method, path: path, body: body)
                sem.signal()
            }
            let waitResult = sem.wait(timeout: .now() + .seconds(120))
            guard waitResult == .success, let (status, data, contentType) = result else {
                let errData = (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": "Request timed out"])) ?? Data()
                return .raw(500, "Internal Server Error", ["Content-Type": "application/json"], { try $0.write(errData) })
            }
            let headers: [String: String] = ["Content-Type": contentType, "Content-Length": "\(data.count)"]
            let phrase = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Internal Server Error"
            return .raw(status, phrase, headers, { try $0.write(data) })
        }

        server.GET["/vms"] = { _ in syncHandle("GET", "/vms", nil) }
        server.POST["/create"] = { req in syncHandle("POST", "/create", req.body.isEmpty ? nil : Data(req.body)) }
        server.GET["/install-progress/:id"] = { req in syncHandle("GET", "/install-progress/\(req.params[":id"] ?? "")", nil) }
        server.POST["/start/:id"] = { req in syncHandle("POST", "/start/\(req.params[":id"] ?? "")", req.body.isEmpty ? nil : Data(req.body)) }
        server.POST["/stop/:id"] = { req in syncHandle("POST", "/stop/\(req.params[":id"] ?? "")", req.body.isEmpty ? nil : Data(req.body)) }
        server.POST["/delete/:id"] = { req in syncHandle("POST", "/delete/\(req.params[":id"] ?? "")", nil) }
        server.POST["/console/:id"] = { req in syncHandle("POST", "/console/\(req.params[":id"] ?? "")", nil) }

        do {
            try server.start(0, forceIPv4: true)
            let actualPort = try server.port()
            try FileManager.default.createDirectory(at: clawhomesDir, withIntermediateDirectories: true)
            try String(actualPort).write(to: vmPortFile, atomically: true, encoding: .utf8)
            print("[ClawVMManager] listening on port \(actualPort)")
            fflush(stdout)
        } catch {
            print("[ClawVMManager] Failed to start server: \(error)")
            exit(1)
        }

        app.run()
    }
}

@MainActor
func handleRequest(method: String, path: String, body: Data?) async -> (Int, Data, String) {
    let manager = ClawVMManager.shared

    func jsonResponse(_ data: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: data)) ?? Data()
    }

    switch (method, path) {
    case ("GET", "/vms"):
        ClawVMManagerApp.runnersLock.lock()
        let runningIds = Set(ClawVMManagerApp.runningRunners.filter { proc in
            proc.value.isRunning
        }.map { $0.key })
        ClawVMManagerApp.runnersLock.unlock()
        let vms = manager.listVMs(runningIds: runningIds)
        return (200, jsonResponse(["ok": true, "vms": vms]), "application/json")

    case ("POST", "/create"):
        var name: String?
        var ramMb: Int?
        var diskGb: Int?
        var ipswPath: String?
        if let body = body,
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        {
            name = obj["name"] as? String
            if let n = obj["ram_mb"] as? NSNumber { ramMb = n.intValue }
            if let n = obj["disk_gb"] as? NSNumber { diskGb = n.intValue }
            if let p = obj["ipsw_path"] as? String, !p.isEmpty { ipswPath = p }
        }
        guard let vmName = name?.trimmingCharacters(in: .whitespaces), !vmName.isEmpty else {
            return (400, jsonResponse(["ok": false, "error": "Missing or empty name"]), "application/json")
        }
        do {
            let vm = try manager.createVM(name: vmName, ramMb: ramMb, diskGb: diskGb, ipswPath: ipswPath)
            return (200, jsonResponse(["ok": true, "vm": vm]), "application/json")
        } catch {
            return (500, jsonResponse(["ok": false, "error": error.localizedDescription]), "application/json")
        }

    case ("GET", _) where path.hasPrefix("/install-progress/"):
        let id = String(path.dropFirst("/install-progress/".count))
        if let prog = manager.installProgress(id: id) {
            var resp: [String: Any] = ["ok": prog.error == nil, "fractionCompleted": prog.fractionCompleted, "phase": prog.phase]
            if let err = prog.error { resp["error"] = err }
            return (200, jsonResponse(resp), "application/json")
        }
        return (404, jsonResponse(["ok": false, "error": "Not installing"]), "application/json")

    case ("POST", _) where path.hasPrefix("/start/"):
        let id = String(path.dropFirst("/start/".count))
        guard !id.isEmpty else {
            return (400, jsonResponse(["ok": false, "error": "Missing vm id"]), "application/json")
        }
        return await startRunner(vmId: id, jsonResponse: jsonResponse)

    case ("POST", _) where path.hasPrefix("/stop/"):
        let id = String(path.dropFirst("/stop/".count))
        guard !id.isEmpty else {
            return (400, jsonResponse(["ok": false, "error": "Missing vm id"]), "application/json")
        }
        var force = false
        if let body = body,
            let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let f = (obj["force"] as? NSNumber)?.boolValue
        {
            force = f
        }
        return await stopRunner(vmId: id, force: force, jsonResponse: jsonResponse)

    case ("POST", _) where path.hasPrefix("/delete/"):
        let id = String(path.dropFirst("/delete/".count))
        guard !id.isEmpty else {
            return (400, jsonResponse(["ok": false, "error": "Missing vm id"]), "application/json")
        }
        await stopRunnerAndWait(vmId: id)
        do {
            try await manager.deleteVM(id: id)
            return (200, jsonResponse(["ok": true]), "application/json")
        } catch {
            return (500, jsonResponse(["ok": false, "error": error.localizedDescription]), "application/json")
        }

    case ("POST", _) where path.hasPrefix("/console/"):
        let id = String(path.dropFirst("/console/".count))
        return await showConsole(vmId: id, jsonResponse: jsonResponse)

    default:
        return (404, jsonResponse(["ok": false, "error": "Not found"]), "application/json")
    }
}

private let maxRunningVMs = 2

@MainActor
func startRunner(vmId: String, jsonResponse: ([String: Any]) -> Data) async -> (Int, Data, String) {
    ClawVMManagerApp.runnersLock.lock()
    if ClawVMManagerApp.runningRunners[vmId]?.isRunning == true {
        ClawVMManagerApp.runnersLock.unlock()
        return (200, jsonResponse(["ok": true]), "application/json")
    }
    let runningCount = ClawVMManagerApp.runningRunners.filter { $0.value.isRunning }.count
    ClawVMManagerApp.runnersLock.unlock()

    if runningCount >= maxRunningVMs {
        return (
            400,
            jsonResponse([
                "ok": false,
                "error": "Due to Apple restrictions, the maximum number of active homes is 2.",
            ]),
            "application/json"
        )
    }

    let execPath = ProcessInfo.processInfo.arguments[0]
    let execDir = (execPath as NSString).deletingLastPathComponent
    let runnerPath = (execDir as NSString).appendingPathComponent("ClawVMRunner")

    guard FileManager.default.fileExists(atPath: runnerPath) else {
        return (500, jsonResponse(["ok": false, "error": "ClawVMRunner not found at \(runnerPath)"]), "application/json")
    }

    // Spawn via copy ClawVM-{vmId} — dock uses actual binary name, not symlink target
    let safeVmId = vmId
        .replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
    let copyName = safeVmId.isEmpty ? "ClawVMRunner" : "ClawVM-\(safeVmId)"
    let copyPath = (execDir as NSString).appendingPathComponent(copyName)
    let copyURL = URL(fileURLWithPath: copyPath)
    do {
        if FileManager.default.fileExists(atPath: copyPath) {
            try FileManager.default.removeItem(at: copyURL)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: runnerPath), to: copyURL)
    } catch {
        return (500, jsonResponse(["ok": false, "error": "Failed to create runner copy: \(error.localizedDescription)"]), "application/json")
    }
    let executablePath = copyPath

    let clawhomeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("clawhome")
    try? FileManager.default.createDirectory(at: clawhomeDir, withIntermediateDirectories: true)

    let proc = Foundation.Process()
    proc.executableURL = URL(fileURLWithPath: executablePath)
    proc.arguments = [vmId]
    proc.currentDirectoryURL = clawhomeDir
    proc.standardOutput = nil
    proc.standardError = nil
    proc.standardInput = nil

    do {
        try proc.run()
        proc.terminationHandler = { _ in
            ClawVMManagerApp.runnersLock.lock()
            ClawVMManagerApp.runningRunners.removeValue(forKey: vmId)
            ClawVMManagerApp.runnersLock.unlock()
            if !safeVmId.isEmpty {
                try? FileManager.default.removeItem(at: copyURL)
            }
        }
        ClawVMManagerApp.runnersLock.lock()
        ClawVMManagerApp.runningRunners[vmId] = proc
        ClawVMManagerApp.runnersLock.unlock()
        return (200, jsonResponse(["ok": true]), "application/json")
    } catch {
        return (500, jsonResponse(["ok": false, "error": error.localizedDescription]), "application/json")
    }
}

@MainActor
func stopRunner(vmId: String, force: Bool, jsonResponse: ([String: Any]) -> Data) async -> (Int, Data, String) {
    await stopRunnerAndWait(vmId: vmId)
    return (200, jsonResponse(["ok": true]), "application/json")
}

@MainActor
func stopRunnerAndWait(vmId: String) async {
    ClawVMManagerApp.runnersLock.lock()
    guard let proc = ClawVMManagerApp.runningRunners[vmId] else {
        ClawVMManagerApp.runnersLock.unlock()
        return
    }
    proc.terminationHandler = nil
    ClawVMManagerApp.runningRunners.removeValue(forKey: vmId)
    ClawVMManagerApp.runnersLock.unlock()

    proc.terminate()
    for _ in 0..<60 {
        guard proc.isRunning else { return }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

@MainActor
func showConsole(vmId: String, jsonResponse: ([String: Any]) -> Data) async -> (Int, Data, String) {
    ClawVMManagerApp.runnersLock.lock()
    guard let proc = ClawVMManagerApp.runningRunners[vmId], proc.isRunning else {
        ClawVMManagerApp.runnersLock.unlock()
        return (404, jsonResponse(["ok": false, "error": "VM not running"]), "application/json")
    }
    let pid = proc.processIdentifier
    ClawVMManagerApp.runnersLock.unlock()

    let app = NSRunningApplication(processIdentifier: pid)
    app?.activate(options: [.activateIgnoringOtherApps])
    return (200, jsonResponse(["ok": true]), "application/json")
}
