import AppKit
import CQueryCraftSSHPluginAPI
import Darwin
import Foundation
import Observation

struct SSHTerminalHandle: Sendable {
    let run: @Sendable () async -> SSHResult
    let cancel: @Sendable () -> Void
    let resize: @Sendable (Int, Int) -> Void
    let ready: @Sendable () -> Bool
}

extension SSHConnectionService {
    func terminalRequest(id: UUID) async throws -> SSHRequest {
        let profiles = try SSHConnectionStore(directory: directory).load()
        guard let profile = profiles.first(where: { $0.id == id }) else { throw MCPFailure("Saved SSH account was removed.", code: .connectionNotFound) }
        let jumps = try SSHConnectionStore.route(to: profile, in: profiles)
        let request = try await SSHRouteRequest.make(profile: profile, jumps: jumps, credentials: terminalCredentials,
            timeoutMilliseconds: 30_000, maximumOutputBytes: 1)
        let current = try SSHConnectionStore(directory: directory).load()
        guard current.first(where: { $0.id == id }) == profile,
              try SSHConnectionStore.route(to: profile, in: current) == jumps else {
            throw MCPFailure("SSH account changed while preparing the connection. Reconnect.", code: .sessionBusy)
        }
        return request
    }
}

/// Each tab owns its renderer and one PTY. Raw output never passes through SwiftUI state.
@MainActor @Observable
final class SSHTerminalSession: Identifiable {
    enum State: Equatable { case connecting, connected, disconnecting, closed, failed }
    let id = UUID()
    let profile: SSHConnection
    var state: State = .connecting
    var message = ""
    var title = ""
    var columns = 100
    var rows = 30
    var endpoints: [SSHConnection] = []
    private(set) var surface: SSHTerminalSurface?
    @ObservationIgnored private var operation: SSHTerminalHandle?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var socket: Int32 = -1
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var pendingScriptSource: String?
    @ObservationIgnored private var outputBuffer = [UInt8](repeating: 0, count: 4096)
    var isActive: Bool { state == .connecting || state == .connected || state == .disconnecting }
    var status: String {
        switch state {
        case .connecting: AppCopy.current.text("正在连接", "Connecting")
        case .connected: AppCopy.current.text("已连接", "Connected")
        case .disconnecting: AppCopy.current.text("正在断开", "Disconnecting")
        case .closed: AppCopy.current.text("已断开", "Disconnected")
        case .failed: AppCopy.current.text("连接失败", "Connection failed")
        }
    }
    init(profile: SSHConnection) {
        self.profile = profile
    }
    func start(service: SSHConnectionService) {
        guard worker == nil else { return }
        worker = Task { [self] in
            do {
                let bundleURL = SSHPlugin.bundleURL(in: service.directory)
                let surface = try SSHTerminalSurface(bundleURL: bundleURL)
                surface.session = self; self.surface = surface
                columns = surface.columns; rows = surface.rows
                let request = try await service.terminalRequest(id: profile.id)
                try Task.checkCancellation()
                guard request.connection == profile else {
                    throw MCPFailure(AppCopy.current.text("账号已修改，请重新选择服务器连接。", "The account changed. Select the server again."), code: .sessionBusy)
                }
                guard state == .connecting else { throw CancellationError() }
                endpoints = request.jumps.map(\.connection) + [request.connection]
                let plugin = try SSHPlugin(bundleURL: bundleURL)
                var pair: [Int32] = [-1, -1]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MCPFailure("Cannot allocate terminal stream.") }
                let peer = pair[1]; defer { Darwin.close(peer) }
                socket = pair[0]
                var yes: Int32 = 1
                guard fcntl(socket, F_SETFL, O_NONBLOCK) == 0,
                      fcntl(socket, F_SETFD, FD_CLOEXEC) == 0,
                      setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                    throw MCPFailure("Cannot configure terminal stream.")
                }
                let handle = try plugin.makeTerminal(request, socket: peer, columns: columns, rows: rows)
                operation = handle
                pump = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        _ = self.drain()
                        if self.state == .connecting && handle.ready() { self.state = .connected }
                        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    }
                }
                let result = await withTaskCancellationHandler { await handle.run() } onCancel: { handle.cancel() }
                pump?.cancel(); pump = nil
                // Drain all bytes already buffered before closing, including a final shell prompt/error.
                while drain() { await Task.yield() }
                if state == .disconnecting || result.status == QC_SSH_CANCELLED { state = .closed }
                else { try result.validate(); state = .closed; message = AppCopy.current.text("远程 Shell 已结束。", "The remote shell ended.") }
            } catch is CancellationError { state = .closed }
            catch { state = .failed; message = error.localizedDescription }
            operation = nil; pendingInput.removeAll()
            if socket >= 0 { Darwin.close(socket); socket = -1 }
            worker = nil
        }
    }
    func disconnect() {
        guard isActive else { return }
        state = .disconnecting; pendingInput.removeAll(); pendingScriptSource = nil
        worker?.cancel(); operation?.cancel()
    }
    func send(_ data: Data) {
        guard state == .connected else { return }
        guard pendingInput.count + data.count <= 1_048_576 else {
            message = AppCopy.current.text("输入超过缓冲上限，请等待发送完成。", "Input buffer is full. Wait for pending input to finish."); return
        }
        pendingInput.append(data)
        if data.contains(13) || data.contains(10) || data.contains(3) { pendingScriptSource = nil }
        flushInput()
    }
    func insertScript(_ source: String, execute: Bool) throws {
        guard state == .connected, socket >= 0 else { throw MCPFailure(AppCopy.current.text("请先连接终端。", "Connect a terminal first.")) }
        let bytes: Data
        if let pendingScriptSource {
            guard pendingScriptSource == source else {
                throw MCPFailure(AppCopy.current.text("控制台已有待执行脚本，请先回车执行或按 Ctrl+C 取消。", "A script is already pending. Press Return to run it or Ctrl+C to cancel."))
            }
            // Run on an already inserted snippet accepts that input exactly once.
            bytes = execute ? Data([13]) : Data()
        } else {
            let command = try SSHScriptTerminalInput.command(source)
            let flags = surface?.inputFlags
            guard flags.map({ $0 & 2 == 0 }) ?? true else {
                throw MCPFailure(AppCopy.current.text("请先退出全屏程序，返回 Shell 提示符。", "Return to the shell prompt before inserting a script."))
            }
            let input: Data
            if flags.map({ $0 & 1 != 0 }) == true {
                let hasControls = source.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0.value != 10 && $0.value != 9 }
                let body = hasControls ? command : source.trimmingCharacters(in: .newlines)
                input = Data("\u{1b}[200~".utf8) + Data(body.utf8) + Data("\u{1b}[201~".utf8)
            } else {
                guard command.utf8.count <= 200, !command.contains("\n") else {
                    throw MCPFailure(AppCopy.current.text("当前终端未开启多行粘贴支持。请返回 Shell 提示符或更新 SSH 插件后重试。", "The terminal has not enabled multiline paste. Return to the shell prompt or update the SSH plugin."), code: .unsupported)
                }
                input = Data(command.utf8)
            }
            // Replace pending input at the shell prompt, outside the paste frame.
            bytes = Data([5, 21]) + input + (execute ? Data([13]) : Data())
        }
        guard pendingInput.count + bytes.count <= 1_048_576 else {
            throw MCPFailure(AppCopy.current.text("终端输入缓冲已满，请稍后再试。", "The terminal input buffer is full. Try again shortly."), code: .capacity)
        }
        if !bytes.isEmpty { send(bytes) }
        pendingScriptSource = execute ? nil : source
        surface?.view.window?.makeFirstResponder(surface?.view)
    }
    func resize(columns: Int, rows: Int) {
        guard (2...1000).contains(columns), (2...1000).contains(rows),
              self.columns != columns || self.rows != rows else { return }
        self.columns = columns; self.rows = rows; operation?.resize(columns, rows)
    }
    private func flushInput() {
        guard socket >= 0, !pendingInput.isEmpty else { return }
        let n = pendingInput.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
        if n > 0 { pendingInput.removeFirst(n) }
        else if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { disconnect() }
    }
    private func drain() -> Bool {
        guard socket >= 0 else { return false }
        flushInput()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(4))
        // Keep input, scrolling and AppKit drawing responsive even under continuous output.
        // Kernel buffers provide lossless backpressure; no output is discarded.
        for _ in 0..<16 {
            let n = recv(socket, &outputBuffer, outputBuffer.count, 0)
            if n > 0 { surface?.feed(outputBuffer[0..<n]) }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
            if ContinuousClock.now >= deadline { return true }
        }
        return true
    }
}
