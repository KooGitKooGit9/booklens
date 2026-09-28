import AppKit
import BookLensCore

// Developer/diagnostic entry points that do not need screen recording permission:
//   BookLens --pipeline <image.png> <x> <y> [model]   run OCR + locate + definition on an image (pixel coords)
//   BookLens --render-popup <out-dir>                 render popup states to PNG for visual checks
let arguments = CommandLine.arguments

if arguments.count >= 5, arguments[1] == "--pipeline" {
    Task {
        let code = await DiagnosticTools.pipeline(imagePath: arguments[2], x: Double(arguments[3]) ?? 0, y: Double(arguments[4]) ?? 0,
                                                  model: arguments.count > 5 ? arguments[5] : AppSettings.shared.model)
        exit(code)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
    if arguments.count >= 3, arguments[1] == "--render-popup" {
        DiagnosticTools.renderPopups(to: URL(fileURLWithPath: arguments[2]))
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}
