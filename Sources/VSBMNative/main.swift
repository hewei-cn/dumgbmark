import AppKit

// Headless capture mode: renders one frame to a PNG and exits, without ever
// creating an NSApplication. Useful for regression artifacts and for CI, and it
// needs no display or screen-recording permission.
if CommandLine.arguments.contains("--render") {
    do {
        try HeadlessRender.run(arguments: CommandLine.arguments)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("vsbm: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// A plain SwiftPM executable, launched either directly or from the assembled
// .app bundle. `setActivationPolicy(.regular)` is what gives it a Dock icon, a
// menu bar and a focusable window without an Info.plist being strictly required.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
