import AppKit

enum PipeIcon {
    static func image(connected: Bool, active: Bool) -> NSImage {
        let icon = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let pipe = NSBezierPath()
            pipe.lineWidth = 2
            pipe.lineCapStyle = .round
            pipe.lineJoinStyle = .round
            pipe.move(to: NSPoint(x: 6, y: 5))
            pipe.line(to: NSPoint(x: 8, y: 5))
            pipe.line(to: NSPoint(x: 8, y: connected ? 13 : 7))
            if !connected { pipe.move(to: NSPoint(x: 8, y: 11)) }
            pipe.line(to: NSPoint(x: 8, y: 13))
            pipe.line(to: NSPoint(x: 16, y: 13))
            pipe.stroke()
            for endpoint in [NSPoint(x: 4, y: 5), NSPoint(x: 18, y: 13)] {
                let ring = NSBezierPath(ovalIn: NSRect(x: endpoint.x - 2, y: endpoint.y - 2, width: 4, height: 4))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            if active && !connected {
                NSBezierPath(ovalIn: NSRect(x: 7, y: 8, width: 2, height: 2)).fill()
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = connected ? "Connected" : (active ? "Connecting" : "Disconnected")
        return icon
    }
}
