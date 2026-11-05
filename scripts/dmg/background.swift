// Tekent de achtergrond van het DMG-venster (640 × 400 punten, 1x en 2x).
//   swift scripts/dmg/background.swift scripts/dmg && cd scripts/dmg && \
//     tiffutil -cathidpicheck background.png background@2x.png -out background.tiff && rm background*.png
// background.tiff staat in de repo; release.sh gebruikt die via settings.py.
import AppKit

let size = CGSize(width: 640, height: 400)
// Posities (vanaf linksboven, zoals in dmgbuild): app links, Applications rechts.
// Houd deze gelijk aan icon_locations in settings.py.
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 165

let cream = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1)
let sand = NSColor(srgbRed: 0.94, green: 0.90, blue: 0.84, alpha: 1)
let red = NSColor(srgbRed: 0.85, green: 0.27, blue: 0.20, alpha: 1)
let ink = NSColor(srgbRed: 0.30, green: 0.26, blue: 0.23, alpha: 1)

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                               pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let flipY = { (y: CGFloat) in size.height - y }

    // Zachte verloop van boven naar onder.
    NSGradient(starting: cream, ending: sand)!.draw(in: CGRect(origin: .zero, size: size), angle: -90)

    // Rechte pijl tussen de twee iconen, met een open punthaak.
    let y = flipY(iconY)
    let from = CGPoint(x: appX + 88, y: y), to = CGPoint(x: appsX - 88, y: y)
    let arrow = NSBezierPath()
    arrow.move(to: from)
    arrow.line(to: to)
    arrow.move(to: CGPoint(x: to.x - 14, y: y + 14))
    arrow.line(to: to)
    arrow.line(to: CGPoint(x: to.x - 14, y: y - 14))
    arrow.lineWidth = 4
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    red.setStroke()
    arrow.stroke()

    // Uitleg onderin.
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag DJ Agenda to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: ink,
        .paragraphStyle: style,
    ])
    text.draw(in: CGRect(x: 0, y: flipY(318), width: size.width, height: 22))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    try! render(scale: scale).representation(using: .png, properties: [:])!
        .write(to: dir.appendingPathComponent(name))
}
