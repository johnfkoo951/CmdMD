import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut registered with Carbon's
/// `RegisterEventHotKey` — the global-shortcut API that needs no privacy
/// permission. (An NSEvent global monitor only receives keys once the app is
/// trusted for Accessibility, a grant ad-hoc-signed builds lose on every
/// update, and it can't consume the keystroke.) The hot key fires on the main
/// thread and swallows the key combination while registered.
final class GlobalHotKey {
    /// Tags our hot key events ("CMDM").
    private static let signature: OSType = 0x434D_444D

    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `binding`, replacing any previous registration. Returns false
    /// (leaving nothing registered) when the binding can't be global — see
    /// `canRegisterGlobally` — or the combination is already taken.
    @discardableResult
    func register(_ binding: KeyBinding) -> Bool {
        unregister()
        guard Self.canRegisterGlobally(binding),
              let keyCode = Self.carbonKeyCode(for: binding.key) else {
            Log.info("global hotkey \(binding.displayString) left in-app only (needs ⌘ or ⌃ and a standard key)")
            return false
        }
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            Self.carbonModifiers(for: binding),
            EventHotKeyID(signature: Self.signature, id: 1),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            Log.error("global hotkey \(binding.displayString) not registered (OSStatus \(status))")
            return false
        }
        hotKeyRef = ref
        Log.info("global hotkey \(binding.displayString) registered")
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKey.signature, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon dispatches hot key events on the main thread.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if status != noErr {
            Log.error("global hotkey handler not installed (OSStatus \(status))")
        }
    }

    // MARK: - KeyBinding → Carbon

    /// Only ⌘ or ⌃ combinations go global: a bare, ⇧- or ⌥-only hot key would
    /// swallow ordinary typing in every app (⌥ combinations type characters
    /// such as å or –). Other bindings keep working in-app through the menu.
    static func canRegisterGlobally(_ binding: KeyBinding) -> Bool {
        (binding.command || binding.control) && carbonKeyCode(for: binding.key) != nil
    }

    /// Carbon modifier mask (`cmdKey | shiftKey | optionKey | controlKey`).
    static func carbonModifiers(for binding: KeyBinding) -> UInt32 {
        var mask = 0
        if binding.command { mask |= cmdKey }
        if binding.shift { mask |= shiftKey }
        if binding.option { mask |= optionKey }
        if binding.control { mask |= controlKey }
        return UInt32(mask)
    }

    /// Virtual key code for a `KeyBinding.key`, by US-ANSI key position, or nil
    /// when the key has no fixed position (so it is never bound to a wrong key).
    static func carbonKeyCode(for key: String) -> UInt32? {
        if let code = namedKeyCodes[key] { return UInt32(code) }
        guard key.count == 1, let character = key.lowercased().first,
              let code = characterKeyCodes[character] else { return nil }
        return UInt32(code)
    }

    private static let namedKeyCodes: [String: Int] = [
        "ArrowLeft": kVK_LeftArrow, "ArrowRight": kVK_RightArrow,
        "ArrowUp": kVK_UpArrow, "ArrowDown": kVK_DownArrow,
        "Space": kVK_Space, "Return": kVK_Return, "Enter": kVK_Return,
        "Tab": kVK_Tab, "Escape": kVK_Escape,
    ]

    /// The recorder stores `charactersIgnoringModifiers`, which keeps Shift's
    /// effect — so shifted symbols ("+", "!") map to their unshifted key.
    private static let characterKeyCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
        "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ")": kVK_ANSI_0, "!": kVK_ANSI_1, "@": kVK_ANSI_2, "#": kVK_ANSI_3,
        "$": kVK_ANSI_4, "%": kVK_ANSI_5, "^": kVK_ANSI_6, "&": kVK_ANSI_7,
        "*": kVK_ANSI_8, "(": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "_": kVK_ANSI_Minus,
        "=": kVK_ANSI_Equal, "+": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "{": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "}": kVK_ANSI_RightBracket,
        "\\": kVK_ANSI_Backslash, "|": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, ":": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, "\"": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, "<": kVK_ANSI_Comma,
        ".": kVK_ANSI_Period, ">": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "?": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave, "~": kVK_ANSI_Grave,
    ]
}
