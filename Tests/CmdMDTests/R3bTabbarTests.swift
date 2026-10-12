import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import CmdMD

/// Tab bar: a dragged tab travels as private data (not its UUID as text, which
/// the editor inserted into the note), AppKit can still deliver it to the bar,
/// the trailing drop zone covers the rest of the bar, and VoiceOver hears a
/// tab's state. The bar itself is hosted offscreen for the layout check.
final class R3bTabbarTests: XCTestCase {
    private var tempDir: URL!
    private var previousDataDir: String?

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTabBar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // AppState loads and writes its data files: keep it away from the real
        // Application Support folder.
        previousDataDir = ProcessInfo.processInfo.environment["CMDMD_DATA_DIR"]
        setenv("CMDMD_DATA_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousDataDir {
            setenv("CMDMD_DATA_DIR", previousDataDir, 1)
        } else {
            unsetenv("CMDMD_DATA_DIR")
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Drag payload (G116 / G074)

    func testDraggedTabIsPrivateDataNotText() {
        let type = TabDragItem.contentType
        XCTAssertFalse(type.conforms(to: .text), "text targets (the editor, Notes, Finder clippings) would accept it")
        XCTAssertFalse(type.conforms(to: .url))
        XCTAssertFalse(type.conforms(to: .image))
        XCTAssertNotEqual(type, .data, "a private type, not generic data")
        // AppKit only routes a drag to SwiftUI's drop destinations (registered
        // for public.data / public.item) when its type conforms to them; an
        // `UTType(exportedAs:)` the Info.plist doesn't declare conforms to neither.
        XCTAssertTrue(type.conforms(to: .data))
        XCTAssertTrue(type.conforms(to: .item))
    }

    func testDraggedTabOffersOnlyThePrivateTypeAndRoundTrips() {
        let item = TabDragItem(id: UUID())
        let provider = NSItemProvider()
        provider.register(item)

        XCTAssertEqual(provider.registeredContentTypes, [TabDragItem.contentType])
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))

        let loaded = expectation(description: "loads the dragged tab back")
        _ = provider.loadTransferable(type: TabDragItem.self) { result in
            XCTAssertEqual(try? result.get().id, item.id)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    func testPlainTextIsNotADraggedTab() {
        let provider = NSItemProvider(object: UUID().uuidString as NSString)
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(TabDragItem.contentType.identifier),
                       "text dragged onto the bar must not reorder tabs")
    }

    func testEditorCannotReadADraggedTab() throws {
        // Same setup as EditorTextView.makeNSView.
        let textView = CmdMDTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        textView.isRichText = true
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        let tabType = NSPasteboard.PasteboardType(TabDragItem.contentType.identifier)
        XCTAssertFalse(textView.readablePasteboardTypes.contains(tabType))
        XCTAssertFalse(textView.acceptableDragTypes.contains(tabType))
        XCTAssertFalse(textView.registeredDraggedTypes.contains(tabType))

        // Control: the old payload, the UUID as text, is something it inserts.
        let textPasteboard = NSPasteboard(name: NSPasteboard.Name("CmdMDTextDrag-\(UUID().uuidString)"))
        defer { textPasteboard.releaseGlobally() }
        textPasteboard.clearContents()
        textPasteboard.setString(UUID().uuidString, forType: .string)
        XCTAssertNotNil(textView.preferredPasteboardType(from: textPasteboard.types ?? [],
                                                         restrictedToTypesFrom: textView.acceptableDragTypes))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CmdMDTabDrag-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try JSONEncoder().encode(TabDragItem(id: UUID())), forType: tabType)

        XCTAssertNil(textView.preferredPasteboardType(from: pasteboard.types ?? [],
                                                      restrictedToTypesFrom: textView.acceptableDragTypes),
                     "nothing on a tab drag is something the editor would insert")
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testTabBarDropTargetsAcceptADraggedTab() throws {
        let targets = dropTargets(tabs: [EditorTab(title: "One")], width: 600)
        try XCTSkipIf(targets.isEmpty, "SwiftUI no longer backs drop destinations with AppKit views")

        let tabType = NSPasteboard.PasteboardType(TabDragItem.contentType.identifier)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CmdMDTabDrop-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(try JSONEncoder().encode(TabDragItem(id: UUID())), forType: tabType)

        // AppKit hands a drag only to views registered for a type on it (by
        // conformance): an undeclared `UTType(exportedAs:)` would match none.
        for target in targets {
            XCTAssertEqual(pasteboard.availableType(from: target.types), tabType)
        }
    }

    // MARK: - Trailing drop zone (G073)

    /// Hosts the bar offscreen and returns the frames (in bar coordinates,
    /// left to right) of the AppKit views SwiftUI registers for its drop
    /// destinations: one per tab, then the trailing zone.
    @MainActor
    private func dropTargetFrames(tabs: [EditorTab], width: CGFloat) -> [CGRect] {
        dropTargets(tabs: tabs, width: width).map(\.frame)
    }

    @MainActor
    private func dropTargets(tabs: [EditorTab], width: CGFloat) -> [(frame: CGRect, types: [NSPasteboard.PasteboardType])] {
        let state = AppState()
        state.tabs = tabs
        let host = NSHostingView(rootView: TabBarView().environment(state))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 34),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        var targets: [(frame: CGRect, types: [NSPasteboard.PasteboardType])] = []
        func collect(_ view: NSView) {
            if !view.registeredDraggedTypes.isEmpty {
                targets.append((view.convert(view.bounds, to: host), view.registeredDraggedTypes))
            }
            view.subviews.forEach(collect)
        }
        collect(host)
        return targets.sorted { $0.frame.minX < $1.frame.minX }
    }

    @MainActor
    func testTrailingDropZoneCoversTheRestOfTheBar() throws {
        let frames = dropTargetFrames(tabs: [EditorTab(title: "One"), EditorTab(title: "Two")], width: 800)
        try XCTSkipIf(frames.isEmpty, "SwiftUI no longer backs drop destinations with AppKit views")
        XCTAssertEqual(frames.count, 3, "one target per tab plus the trailing zone")
        let end = try XCTUnwrap(frames.last)
        // It used to be a 24 x 0 pt sliver after the + button: a horizontal
        // ScrollView offers no width, and a Spacer in an HStack has no height.
        XCTAssertEqual(end.maxX, 800 - 6, accuracy: 1, "reaches the end of the bar")
        XCTAssertGreaterThan(end.width, 400)
        XCTAssertGreaterThanOrEqual(end.height, frames[0].height, "a 0 pt tall target never gets a drop")
        // The tabs keep their natural width instead of stretching to fill.
        XCTAssertLessThan(frames[0].width, 120)
    }

    @MainActor
    func testTrailingDropZoneStaysReachableWhenTabsOverflow() throws {
        let tabs = (1...12).map { EditorTab(title: "A long enough tab title \($0)") }
        let frames = dropTargetFrames(tabs: tabs, width: 600)
        try XCTSkipIf(frames.isEmpty, "SwiftUI no longer backs drop destinations with AppKit views")
        XCTAssertEqual(frames.count, 13)
        let end = try XCTUnwrap(frames.last)
        XCTAssertGreaterThanOrEqual(end.width, 24, "a drop target after the last tab even when scrolled")
        XCTAssertGreaterThanOrEqual(end.height, frames[0].height)
        XCTAssertGreaterThan(end.minX, frames[11].maxX)
    }

    // MARK: - VoiceOver (G132 / G071)

    func testAccessibilityStatusSpeaksTheTabGlyphs() {
        XCTAssertEqual(TabItemView.accessibilityStatus(isDirty: false, isPinned: false, isFavorited: false), "")
        XCTAssertEqual(TabItemView.accessibilityStatus(isDirty: true, isPinned: false, isFavorited: false), "Edited")
        XCTAssertEqual(TabItemView.accessibilityStatus(isDirty: false, isPinned: true, isFavorited: false), "Pinned")
        XCTAssertEqual(TabItemView.accessibilityStatus(isDirty: true, isPinned: true, isFavorited: true),
                       "Edited, Pinned, Favorite")
    }
}
