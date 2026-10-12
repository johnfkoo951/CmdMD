import SwiftUI

// MARK: - Key binding model

/// A user-remappable keyboard shortcut. Stored in settings and applied to menu
/// commands / views via `View.appShortcut(_:)`. Keys are encoded like Obsidian
/// ("ArrowLeft", "[", "p") so defaults can mirror the user's vault hotkeys.
struct KeyBinding: Codable, Equatable, Hashable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    /// No shortcut — the user removed it in Settings (⌫ while recording).
    /// Its nil `keyEquivalent` makes `appShortcut` a no-op.
    static let unbound = KeyBinding(key: "")

    var isUnbound: Bool { key.isEmpty }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "ArrowLeft":  return .leftArrow
        case "ArrowRight": return .rightArrow
        case "ArrowUp":    return .upArrow
        case "ArrowDown":  return .downArrow
        case "Space":      return .space
        case "Return", "Enter": return .return
        case "Tab":        return .tab
        case "Escape":     return .escape
        default:
            guard key.count == 1, let ch = key.first else { return nil }
            return KeyEquivalent(ch)
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// Human-readable combo, e.g. "⌃⌘←".
    var displayString: String {
        guard !isUnbound else { return "None" }
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += Self.keyLabel(key)
        return s
    }

    static func keyLabel(_ key: String) -> String {
        switch key {
        case "ArrowLeft":  return "←"
        case "ArrowRight": return "→"
        case "ArrowUp":    return "↑"
        case "ArrowDown":  return "↓"
        case "Space":      return "Space"
        case "Return", "Enter": return "↩"
        case "Tab":        return "⇥"
        case "Escape":     return "⎋"
        default:           return key.uppercased()
        }
    }
}

extension KeyBinding {
    /// Lenient decoding (in an extension, so the memberwise init stays): a
    /// missing modifier means "off" instead of failing all of settings.json,
    /// and a key no menu can show fails just this binding, which then falls
    /// back to the action's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        command = (try? c.decodeIfPresent(Bool.self, forKey: .command)) ?? false
        shift = (try? c.decodeIfPresent(Bool.self, forKey: .shift)) ?? false
        option = (try? c.decodeIfPresent(Bool.self, forKey: .option)) ?? false
        control = (try? c.decodeIfPresent(Bool.self, forKey: .control)) ?? false
        guard hasUsableKey else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: c, debugDescription: "Shortcut key can't be shown in a menu")
        }
    }

    /// Whether menus can show and match `key`: a named key, one printable
    /// character, or "" (unbound). The old recorder also stored the raw
    /// characters of Return, Delete and F-keys, which rendered blank.
    var hasUsableKey: Bool {
        guard !isUnbound else { return true }
        guard key.count == 1 else { return keyEquivalent != nil }
        return !key.unicodeScalars.contains(where: Self.isUnprintable)
    }

    /// Control characters (Return, Tab and Delete arrive as "\r", "\t" and
    /// "\u{7F}") and the private-use range AppKit gives function and
    /// navigation keys (F1 is "\u{F704}").
    static func isUnprintable(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0xF700...0xF8FF).contains(scalar.value)
    }

    /// Same key combination: equal modifiers on the same physical key, so a
    /// recorded "}" (⇧⌘]) matches a "]" menu shortcut with ⇧⌘.
    func isSameCombo(as other: KeyBinding) -> Bool {
        guard !isUnbound, !other.isUnbound,
              command == other.command, shift == other.shift,
              option == other.option, control == other.control else { return false }
        if let code = GlobalHotKey.carbonKeyCode(for: key),
           let otherCode = GlobalHotKey.carbonKeyCode(for: other.key) {
            return code == otherCode
        }
        return key.lowercased() == other.key.lowercased()
    }

    /// What the Settings recorder does with one key press.
    enum Recorded: Equatable {
        case cancel
        case clear
        case binding(KeyBinding)
        /// Not usable: no ⌘ or ⌃, or a key menus can't show (F-keys).
        case rejected
    }

    /// Maps a key press in the recorder: ⎋ cancels, ⌫/⌦ remove the shortcut,
    /// Return and Tab are stored by name. A shortcut needs ⌘ or ⌃ — like the
    /// global hot key — since bare, ⇧- and ⌥-only keys type text.
    static func recorded(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> Recorded {
        let key: String
        switch keyCode {
        case 53:      return .cancel
        case 51, 117: return .clear
        case 123:     key = "ArrowLeft"
        case 124:     key = "ArrowRight"
        case 126:     key = "ArrowUp"
        case 125:     key = "ArrowDown"
        case 49:      key = "Space"
        case 36, 76:  key = "Return"
        case 48:      key = "Tab"
        default:
            guard let chars = characters?.lowercased(), chars.count == 1,
                  !chars.unicodeScalars.contains(where: isUnprintable) else { return .rejected }
            key = chars
        }

        let binding = KeyBinding(
            key: key,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
        return binding.command || binding.control ? .binding(binding) : .rejected
    }

    /// ⌘+ as people type it: ⇧⌘= (the key's printed symbol), keypad + or an
    /// unshifted + key (German, Nordic layouts) — all "+" here. Zoom In's
    /// menu item matches "=" literally and misses every one of them.
    static func isZoomInAlternate(characters: String?, command: Bool, option: Bool, control: Bool) -> Bool {
        command && !option && !control && characters == "+"
    }
}

// MARK: - Remappable actions

/// Every shortcut-bound action. Defaults reference 구요한's Obsidian main-vault
/// hotkeys where an equivalent exists (Omnisearch ⇧⌘O, sidebars ⌃⌘←/→).
enum AppShortcut: String, CaseIterable, Identifiable {
    case commandPalette
    case omnisearch
    case toggleSidebar
    case toggleInspector
    case copyFilePath
    case sendToVault
    case autoRoute
    case openInObsidian
    case quickCapture
    case sourceMode
    case splitMode
    case previewMode
    case newDraft
    case save
    case saveAs
    case findInDocument
    case reloadFromDisk
    case openFolder
    case zoomIn
    case zoomOut
    case resetZoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: return "Command Palette"
        case .omnisearch:     return "Omnisearch"
        case .toggleSidebar:  return "Toggle Left Sidebar"
        case .toggleInspector: return "Toggle Right Sidebar (Inspector)"
        case .copyFilePath:   return "Copy File Path"
        case .sendToVault:    return "Send to Vault…"
        case .autoRoute:      return "Auto-Route Send"
        case .openInObsidian: return "Open in Obsidian"
        case .quickCapture:   return "Quick Capture"
        case .sourceMode:     return "Source View"
        case .splitMode:      return "Split View"
        case .previewMode:    return "Preview View"
        case .newDraft:       return "New Draft"
        case .save:           return "Save"
        case .saveAs:         return "Save As…"
        case .findInDocument: return "Find in Document"
        case .reloadFromDisk: return "Reload from Disk"
        case .openFolder:     return "Open Folder…"
        case .zoomIn:         return "Zoom In"
        case .zoomOut:        return "Zoom Out"
        case .resetZoom:      return "Actual Size"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .commandPalette:  return KeyBinding(key: "p", command: true)
        case .omnisearch:      return KeyBinding(key: "o", command: true, shift: true)
        case .toggleSidebar:   return KeyBinding(key: "ArrowLeft", command: true, control: true)
        case .toggleInspector: return KeyBinding(key: "ArrowRight", command: true, control: true)
        case .copyFilePath:    return KeyBinding(key: "c", command: true, option: true)
        case .sendToVault:     return KeyBinding(key: "t", command: true, shift: true)
        case .autoRoute:       return KeyBinding(key: "t", command: true, control: true)
        case .openInObsidian:  return KeyBinding(key: "j", command: true, option: true)
        case .quickCapture:    return KeyBinding(key: "m", command: true, shift: true)
        case .sourceMode:      return KeyBinding(key: "1", command: true)
        case .splitMode:       return KeyBinding(key: "2", command: true)
        case .previewMode:     return KeyBinding(key: "3", command: true)
        case .newDraft:        return KeyBinding(key: "n", command: true)
        case .save:            return KeyBinding(key: "s", command: true)
        case .saveAs:          return KeyBinding(key: "s", command: true, shift: true)
        case .findInDocument:  return KeyBinding(key: "f", command: true)
        case .reloadFromDisk:  return KeyBinding(key: "r", command: true, option: true)
        case .openFolder:      return KeyBinding(key: "o", command: true, option: true)
        // "=" is the physical ⌘+ key (unshifted); matches Safari/Xcode zoom.
        case .zoomIn:          return KeyBinding(key: "=", command: true)
        case .zoomOut:         return KeyBinding(key: "-", command: true)
        case .resetZoom:       return KeyBinding(key: "0", command: true)
        }
    }
}

// MARK: - Conflicts

extension AppShortcut {
    /// Shortcuts the user can't remap: CmdMDApp's fixed menu key equivalents
    /// (keep in sync) and standard macOS ones. NSMenu fires only the first
    /// match in menu order, so a remap onto any of these would never fire.
    static let fixedShortcuts: [(title: String, binding: KeyBinding)] = [
        ("Open…", KeyBinding(key: "o", command: true)),
        ("Export as HTML…", KeyBinding(key: "e", command: true, shift: true)),
        ("New Tab", KeyBinding(key: "t", command: true)),
        ("Close Tab", KeyBinding(key: "w", command: true)),
        ("Next Tab", KeyBinding(key: "]", command: true, shift: true)),
        ("Previous Tab", KeyBinding(key: "[", command: true, shift: true)),
        ("Bold", KeyBinding(key: "b", command: true)),
        ("Italic", KeyBinding(key: "i", command: true)),
        ("Insert Link", KeyBinding(key: "k", command: true, shift: true)),
        ("Find and Replace…", KeyBinding(key: "f", command: true, option: true)),
        ("Find Next", KeyBinding(key: "g", command: true)),
        ("Find Previous", KeyBinding(key: "g", command: true, shift: true)),
        ("Use Selection for Find", KeyBinding(key: "e", command: true)),
        ("Find in Folder…", KeyBinding(key: "f", command: true, shift: true)),
        ("Settings…", KeyBinding(key: ",", command: true)),
        ("Hide CmdMD", KeyBinding(key: "h", command: true)),
        ("Hide Others", KeyBinding(key: "h", command: true, option: true)),
        ("Quit CmdMD", KeyBinding(key: "q", command: true)),
        ("Undo", KeyBinding(key: "z", command: true)),
        ("Redo", KeyBinding(key: "z", command: true, shift: true)),
        ("Cut", KeyBinding(key: "x", command: true)),
        ("Copy", KeyBinding(key: "c", command: true)),
        ("Paste", KeyBinding(key: "v", command: true)),
        ("Select All", KeyBinding(key: "a", command: true)),
        ("Minimize", KeyBinding(key: "m", command: true)),
        ("Enter Full Screen", KeyBinding(key: "f", command: true, control: true)),
        ("Emoji & Symbols", KeyBinding(key: "Space", command: true, control: true)),
        ("Help", KeyBinding(key: "/", command: true, shift: true)),
    ] + (1...9).map { ("Tab \($0)", KeyBinding(key: "\($0)", command: true, control: true)) }

    /// What already answers to `binding` besides this action — another
    /// action's current binding (`overrides` = settings.keyBindings) or a
    /// fixed shortcut — by title, or nil when the combination is free.
    func conflict(for binding: KeyBinding, overrides: [String: KeyBinding]) -> String? {
        guard !binding.isUnbound else { return nil }
        for other in Self.allCases where other != self {
            if (overrides[other.rawValue] ?? other.defaultBinding).isSameCombo(as: binding) {
                return other.title
            }
        }
        return Self.fixedShortcuts.first { $0.binding.isSameCombo(as: binding) }?.title
    }
}

// MARK: - Hints

extension AppState {
    /// The current binding as hint text ("⌥⌘O") — palette rows, tooltips,
    /// captions — so every hint follows remaps. Nil while unbound.
    func shortcutHint(for shortcut: AppShortcut) -> String? {
        let binding = keyBinding(for: shortcut)
        return binding.isUnbound ? nil : binding.displayString
    }

    /// `title` with the current shortcuts in parentheses, the tooltip format:
    /// "Open Folder (⌥⌘O)", "Change view mode (⌘1 / ⌘2 / ⌘3)". Unbound
    /// actions are left out.
    func shortcutHelp(_ title: String, _ shortcuts: AppShortcut...) -> String {
        let hints = shortcuts.compactMap { shortcutHint(for: $0) }
        return hints.isEmpty ? title : "\(title) (\(hints.joined(separator: " / ")))"
    }

    /// Whether ⌘+ (`KeyBinding.isZoomInAlternate`) zooms in: only while Zoom
    /// In keeps its default ⌘= — the alternate belongs to that default — no
    /// action is bound to "+" itself, and the recorder isn't capturing keys.
    var acceptsZoomInAlternate: Bool {
        recordingShortcut == nil
            && keyBinding(for: .zoomIn) == AppShortcut.zoomIn.defaultBinding
            && !AppShortcut.allCases.contains { keyBinding(for: $0).key == "+" }
    }
}

// MARK: - Applying a binding to a command/view

extension View {
    /// Applies a remappable shortcut. No-op when the key can't be represented.
    @ViewBuilder
    func appShortcut(_ binding: KeyBinding?) -> some View {
        if let binding, let key = binding.keyEquivalent {
            keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }
}
