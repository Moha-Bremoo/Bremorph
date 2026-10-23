import Foundation
import AppKit

/// Command-line mode:  Bremorph.app/Contents/MacOS/Bremorph --run <action> <file> [file…]
/// Example:            Bremorph --run vidMKV ~/Movies/clip.mp4
/// List actions:       Bremorph --list
enum CLI {
    final class Box: @unchecked Sendable {
        var done = false
        var code: Int32 = 0
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { return }
        if args[1] == "--list" {
            for a in ActionID.allCases {
                print("\(a.rawValue)\t\(a.info.title)\t[\(a.info.kinds.map(\.rawValue).joined(separator: ","))]")
            }
            exit(0)
        }
        if args[1] == "--render-wheel" {
            // Bremorph --render-wheel <convert|tools|actions> <highlighted slice, -1 for none> <sample file> <out.png>
            // Draws the real wheel off-screen at 4x for the README and website. Add -AppleLanguages "(ar)" for Arabic.
            guard args.count >= 6, let hover = Int(args[3]) else {
                print("usage: Bremorph --render-wheel <convert|tools|actions> <slice> <file> <out.png>")
                exit(2)
            }
            MainActor.assumeIsolated { renderWheel(mode: args[2], hover: hover, file: args[4], out: args[5]) }
            exit(0)
        }
        guard args[1] == "--run" else { return }
        guard args.count >= 4, let action = ActionID(rawValue: args[2]) else {
            print("usage: Bremorph --run <action> <file> [file…]   (Bremorph --list shows actions)")
            exit(2)
        }
        let files = args[3...].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let box = Box()
        Task.detached {
            do {
                let r = try await Engine.run(action, inputs: files, options: ActionOptions()) { _ in }
                let outs = r.outputs.map(\.lastPathComponent).joined(separator: ", ")
                print("OK   \(action.rawValue) ← \(files.map(\.lastPathComponent).joined(separator: ", ")) → \(outs)\(r.message.map { " | " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "")")
            } catch {
                print("FAIL \(action.rawValue) ← \(files.map(\.lastPathComponent).joined(separator: ", ")): \(error.localizedDescription)")
                box.code = 1
            }
            box.done = true
        }
        while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        exit(box.code)
    }

    @MainActor
    static func renderWheel(mode: String, hover: Int, file: String, out: String) {
        let m: WheelMode = mode == "tools" ? .tools : (mode == "actions" ? .actions : .convert)
        let size: CGFloat = 420, scale: CGFloat = 4
        let view = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.items = WheelController.items(for: [URL(fileURLWithPath: (file as NSString).expandingTildeInPath)], mode: m)
        view.mode = m
        view.fileCount = 1
        view.dragMode = true
        view.hover = hover >= 0 && hover < view.items.count ? hover : nil
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * scale), pixelsHigh: Int(size * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        // On screen the wheel sits on a blurred backdrop; off-screen it gets a plain dark one behind it.
        let r = view.outerR + 1
        NSGraphicsContext.current?.compositingOperation = .destinationOver
        NSColor(srgbRed: 0.09, green: 0.10, blue: 0.11, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: size / 2 - r, y: size / 2 - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        } catch {
            print("FAIL \(error.localizedDescription)")
        }
    }
}
