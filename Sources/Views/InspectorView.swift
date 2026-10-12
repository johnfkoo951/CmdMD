import SwiftUI

enum InspectorTab: String, CaseIterable {
    case toc = "TOC"
    case properties = "Properties"
    case send = "Send"
    
    var icon: String {
        switch self {
        case .toc: return "list.bullet.indent"
        case .properties: return "list.bullet.rectangle"
        case .send: return "paperplane"
        }
    }
}

struct InspectorView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: InspectorTab = .toc
    
    var body: some View {
        VStack(spacing: 0) {
            if appState.currentDocument != nil {
                InspectorTabBar(selectedTab: $selectedTab)
                
                Divider()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case .toc:
                            if let document = appState.currentDocument {
                                TableOfContentsSection(document: document)
                            }
                        case .properties:
                            if let document = appState.currentDocument {
                                FrontmatterSection(document: document)
                            }
                        case .send:
                            SendSection()
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                InspectorBottomSection()
            } else {
                ContentUnavailableView("No Document", systemImage: "doc.text", description: Text("Open a file to see its details"))
            }
        }
        // No opaque background — the system inspector supplies its own
        // translucent material, which painting windowBackgroundColor destroyed.
    }
}

/// Native segmented switcher — the previous custom underline tab bar read as
/// web/iOS chrome inside a macOS inspector panel.
struct InspectorTabBar: View {
    @Binding var selectedTab: InspectorTab

    var body: some View {
        Picker("Inspector Section", selection: $selectedTab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Image(systemName: tab.icon)
                    .help(tab.rawValue)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SendSection: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.vaults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("No vaults configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    Button("Add Vault") {
                        appState.showVaultManager = true
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Quick Send", systemImage: "paperplane")
                        .font(.headline)
                    
                    ForEach(appState.vaults.prefix(3)) { vault in
                        Button {
                            quickSendToVault(vault)
                        } label: {
                            HStack {
                                Image(systemName: "tray.and.arrow.down.fill")
                                    .foregroundStyle(Color.cmdsAccent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(vault.displayName)
                                    Text(appState.effectiveSendFolder(for: vault))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if appState.vaults.count > 3 {
                        Button {
                            appState.showSendToVault = true
                        } label: {
                            HStack {
                                Text("More options...")
                                    .font(.callout)
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                
                Divider()
                    .padding(.vertical, 8)

                Button {
                    appState.showSendToVault = true
                } label: {
                    Label("Send with Options...", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Divider()
                    .padding(.vertical, 8)

                QuickActionsSection()
            }
        }
    }
    
    private func quickSendToVault(_ vault: Vault) {
        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = appState.effectiveSendFolder(for: vault)
            options.conflictResolution = appState.settings.conflictResolution
            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault

            do {
                try await appState.sendToVault(options: options)
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }
}

struct InspectorBottomSection: View {
    @Environment(AppState.self) private var appState
    @State private var showingInfo: Bool = false
    @State private var wordCount = 0
    @State private var characterCount = 0
    @State private var hasCounted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingInfo.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        Text("Info")
                            .font(.caption)
                    }
                    .foregroundStyle(showingInfo ? Color.cmdsAccent : Color.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if appState.currentDocument != nil {
                    Text("\(wordCount.formatted()) words")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showingInfo, let document = appState.currentDocument {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    CompactInfoRow(label: "Characters", value: characterCount.formatted())
                    CompactInfoRow(label: "Modified", value: document.modifiedAt.formatted(.dateTime.month().day().hour().minute()))
                    if let url = document.fileURL {
                        CompactInfoRow(label: "Path", value: (url.path as NSString).abbreviatingWithTildeInPath)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingInfo)
        // Debounced like the status bar — full-document counting per keystroke
        // with the inspector open was pure main-thread waste.
        .task(id: appState.currentDocument?.content ?? "") {
            guard let content = appState.currentDocument?.content else { return }
            if hasCounted {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            wordCount = DocumentStatsView.countWords(in: content)
            characterCount = content.count
            hasCounted = true
        }
    }
}

struct CompactInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

struct TableOfContentsSection: View {
    let document: MarkdownDocument

    // Shared with the renderer (fence-aware, deduplicating slugger) so a TOC
    // click always lands on the right anchor — including duplicate and Korean
    // headings. Debounced: with the inspector open, re-parsing the whole
    // document on every keystroke (twice — isEmpty check + ForEach) was a
    // measurable slice of typing latency.
    @State private var headings: [TOCHeading] = []
    @State private var hasParsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Table of Contents", systemImage: "list.bullet.indent")
                .font(.headline)

            if headings.isEmpty {
                Text("No headings found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(headings) { heading in
                        TOCHeadingRow(heading: heading)
                    }
                }
            }
        }
        .task(id: document.content) {
            if hasParsed {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            headings = TOCBuilder.extractHeadings(from: document.content)
            hasParsed = true
        }
    }
}

struct TOCHeadingRow: View {
    let heading: TOCHeading
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Button {
            scrollToHeading(heading)
        } label: {
            HStack(spacing: 4) {
                Text(heading.text)
                    .font(.system(size: fontSize))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.leading, CGFloat(heading.level - 1) * 12)
        }
        .buttonStyle(.plain)
    }
    
    private var fontSize: CGFloat {
        switch heading.level {
        case 1: return 13
        case 2: return 12
        case 3: return 11
        default: return 10
        }
    }
    
    private func scrollToHeading(_ heading: TOCHeading) {
        if appState.viewMode != .preview {
            NotificationCenter.default.post(name: .scrollToLine, object: heading.lineNumber)
        }
        if appState.viewMode != .source {
            NotificationCenter.default.post(name: .scrollToHeading, object: heading.slug)
        }
    }
}

extension Notification.Name {
    static let scrollToLine = Notification.Name("scrollToLine")
}



struct FrontmatterSection: View {
    @Environment(AppState.self) private var appState
    let document: MarkdownDocument
    @State private var isEditing: Bool = false
    @State private var newTagText: String = ""
    @State private var showAddProperty: Bool = false
    @State private var newPropertyKey: String = ""
    @State private var newPropertyValue: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Properties", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                if document.frontmatter != nil {
                    Button {
                        isEditing.toggle()
                    } label: {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                            .foregroundStyle(isEditing ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if let frontmatter = document.frontmatter {
                VStack(alignment: .leading, spacing: 2) {
                    if let title = frontmatter.title {
                        PropertyRow(
                            icon: "textformat",
                            label: "title",
                            isEditing: isEditing
                        ) {
                            if isEditing {
                                TextField("Title", text: binding(for: \.title, default: ""))
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                            } else {
                                Text(title)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    
                    PropertyRow(
                        icon: "calendar",
                        label: "date",
                        isEditing: isEditing
                    ) {
                        if isEditing {
                            DatePicker("", selection: dateBinding, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                        } else if let date = frontmatter.date {
                            Text(date.formatted(.dateTime.day().month().year()))
                                .font(.callout)
                                .foregroundStyle(.primary)
                        } else {
                            Text("Not set")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    PropertyRow(
                        icon: "tag",
                        label: "tags",
                        isEditing: isEditing
                    ) {
                        FlowLayout(spacing: 4) {
                            ForEach(frontmatter.tags, id: \.self) { tag in
                                EditableTagChip(
                                    tag: tag,
                                    isEditing: isEditing,
                                    onRemove: { removeTag(tag) }
                                )
                            }
                            if isEditing {
                                AddTagField(
                                    text: $newTagText,
                                    onAdd: { addTag(newTagText) }
                                )
                            }
                        }
                    }
                    
                    if !frontmatter.aliases.isEmpty || isEditing {
                        PropertyRow(
                            icon: "link",
                            label: "aliases",
                            isEditing: isEditing
                        ) {
                            if isEditing {
                                TextField("Aliases (comma-separated)", text: aliasesBinding)
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                            } else {
                                Text(frontmatter.aliases.joined(separator: ", "))
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    
                    ForEach(Array(frontmatter.custom.keys.sorted()), id: \.self) { key in
                        PropertyRow(
                            icon: "text.alignleft",
                            label: key,
                            isEditing: isEditing,
                            onDelete: isEditing ? { removeCustomProperty(key) } : nil
                        ) {
                            if isEditing {
                                TextField(key, text: customBinding(for: key))
                                    .textFieldStyle(.plain)
                                    .font(.callout)
                            } else if let value = frontmatter.custom[key] {
                                Text(value.displayString)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    
                    if isEditing {
                        if showAddProperty {
                            AddPropertyRow(
                                keyText: $newPropertyKey,
                                valueText: $newPropertyValue,
                                onAdd: {
                                    addCustomProperty(key: newPropertyKey, value: newPropertyValue)
                                    newPropertyKey = ""
                                    newPropertyValue = ""
                                    showAddProperty = false
                                },
                                onCancel: {
                                    showAddProperty = false
                                    newPropertyKey = ""
                                    newPropertyValue = ""
                                }
                            )
                        } else {
                            Button {
                                showAddProperty = true
                            } label: {
                                Label("Add property", systemImage: "plus.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    Text("No properties")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    Button("Add Properties") {
                        addFrontmatter()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    private var dateBinding: Binding<Date> {
        Binding(
            get: { document.frontmatter?.date ?? Date() },
            set: { newDate in
                updateFrontmatter { fm in
                    fm.date = newDate
                }
            }
        )
    }
    
    private var aliasesBinding: Binding<String> {
        Binding(
            get: { document.frontmatter?.aliases.joined(separator: ", ") ?? "" },
            set: { newValue in
                let aliases = newValue.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                updateFrontmatter { fm in
                    fm.aliases = aliases
                }
            }
        )
    }
    
    private func binding(for keyPath: WritableKeyPath<Frontmatter, String?>, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { document.frontmatter?[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                updateFrontmatter { fm in
                    fm[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }
    
    private func customBinding(for key: String) -> Binding<String> {
        Binding(
            get: { document.frontmatter?.custom[key]?.displayString ?? "" },
            set: { newValue in
                updateFrontmatter { fm in
                    fm.custom[key] = .string(newValue)
                }
            }
        )
    }
    
    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        updateFrontmatter { fm in
            if !fm.tags.contains(trimmed) {
                fm.tags.append(trimmed)
            }
        }
        newTagText = ""
    }
    
    private func removeTag(_ tag: String) {
        updateFrontmatter { fm in
            fm.tags.removeAll { $0 == tag }
        }
    }
    
    private func addCustomProperty(key: String, value: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedKey.isEmpty else { return }
        updateFrontmatter { fm in
            fm.custom[trimmedKey] = .string(value)
        }
    }
    
    private func removeCustomProperty(_ key: String) {
        updateFrontmatter { fm in
            fm.custom.removeValue(forKey: key)
        }
    }
    
    private func updateFrontmatter(_ update: (inout Frontmatter) -> Void) {
        guard var doc = appState.currentDocument,
              var frontmatter = doc.frontmatter else { return }
        update(&frontmatter)
        doc.frontmatter = frontmatter
        appState.currentDocument = doc
    }
    
    private func addFrontmatter() {
        guard var doc = appState.currentDocument else { return }
        // Set the frontmatter model only; the body stays untouched. fullText
        // composes the YAML block on save.
        doc.frontmatter = Frontmatter(
            title: doc.displayTitle,
            date: Date()
        )
        appState.currentDocument = doc
        isEditing = true
    }
}

struct PropertyRow<Content: View>: View {
    let icon: String
    let label: String
    let isEditing: Bool
    var onDelete: (() -> Void)?
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if let onDelete = onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EditableTagChip: View {
    let tag: String
    let isEditing: Bool
    let onRemove: () -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            Text("#\(tag)")
                .font(.caption)
            if isEditing {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.cmdsAccentSoft)
        .foregroundStyle(Color.cmdsAccent)
        .clipShape(Capsule())
    }
}

struct AddTagField: View {
    @Binding var text: String
    let onAdd: () -> Void
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 2) {
            Text("#")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("tag", text: $text)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 60)
                .focused($isFocused)
                .onSubmit {
                    onAdd()
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Capsule()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

struct AddPropertyRow: View {
    @Binding var keyText: String
    @Binding var valueText: String
    let onAdd: () -> Void
    let onCancel: () -> Void
    @FocusState private var keyFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            
            TextField("key", text: $keyText)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 56)
                .focused($keyFocused)
            
            TextField("value", text: $valueText)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit {
                    if !keyText.isEmpty {
                        onAdd()
                    }
                }
            
            Button {
                onAdd()
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .disabled(keyText.isEmpty)
            
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .onAppear {
            keyFocused = true
        }
    }
}



struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        
        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

struct QuickActionsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Quick Actions", systemImage: "bolt")
                .font(.headline)

            VStack(spacing: 8) {
                if let url = appState.currentDocument?.fileURL {
                    Button {
                        openInObsidian(url: url)
                    } label: {
                        Label("Open in Obsidian", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    copyAsMarkdown()
                } label: {
                    Label("Copy as Markdown", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func openInObsidian(url: URL) {
        // Vault folder names are what Obsidian actually keys on (the display
        // alias broke links); fall back to a path-based open outside any vault.
        if let vault = appState.vaults.first(where: { $0.contains(url) }),
           let obsidianURL = vault.obsidianURL(forFile: url) {
            NSWorkspace.shared.open(obsidianURL)
            return
        }

        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let obsidianURL = components.url {
            NSWorkspace.shared.open(obsidianURL)
        }
    }

    private func copyAsMarkdown() {
        guard let content = appState.currentDocument?.content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        appState.showToast("Copied to clipboard")
    }
}

#if !SWIFT_PACKAGE
#Preview {
    InspectorView()
        .environment(AppState())
        .frame(width: 280, height: 600)
}
#endif
