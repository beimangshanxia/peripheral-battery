import Foundation

public enum DeviceKind: String, Sendable {
    case controller, mouse, keyboard, keyboardAndMouse, trackpad, headphones, other

    public init(hidUsagePage: Int, usage: Int) {
        switch (hidUsagePage, usage) {
        case (0x01, 0x02): self = .mouse
        case (0x01, 0x04), (0x01, 0x05): self = .controller
        case (0x01, 0x06), (0x01, 0x07): self = .keyboard
        case (0x0D, 0x05): self = .trackpad
        default: self = .other
        }
    }

    public init(description: String) {
        let text = description.lowercased()
        let matches: [(DeviceKind, [String])] = [
            (.controller, ["controller", "gamepad", "joystick", "手柄", "joy-con", "dualsense", "dualshock"]),
            (.trackpad, ["trackpad", "touchpad", "触控板"]),
            (.headphones, ["headphone", "headset", "earbud", "airpods", "耳机"]),
            (.mouse, ["mouse", "鼠标"]),
            (.keyboard, ["keyboard", "keypad", "键盘"]),
        ]
        let kinds = matches.filter { _, words in words.contains { text.contains($0) } }.map(\.0)
        self = kinds.contains(.mouse) && kinds.contains(.keyboard) ? .keyboardAndMouse : kinds.first ?? .other
    }

    public func includingInterface(_ other: Self) -> Self {
        if self == .other { return other }
        if other == .other || self == other { return self }
        let kinds: Set<Self> = [self, other]
        if kinds.contains(.controller) { return .controller }
        if kinds.contains(.trackpad) { return .trackpad }
        if kinds.contains(.keyboardAndMouse) || kinds == [.keyboard, .mouse] { return .keyboardAndMouse }
        return self
    }
}
