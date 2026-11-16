import AppKit

// A menu row drawn by hand: an icon, a label, and a right-hand column with
// grey detail and an optional status dot.
//
// A standard item cannot carry that column without the menu adding a wide
// empty margin after its title. A view sets its own width instead, so every
// row that carries the column is a view sized to the menu grid, and the right
// padding matches the left.
//
// A view in a menu draws its own highlight and handles its own click. Its menu
// item keeps the action too, so choosing the row with the keyboard still works.
final class MenuRowView: NSView {
    private let label: String
    private let symbol: String?
    private let detail: String
    var dot: NSColor? { didSet { if dot != oldValue { needsDisplay = true } } }

    init(label: String, symbol: String?, detail: String, dot: NSColor? = nil) {
        self.label = label
        self.symbol = symbol
        self.detail = detail
        self.dot = dot
        super.init(frame: NSRect(x: 0, y: 0, width: MenuGrid.menuWidth, height: MenuGrid.rowHeight))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel("\(label), \(detail)")
    }

    required init?(coder: NSCoder) { nil }

    private var highlighted: Bool { enclosingMenuItem?.isHighlighted ?? false }

    override func draw(_ dirtyRect: NSRect) {
        let lit = highlighted
        if lit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
        }
        let primary: NSColor = lit ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = lit ? .selectedMenuItemTextColor : .secondaryLabelColor

        var textStart = MenuGrid.textStart
        if let symbol {
            drawIcon(symbol, color: primary)
            textStart = MenuGrid.iconTextStart
        }
        drawText(label, font: MenuGrid.labelFont, color: primary, left: textStart)

        var right = MenuGrid.rightEdge
        if let dot {
            let diameter: CGFloat = 7
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: right - diameter, y: (bounds.height - diameter) / 2,
                                        width: diameter, height: diameter)).fill()
            right -= diameter + 6
        }
        drawText(detail, font: MenuGrid.detailFont, color: secondary, right: right)
    }

    private func drawIcon(_ symbol: String, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: MenuGrid.labelFont.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: MenuGrid.iconStart + (MenuGrid.iconWidth - size.width) / 2,
                              y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    private func drawText(_ string: String, font: NSFont, color: NSColor,
                          left: CGFloat? = nil, right: CGFloat? = nil) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        let x = left ?? ((right ?? 0) - size.width)
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}
