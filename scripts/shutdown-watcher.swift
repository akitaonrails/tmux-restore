// tmux-restore's save at shutdown on macOS. macOS posts NSWorkspace.willPowerOffNotification when
// you log out, restart or shut down, before apps quit: this runs the save then. SIGUSR1 runs it
// too (the tests use that). install.sh builds it and starts it as a LaunchAgent.
//   tmux-restore-shutdown <script>
import AppKit

let script = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""

func save() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [script]
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data("tmux-restore: can't run \(script): \(error)\n".utf8))
    }
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
) { _ in save() }

signal(SIGUSR1, SIG_IGN)
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler { save() }
usr1.resume()

NSApplication.shared.setActivationPolicy(.prohibited) // no Dock icon
NSApplication.shared.run()
