import AppKit

Settings.registerDefaults()
AX.limitMessagingTimeout()

// A leading "--" argument runs a test command instead of the app (see DevCommands.usage).
let commandArguments = Array(CommandLine.arguments.dropFirst())
if commandArguments.first?.hasPrefix("--") == true {
    exit(DevCommands.run(commandArguments))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
