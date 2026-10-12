import XCTest
import AppKit
import WebKit
@testable import CmdMD

/// AppStates built here point their whole data layer (settings, session,
/// recents…) at a throwaway directory through CMDMD_DATA_DIR, so these tests
/// never read or write the real Application Support/CmdMD.
class R3WindowSandboxTestCase: XCTestCase {
    private(set) var sandbox: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdmd-r3-window-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", sandbox.appendingPathComponent("data").path, 1)
    }

    override func tearDownWithError() throws {
        if let previousDataDir {
            setenv("CMDMD_DATA_DIR", previousDataDir, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: sandbox)
        try super.tearDownWithError()
    }

    /// Creates `path` under the sandbox — a folder when it ends in "/",
    /// otherwise a file holding `contents` — and returns its URL.
    @discardableResult
    func make(_ path: String, contents: String = "") throws -> URL {
        let url = sandbox.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

// MARK: - ⌘W follows the key window (G020, G115)

final class R3WindowCloseTargetTests: XCTestCase {
    func testNoKeyWindowClosesNothing() {
        // The editor window is closed (menu-bar only): its hidden tabs stay.
        XCTAssertEqual(AppWindowPolicy.closeTarget(hasKeyWindow: false, keyIsEditor: false, keyIsSheet: false), .nothing)
    }

    func testSettingsOrPanelKeyClosesThatWindow() {
        // Settings, the Quick Capture panel, the menu-bar window.
        XCTAssertEqual(AppWindowPolicy.closeTarget(hasKeyWindow: true, keyIsEditor: false, keyIsSheet: false), .keyWindow)
    }

    func testSheetKeyBeepsInsteadOfClosingTheTabUnderIt() {
        // Send to Vault on note A: ⌘W used to close A, and Send then sent B.
        XCTAssertEqual(AppWindowPolicy.closeTarget(hasKeyWindow: true, keyIsEditor: false, keyIsSheet: true), .beep)
    }

    func testEditorKeyClosesTheActiveTab() {
        XCTAssertEqual(AppWindowPolicy.closeTarget(hasKeyWindow: true, keyIsEditor: true, keyIsSheet: false), .editor)
    }
}

// MARK: - Dropping a folder opens it as the workspace (G037)

final class R3WindowDropTests: R3WindowSandboxTestCase {
    func testFoldersAreSplitFromFilesAndPackages() throws {
        let vault = try make("Vault/")
        let note = try make("note.md", contents: "# Note")
        let package = try make("Fake.app/")

        let dropped = AppWindowPolicy.partitionDroppedURLs([note, vault, package])

        XCTAssertEqual(dropped.folders.map(\.lastPathComponent), ["Vault"])
        // Packages are single files to Finder; they keep the file path.
        XCTAssertEqual(dropped.files.map(\.lastPathComponent), ["note.md", "Fake.app"])
    }

    func testUnreadableURLStaysOnTheFilePath() {
        let missing = sandbox.appendingPathComponent("gone.md")
        let dropped = AppWindowPolicy.partitionDroppedURLs([missing])
        XCTAssertTrue(dropped.folders.isEmpty)
        XCTAssertEqual(dropped.files, [missing])
    }

    func testOpenFolderAtURLMakesItTheWorkspace() throws {
        let vault = try make("Vault/")
        try make("Vault/inbox.md", contents: "hello")
        let state = AppState()
        state.sidebarVisible = false
        state.selectedSidebarTab = .favorites

        state.openFolder(at: vault)

        XCTAssertEqual(state.currentFolder, vault)
        XCTAssertEqual(state.selectedSidebarTab, .files)
        XCTAssertTrue(state.sidebarVisible)
        XCTAssertTrue(state.fileTree.contains { $0.url.lastPathComponent == "inbox.md" })
    }
}

// MARK: - Window size settings stay on screen (G101)

final class R3WindowFrameClampTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testOversizedFrameShrinksToTheVisibleArea() {
        let frame = CGRect(x: 400, y: 0, width: 2000, height: 900)
        XCTAssertEqual(WindowFrameClamp.clamped(frame, to: visible), CGRect(x: 0, y: 0, width: 1440, height: 875))
    }

    func testFrameInsideIsUnchanged() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowFrameClamp.clamped(frame, to: visible), frame)
    }

    func testRightOverflowShiftsLeftKeepingItsSize() {
        let frame = CGRect(x: 1000, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowFrameClamp.clamped(frame, to: visible), CGRect(x: 640, y: 100, width: 800, height: 600))
    }

    func testTopOverflowMovesDownBelowTheMenuBar() {
        let frame = CGRect(x: 100, y: 400, width: 800, height: 600)
        let clamped = WindowFrameClamp.clamped(frame, to: visible)
        XCTAssertEqual(clamped.maxY, visible.maxY)
        XCTAssertEqual(clamped.size, frame.size)
    }

    func testRespectsAVisibleAreaAboveTheDock() {
        let aboveDock = CGRect(x: 0, y: 80, width: 1440, height: 795)
        let frame = CGRect(x: 100, y: 20, width: 800, height: 600)
        let clamped = WindowFrameClamp.clamped(frame, to: aboveDock)
        XCTAssertGreaterThanOrEqual(clamped.minY, aboveDock.minY)
        XCTAssertLessThanOrEqual(clamped.maxY, aboveDock.maxY)
    }
}

// MARK: - The palette overlay hands focus back (G021)

final class R3WindowPaletteFocusTests: XCTestCase {
    func testEditorIsRestoredOnlyWhereItIsVisible() {
        XCTAssertFalse(PaletteFocus.shouldRestore(isEditor: true, isPreview: false, mode: .preview))
        XCTAssertTrue(PaletteFocus.shouldRestore(isEditor: true, isPreview: false, mode: .source))
        XCTAssertTrue(PaletteFocus.shouldRestore(isEditor: true, isPreview: false, mode: .split))
    }

    func testPreviewIsRestoredOnlyWhereItIsVisible() {
        XCTAssertFalse(PaletteFocus.shouldRestore(isEditor: false, isPreview: true, mode: .source))
        XCTAssertTrue(PaletteFocus.shouldRestore(isEditor: false, isPreview: true, mode: .preview))
        XCTAssertTrue(PaletteFocus.shouldRestore(isEditor: false, isPreview: true, mode: .split))
    }

    func testOtherViewsAreAlwaysRestorable() {
        XCTAssertTrue(PaletteFocus.shouldRestore(isEditor: false, isPreview: false, mode: .preview))
    }

    func testRestorableViewSkipsThePalettesOwnFieldAndNonViews() {
        XCTAssertNil(PaletteFocus.restorableView(for: nil))
        XCTAssertNil(PaletteFocus.restorableView(for: AutoFocusTextField()))
        XCTAssertNil(PaletteFocus.restorableView(for: NSResponder()))

        let textView = NSTextView()
        XCTAssertTrue(PaletteFocus.restorableView(for: textView) === textView)
    }

    func testWebViewDescendantsCountAsThePreview() {
        let webView = WKWebView(frame: .zero)
        let inner = NSView()
        webView.addSubview(inner)
        XCTAssertTrue(PaletteFocus.isInWebView(webView))
        XCTAssertTrue(PaletteFocus.isInWebView(inner))
        XCTAssertFalse(PaletteFocus.isInWebView(NSView()))
    }
}

// MARK: - Toasts say what happened (G028)

final class R3WindowToastTests: R3WindowSandboxTestCase {
    func testStyleTravelsWithTheMessage() {
        let state = AppState()
        state.showToast("Saved")
        XCTAssertEqual(state.toastStyle, .success)

        state.showToast("Couldn't toggle that task", style: .error)
        XCTAssertEqual(state.toastMessage, "Couldn't toggle that task")
        XCTAssertEqual(state.toastStyle, .error)
    }

    func testFailuresNoLongerWearTheSuccessCheckmark() {
        XCTAssertEqual(ToastStyle.success.symbol, "checkmark.circle.fill")
        XCTAssertNotEqual(ToastStyle.warning.symbol, ToastStyle.success.symbol)
        XCTAssertNotEqual(ToastStyle.error.symbol, ToastStyle.success.symbol)
        XCTAssertNotEqual(ToastStyle.error.color, ToastStyle.success.color)
    }

    func testRepeatedToastIsNotCutShortByTheEarlierTimer() {
        // Autosave "Saved", then ⌘S "Saved" 1.5 s later: the first timer used
        // to clear the second toast after about half a second.
        let state = AppState()
        state.showToast("Saved")

        let checked = expectation(description: "second toast still up")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            state.showToast("Saved")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                XCTAssertEqual(state.toastMessage, "Saved")
                checked.fulfill()
            }
        }
        wait(for: [checked], timeout: 5)
    }
}

// MARK: - Closing the editor window drops pending sheets (G023)

final class R3WindowCaptureStashTests: R3WindowSandboxTestCase {
    /// Final review: quitting with text left in the hidden floating capture
    /// panel threw it away; it now becomes the newest draft.
    func testUnsentCaptureBecomesADraft() {
        let state = AppState()
        let before = state.drafts.count

        state.stashCaptureAsDraft("Buy milk\nand eggs")

        XCTAssertEqual(state.drafts.count, before + 1)
        XCTAssertEqual(state.drafts.first?.body, "Buy milk\nand eggs")
    }
}

final class R3WindowPresentationTests: R3WindowSandboxTestCase {
    func testDismissTransientPresentationsClearsSheetsButNotOnboarding() {
        let state = AppState()
        state.settings.hasCompletedOnboarding = false
        state.showCommandPalette = true
        state.showOmnisearch = true
        state.showSendToVault = true
        state.showVaultManager = true
        state.showQuickCapture = true
        state.showAbout = true
        state.batchSendURLs = [sandbox.appendingPathComponent("a.md")]

        state.dismissTransientPresentations()

        XCTAssertFalse(state.showCommandPalette)
        XCTAssertFalse(state.showOmnisearch)
        XCTAssertFalse(state.showSendToVault)
        XCTAssertFalse(state.showVaultManager)
        XCTAssertFalse(state.showQuickCapture)
        XCTAssertFalse(state.showAbout)
        XCTAssertTrue(state.batchSendURLs.isEmpty)
        XCTAssertFalse(state.settings.hasCompletedOnboarding)
    }
}

// MARK: - Zoom In/Out disable at the limits (G129)

final class R3WindowZoomLimitTests: R3WindowSandboxTestCase {
    func testZoomStepsLandExactlyOnTheRangeBounds() {
        // View › Zoom In/Out are disabled by comparing against these bounds.
        let state = AppState()
        for _ in 0..<40 { state.zoomIn() }
        XCTAssertEqual(state.settings.zoomLevel, AppState.zoomRange.upperBound)

        for _ in 0..<40 { state.zoomOut() }
        XCTAssertEqual(state.settings.zoomLevel, AppState.zoomRange.lowerBound)
    }
}

// MARK: - Quick Capture panel close keeps the text (G123)

final class R3WindowQuickCapturePanelTests: XCTestCase {
    func testTitleBarCloseHidesInsteadOfClosing() {
        let controller = QuickCapturePanelController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertFalse(window.isVisible)
    }
}
