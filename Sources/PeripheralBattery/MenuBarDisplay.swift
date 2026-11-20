import AppKit
import BatteryCore

@MainActor
enum MenuBarDisplay {
    struct Reading {
        let device: DeviceBattery
        let percent: Int
        let isLow: Bool

        var description: String {
            "\(device.name) \(percent)%\(isLow ? "，低电量" : "")"
        }
    }

    static func readings(for devices: [DeviceBattery], threshold: Int) -> [Reading] {
        devices.compactMap { device in
            device.minimum.map { Reading(device: device, percent: $0, isLow: $0 <= threshold) }
        }
    }

    static func image(for readings: [Reading]) -> NSImage? {
        guard !readings.isEmpty else {
            let image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let spacing: CGFloat = 10
        let height: CGFloat = 19
        let segments = readings.map { reading in
            let icons = reading.device.kind.symbolNames.compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            }
            let label = NSAttributedString(
                string: "\(reading.percent)%\(reading.isLow ? "!" : "")",
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            let width = icons.reduce(CGFloat.zero) { $0 + ceil($1.size.width) + 3 } + ceil(label.size().width)
            return (icons: icons, label: label, width: width)
        }
        let width = segments.reduce(CGFloat.zero) { $0 + $1.width } + spacing * CGFloat(segments.count - 1)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for segment in segments {
                for icon in segment.icons {
                    let rect = NSRect(x: x, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
                    icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x += ceil(icon.size.width) + 3
                }
                segment.label.draw(at: NSPoint(x: x, y: (height - segment.label.size().height) / 2))
                x += ceil(segment.label.size().width) + spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

extension DeviceKind {
    fileprivate var symbolNames: [String] {
        switch self {
        case .controller: ["gamecontroller"]
        case .mouse: ["computermouse"]
        case .keyboard: ["keyboard"]
        case .keyboardAndMouse: ["keyboard", "computermouse"]
        case .trackpad: ["rectangle.dotted"]
        case .headphones: ["headphones"]
        case .other: ["bolt.circle"]
        }
    }

    var menuImage: NSImage? {
        NSImage(systemSymbolName: symbolNames[0], accessibilityDescription: nil)
    }
}
