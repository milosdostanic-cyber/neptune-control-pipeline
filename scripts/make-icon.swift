import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
guard let logo = NSImage(contentsOfFile: "Resources/NeptuneLogo.svg") else {
    fatalError("NeptuneLogo.svg could not be read")
}
func writePNG(_ image: NSImage, to url: URL) throws {
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}
let mark = NSImage(size: NSSize(width: 543.1, height: 633.3))
mark.lockFocus()
logo.draw(in: NSRect(x: 0, y: 0, width: 543.1, height: 633.3))
mark.unlockFocus()
try writePNG(mark, to: destination.deletingLastPathComponent().appendingPathComponent("NeptuneLogo.png"))

let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
NSColor(calibratedRed: 0.09, green: 0.12, blue: 0.16, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 205, yRadius: 205).fill()
logo.draw(in: NSRect(x: 272, y: 232, width: 480, height: 560))
icon.unlockFocus()
try writePNG(icon, to: destination)
