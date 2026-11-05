import AppKit

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

        // LaunchServices starts Dvar.app with no arguments (older macOS adds -psn_*)
        // and launchd as the parent process. Anything else, including a bare `dvar`
        // from a shell or script, is the CLI.
        //
        // main() stays synchronous on purpose: an async entry point would run as a
        // job on the main queue, and the app's run loop could then never drain it.
        if arguments.isEmpty && getppid() == 1 {
            AppDelegate.run()
        }

        Task {
            exit(await CLI.run(Array(arguments)))
        }
        dispatchMain()
    }
}
