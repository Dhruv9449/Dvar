import Foundation

// LaunchServices starts the app with no arguments (older macOS adds -psn_*) and
// launchd as its parent. Anything else, including a bare run from a shell or a
// script, is the CLI.
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if args.isEmpty && getppid() == 1 {
    runApp()
}
exit(CLI.run(Array(args)))
