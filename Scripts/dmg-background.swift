import AppKit
import CoreGraphics
import Foundation

// Рисует фон окна DMG: тёмный градиент, подсвеченные места под иконки и стрелка
// между ними. Запускается один раз, результат лежит в docs/dmg-background.png.
// Высота — ровно видимая часть окна: заголовок и полоса состояния сверху и снизу
// съедают около 52 точек, и фон под ними всё равно не виден.
let width = 640, height = 400
let scale = 2
let size = CGSize(width: width * scale, height: height * scale)

guard let context = CGContext(data: nil,
                              width: Int(size.width), height: Int(size.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("не создался контекст")
}
context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

// Фон: тёплый тёмный градиент, как у иконки приложения.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let background = CGGradient(colorsSpace: space,
                            colors: [CGColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1),
                                     CGColor(red: 0.16, green: 0.14, blue: 0.17, alpha: 1)] as CFArray,
                            locations: [0, 1])!
context.drawLinearGradient(background,
                           start: CGPoint(x: 0, y: CGFloat(height)),
                           end: CGPoint(x: CGFloat(width), y: 0),
                           options: [])

// Тёплое свечение слева — там, где стоит иконка приложения: намёк на луч проектора.
let glow = CGGradient(colorsSpace: space,
                      colors: [CGColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 0.16),
                               CGColor(red: 1.0, green: 0.86, blue: 0.62, alpha: 0)] as CFArray,
                      locations: [0, 1])!
context.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 170, y: height - 205), startRadius: 0,
                           endCenter: CGPoint(x: 170, y: height - 205), endRadius: 260,
                           options: [])

/// Мягкая площадка под иконку, чтобы было видно, куда её класть.
func plate(at point: CGPoint) {
    let rect = CGRect(x: point.x - 62, y: point.y - 62, width: 124, height: 124)
    context.setFillColor(CGColor(gray: 1, alpha: 0.05))
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.09))
    context.setLineWidth(1)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 26, cornerHeight: 26, transform: nil))
    context.strokePath()
}
let appSpot = CGPoint(x: 170, y: CGFloat(height) - 205)
let folderSpot = CGPoint(x: 470, y: CGFloat(height) - 205)
plate(at: appSpot)
plate(at: folderSpot)

// Стрелка между площадками.
context.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
context.setLineWidth(2)
context.setLineDash(phase: 0, lengths: [6, 6])
context.move(to: CGPoint(x: appSpot.x + 78, y: appSpot.y))
context.addLine(to: CGPoint(x: folderSpot.x - 92, y: folderSpot.y))
context.strokePath()
context.setLineDash(phase: 0, lengths: [])
context.setFillColor(CGColor(gray: 1, alpha: 0.35))
let tip = CGPoint(x: folderSpot.x - 78, y: folderSpot.y)
context.move(to: tip)
context.addLine(to: CGPoint(x: tip.x - 12, y: tip.y + 7))
context.addLine(to: CGPoint(x: tip.x - 12, y: tip.y - 7))
context.closePath()
context.fillPath()

/// Текст по центру заданной точки.
func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat, weight: NSFont.Weight, alpha: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        .foregroundColor: NSColor(white: 1, alpha: alpha),
    ]
    let line = NSAttributedString(string: text, attributes: attributes)
    let bounds = line.size()
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    line.draw(at: CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2))
    NSGraphicsContext.restoreGraphicsState()
}

draw("Lumière", at: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 62), size: 30, weight: .semibold, alpha: 0.92)
draw("Drag Lumière into your Applications folder",
     at: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) - 96), size: 13, weight: .regular, alpha: 0.5)

guard let image = context.makeImage() else { fatalError("не получилась картинка") }
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/dmg-background.png")
let rep = NSBitmapImageRep(cgImage: image)
rep.size = NSSize(width: width, height: height)   // 2x: логический размер вдвое меньше пиксельного
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("не сохранилось") }
try data.write(to: output)
print("готово: \(output.path) — \(Int(size.width))×\(Int(size.height)) пикселей")
