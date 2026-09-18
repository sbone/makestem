import AppKit

enum DockProgress: Equatable {
    case inactive
    case indeterminate
    case determinate(Double)
}

extension AppModel {
    var dockProgress: DockProgress {
        if isScreenshotMode { return .inactive }
        if case .downloading(let status) = modelState {
            return status.dockProgress
        }
        if case .processing(_, let status) = state {
            return status.dockProgress
        }
        return .inactive
    }
}

private extension ProcessingStatus {
    var dockProgress: DockProgress {
        guard let percent else { return .indeterminate }
        return .determinate(Double(min(max(percent, 0), 100)) / 100)
    }
}

@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    private let container = NSView()
    private let icon = NSImageView()
    private let indicator = DockProgressBar()
    private var animationTimer: Timer?

    private init() {
        icon.image = NSApplication.shared.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown

        container.addSubview(icon)
        container.addSubview(indicator)
    }

    func update(_ progress: DockProgress) {
        animationTimer?.invalidate()
        animationTimer = nil

        guard progress != .inactive else {
            NSApplication.shared.dockTile.contentView = nil
            NSApplication.shared.dockTile.display()
            return
        }

        let size = NSApplication.shared.dockTile.size
        container.frame = NSRect(origin: .zero, size: size)
        icon.frame = container.bounds
        indicator.frame = NSRect(x: 10, y: 7, width: size.width - 20, height: 12)

        switch progress {
        case .inactive:
            break
        case .indeterminate:
            indicator.progress = nil
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in
                    self.indicator.advanceAnimation()
                    NSApplication.shared.dockTile.display()
                }
            }
        case .determinate(let value):
            indicator.progress = value
        }

        NSApplication.shared.dockTile.contentView = container
        NSApplication.shared.dockTile.display()
    }
}

private final class DockProgressBar: NSView {
    var progress: Double? {
        didSet { needsDisplay = true }
    }
    private var animationPhase = 0.0

    func advanceAnimation() {
        animationPhase = (animationPhase + 0.08).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 1, dy: 1)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()

        let fraction = progress.map { min(max($0, 0), 1) }
        let fill: NSRect
        if let fraction {
            fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        } else {
            let width = track.width * 0.32
            fill = NSRect(
                x: track.minX + (track.width - width) * animationPhase,
                y: track.minY,
                width: width,
                height: track.height
            )
        }

        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4)
        outline.lineWidth = 1.5
        outline.stroke()
    }
}
