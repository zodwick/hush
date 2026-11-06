// hushctl: query and drive a running Hush from the terminal.
//
// Hush must be running with debug control on:
//     open build/Hush.app --args -DebugControl YES
//
// It sends one command as a local distributed notification and prints the
// reply. It never talks to Bluetooth itself.

import Foundation

let usage = """
usage: hushctl <command>

  status                     current state (default)
  mode nc|ambient|off        noise control mode
  ambient 1-20               ambient level (switches to ambient)
  voice on|off               focus on voice
  eq                         list equalizer presets
  eq <name|hex id>           pick a preset
  bands b1 … b6              custom EQ, -10…10 (Clear Bass, 400, 1k, 2.5k, 6.3k, 16k)
  stc on|off                 Speak-to-Chat
  touch on|off               touch controls
  pause on|off               pause when taken off
  autooff never|5|30|60|180  auto power off when idle (minutes)
  send <hex>                 raw payload, e.g. `send 66 02`; reply shows in the log
  reconnect                  drop and reopen the data channel
  rest                       close the data channel as if idle (next command wakes it)
  poweroff                   turn the headphones off
  log [-f] [lines]           print (or follow) ~/Library/Logs/Hush.log
"""

// Split on spaces too, so `hushctl "mode nc"` (one quoted word, which zsh
// produces from an unquoted variable) works like `hushctl mode nc`.
let args = CommandLine.arguments.dropFirst().flatMap { $0.split(separator: " ").map(String.init) }
let logPath = NSString(string: "~/Library/Logs/Hush.log").expandingTildeInPath

if args.first == "help" || args.first == "-h" || args.first == "--help" {
    print(usage)
    exit(0)
}

if args.first == "log" {
    let follow = args.contains("-f")
    let lines = args.dropFirst().first { Int($0) != nil } ?? "40"
    let tail = Process()
    tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    tail.arguments = (follow ? ["-f"] : []) + ["-n", lines, logPath]
    try tail.run()
    tail.waitUntilExit()
    exit(tail.terminationStatus)
}

let center = DistributedNotificationCenter.default()
let id = UUID().uuidString
nonisolated(unsafe) var exitCode: Int32 = 1
nonisolated(unsafe) var answered = false

let observer = center.addObserver(
    forName: Notification.Name("com.zodwick.hush.debug.reply"), object: id, queue: .main
) { note in
    print(note.userInfo?["output"] as? String ?? "(empty reply)")
    exitCode = (note.userInfo?["ok"] as? Bool ?? false) ? 0 : 1
    answered = true
}

center.postNotificationName(
    Notification.Name("com.zodwick.hush.debug.command"), object: id,
    userInfo: ["args": args], deliverImmediately: true)

let deadline = Date().addingTimeInterval(5)
while !answered, Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
center.removeObserver(observer)

if !answered {
    FileHandle.standardError.write(Data("""
    No reply from Hush. Is it running with debug control on?
        open build/Hush.app --args -DebugControl YES

    """.utf8))
}
exit(exitCode)
