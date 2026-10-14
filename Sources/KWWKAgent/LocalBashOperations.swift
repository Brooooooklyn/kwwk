import Foundation
import KWWKAI

public struct LocalBashOperations: BashOperations {
    public let cwd: String?
    public let shellPath: String
    public let environment: [String: String]

    public init(
        cwd: String? = nil,
        shellPath: String = kwwkDefaultShellPath,
        environment: [String: String]
    ) {
        self.cwd = cwd
        self.shellPath = shellPath
        self.environment = environment
    }

    public func execute(
        command: String,
        timeout: Int?,
        cancellation: CancellationHandle?
    ) async throws -> BashExecutionResult {
        // Spawn via posix_spawn (SpawnedBashProcess) so the child gets its own
        // process group — cancel/timeout then signals the whole group and
        // reaches any grandchildren, not just the direct shell. Foundation's
        // Process leaves the child in our group, so `kill` would miss them.
        let effectiveCommand: String
        if let cwd {
            effectiveCommand = "cd \(bashShellQuote(cwd)) && \(command)"
        } else {
            effectiveCommand = command
        }

        // Isolate stdin from the parent (handled inside SpawnedBashProcess by
        // dup'ing /dev/null onto STDIN): the coding TUI runs its own stdin in
        // raw mode, so a child reading stdin would steal the user's keystrokes
        // and interactive wizards would hang. /dev/null forces EOF on reads.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let control = BashProcessControl(pid: 0)
        let start = Date()

        let spawned: SpawnedBashProcess
        do {
            spawned = try SpawnedBashProcess.start(
                shellPath: shellPath,
                command: effectiveCommand,
                stdoutFd: stdoutPipe.fileHandleForWriting.fileDescriptor,
                stderrFd: stderrPipe.fileHandleForWriting.fileDescriptor,
                environment: environment,
                extraEnv: [:]
            )
        } catch {
            throw CodingToolError.commandFailed(stderr: "\(error)", exitCode: -1)
        }
        // Close our copies of the write ends so the read ends see EOF once the
        // child exits and closes its dup'd copies.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        control.setPid(spawned.pid)
        cancellation?.onCancel { _ in control.terminate() }

        var timeoutTask: Task<Void, Never>?
        if let timeout, timeout > 0 {
            timeoutTask = Task {
                // A cancelled sleep means the process already exited — the
                // deadline never arrived, so it must not count as a timeout.
                guard (try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)) != nil else { return }
                control.timeoutAndTerminate()
            }
        }

        // Drain both pipes CONCURRENTLY with the wait. Reading only after
        // waitpid would deadlock once the child fills the ~64KB pipe buffer:
        // the child blocks in write(2) while we block in wait.
        let outBox = OutputBox()
        let errBox = OutputBox()
        let statusBox = ExitStatusBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            let outHandle = stdoutPipe.fileHandleForReading
            let errHandle = stderrPipe.fileHandleForReading
            group.enter()
            DispatchQueue.global().async {
                outBox.data = outHandle.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errBox.data = errHandle.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                statusBox.status = spawned.wait()
                group.leave()
            }
            group.notify(queue: .global()) { cont.resume() }
        }
        timeoutTask?.cancel()

        let stdout = String(decoding: outBox.data, as: UTF8.self)
        let stderr = String(decoding: errBox.data, as: UTF8.self)
        let duration = Int(Date().timeIntervalSince(start) * 1000)

        if cancellation?.isCancelled == true {
            throw CodingToolError.aborted
        }
        if control.didTimeOut {
            throw CodingToolError.commandFailed(stderr: "Command timed out after \(timeout ?? 0)ms\n" + stderr, exitCode: -1)
        }
        // The wait closure always sets `status` before the group completes.
        let code = statusBox.status!.code
        if code != 0 {
            throw CodingToolError.commandFailed(stderr: stderr.isEmpty ? stdout : stderr, exitCode: code)
        }
        return BashExecutionResult(stdout: stdout, stderr: stderr, exitCode: code, durationMs: duration, timedOut: false)
    }
}

/// `@unchecked Sendable` holders used to return values out of the concurrent
/// pipe-drain closures. Written on dispatch threads, read by the awaiting task
/// after `DispatchGroup.notify` establishes a happens-before edge.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

private final class ExitStatusBox: @unchecked Sendable {
    var status: SpawnedBashProcess.ExitStatus?
}
