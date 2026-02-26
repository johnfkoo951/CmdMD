import Foundation
import Network
import Observation

// MARK: - HTTP Request

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data?

    var pathWithoutQuery: String {
        if let idx = path.firstIndex(of: "?") {
            return String(path[path.startIndex..<idx])
        }
        return path
    }

    var queryParameters: [String: String] {
        guard let idx = path.firstIndex(of: "?") else { return [:] }
        let query = String(path[path.index(after: idx)...])
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let val = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[key] = val
            }
        }
        return params
    }

    var jsonDict: [String: Any]? {
        guard let body = body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - HTTP Response

struct HTTPResponse {
    let statusCode: Int
    let statusText: String
    let headers: [String: String]
    let body: Data?

    static func json(_ dict: [String: Any], status: Int = 200) -> HTTPResponse {
        let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        return HTTPResponse(
            statusCode: status,
            statusText: textForStatus(status),
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func error(_ message: String, status: Int = 400) -> HTTPResponse {
        json(["error": message], status: status)
    }

    static func ok(_ message: String = "OK") -> HTTPResponse {
        json(["status": "ok", "message": message])
    }

    private static func textForStatus(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

// MARK: - Log Entry

struct RemoteControlLogEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let method: String
    let path: String
    let statusCode: Int
}

// MARK: - Remote Control Service

@Observable
final class RemoteControlService {
    var isRunning: Bool = false
    var connectionCount: Int = 0
    var recentRequests: [RemoteControlLogEntry] = []

    private var listener: NWListener?
    private weak var appState: AppState?
    private var apiKey: String?
    private let queue = DispatchQueue(label: "com.cmdmd.remotecontrol", qos: .userInitiated)

    func start(appState: AppState, port: UInt16, apiKey: String?) {
        self.appState = appState
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("[RemoteControl] Invalid port: \(port)")
            return
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            print("[RemoteControl] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isRunning = true
                    print("[RemoteControl] Listening on port \(port)")
                case .failed(let error):
                    self?.isRunning = false
                    print("[RemoteControl] Failed: \(error)")
                    self?.listener?.cancel()
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.connectionCount = 0
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        DispatchQueue.main.async {
            self.connectionCount += 1
        }

        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                DispatchQueue.main.async {
                    self?.connectionCount = max(0, (self?.connectionCount ?? 1) - 1)
                }
            }
        }

        connection.start(queue: queue)
        readRequest(from: connection, accumulated: Data())
    }

    private func readRequest(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[RemoteControl] Read error: \(error)")
                connection.cancel()
                return
            }

            var allData = accumulated
            if let data = data {
                allData.append(data)
            }

            if let request = self.parseHTTPRequest(from: allData) {
                let contentLength = Int(request.headers["content-length"] ?? "0") ?? 0
                let bodyLength = request.body?.count ?? 0

                if bodyLength >= contentLength {
                    self.processAndRespond(request: request, connection: connection)
                } else {
                    self.readRequest(from: connection, accumulated: allData)
                }
            } else if isComplete {
                connection.cancel()
            } else {
                self.readRequest(from: connection, accumulated: allData)
            }
        }
    }

    private func processAndRespond(request: HTTPRequest, connection: NWConnection) {
        Task { @MainActor in
            let response = await self.routeRequest(request)
            let responseData = self.serializeHTTPResponse(response)

            let logEntry = RemoteControlLogEntry(
                id: UUID(),
                timestamp: Date(),
                method: request.method,
                path: request.pathWithoutQuery,
                statusCode: response.statusCode
            )
            self.recentRequests.insert(logEntry, at: 0)
            if self.recentRequests.count > 50 {
                self.recentRequests = Array(self.recentRequests.prefix(50))
            }

            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(from data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8),
              let headerEnd = string.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(string[string.startIndex..<headerEnd.lowerBound])
        let bodyStart = headerEnd.upperBound

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyString = String(string[bodyStart...])
        let body = bodyString.isEmpty ? nil : bodyString.data(using: .utf8)

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func serializeHTTPResponse(_ response: HTTPResponse) -> Data {
        var result = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"

        var headers = response.headers
        if let body = response.body {
            headers["Content-Length"] = "\(body.count)"
        }
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, X-API-Key"

        for (key, value) in headers {
            result += "\(key): \(value)\r\n"
        }
        result += "\r\n"

        var data = result.data(using: .utf8) ?? Data()
        if let body = response.body {
            data.append(body)
        }
        return data
    }

    // MARK: - Routing

    @MainActor
    func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // CORS preflight
        if request.method == "OPTIONS" {
            return HTTPResponse(
                statusCode: 204,
                statusText: "No Content",
                headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-Key"
                ],
                body: nil
            )
        }

        // API key authentication
        if let requiredKey = apiKey {
            let provided = request.headers["x-api-key"]
                ?? request.headers["authorization"]?.replacingOccurrences(of: "Bearer ", with: "")
            if provided != requiredKey {
                return .error("Unauthorized", status: 401)
            }
        }

        let path = request.pathWithoutQuery
        let segments = path.split(separator: "/").map(String.init)

        guard segments.first == "api" else {
            return .error("Not found. All endpoints are under /api/", status: 404)
        }

        let route = Array(segments.dropFirst())

        switch (request.method, route) {
        // Status
        case ("GET", ["status"]):
            return handleGetStatus()

        // Tabs
        case ("GET", ["tabs"]):
            return handleGetTabs()
        case ("POST", ["tabs"]):
            return handleCreateTab(request)
        case ("DELETE", ["tabs", let id]):
            return handleCloseTab(id)
        case ("PUT", ["tabs", let id, "activate"]):
            return handleActivateTab(id)

        // Current document
        case ("GET", ["document"]):
            return handleGetCurrentDocument()
        case ("PUT", ["document"]):
            return handleUpdateCurrentDocument(request)
        case ("POST", ["document", "insert"]):
            return handleInsertText(request)

        // Documents by ID
        case ("GET", ["documents", let id]):
            return handleGetDocument(id)
        case ("PUT", ["documents", let id]):
            return handleUpdateDocument(id, request: request)

        // Actions
        case ("POST", ["open"]):
            return handleOpenFile(request)
        case ("POST", ["save"]):
            return await handleSave()
        case ("POST", ["command"]):
            return handleCommand(request)

        // Info
        case ("GET", ["vaults"]):
            return handleGetVaults()
        case ("GET", ["settings"]):
            return handleGetSettings()

        default:
            return .error("Endpoint not found: \(request.method) /api/\(route.joined(separator: "/"))", status: 404)
        }
    }

    // MARK: - Status

    @MainActor
    private func handleGetStatus() -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        return .json([
            "status": "running",
            "app": "CmdMD",
            "version": "1.0.0",
            "tabs_open": state.tabs.count,
            "active_tab_id": state.activeTabId?.uuidString as Any,
            "has_document": state.currentDocument != nil,
            "view_mode": state.viewMode.rawValue,
            "sidebar_visible": state.sidebarVisible,
            "inspector_visible": state.inspectorVisible
        ])
    }

    // MARK: - Tabs

    @MainActor
    private func handleGetTabs() -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }

        let tabs: [[String: Any]] = state.tabs.map { tab in
            let doc = state.documents[tab.documentId]
            let isDirty = doc.map { $0.content != (state.originalContents[tab.documentId] ?? "") } ?? false
            return [
                "id": tab.id.uuidString,
                "document_id": tab.documentId.uuidString,
                "title": tab.displayTitle,
                "is_pinned": tab.isPinned,
                "is_dirty": isDirty,
                "is_active": tab.id == state.activeTabId,
                "file_url": tab.fileURL?.path as Any,
                "word_count": doc?.wordCount ?? 0,
                "character_count": doc?.characterCount ?? 0
            ]
        }

        return .json([
            "tabs": tabs,
            "count": state.tabs.count,
            "active_tab_id": state.activeTabId?.uuidString as Any
        ])
    }

    @MainActor
    private func handleCreateTab(_ request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }

        if let json = request.jsonDict, let content = json["content"] as? String {
            let title = json["title"] as? String ?? "Untitled"
            let document = MarkdownDocument(title: title, content: content)
            let tab = EditorTab(documentId: document.id, title: title)
            state.documents[document.id] = document
            state.originalContents[document.id] = content
            state.tabs.append(tab)
            state.activeTabId = tab.id

            return .json([
                "status": "created",
                "tab_id": tab.id.uuidString,
                "document_id": document.id.uuidString
            ], status: 201)
        } else {
            state.createNewTab()
            if let tab = state.tabs.last {
                return .json([
                    "status": "created",
                    "tab_id": tab.id.uuidString,
                    "document_id": tab.documentId.uuidString
                ], status: 201)
            }
            return .error("Failed to create tab", status: 500)
        }
    }

    @MainActor
    private func handleCloseTab(_ tabId: String) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let uuid = UUID(uuidString: tabId),
              let tab = state.tabs.first(where: { $0.id == uuid }) else {
            return .error("Tab not found", status: 404)
        }
        state.closeTab(tab)
        return .ok("Tab closed")
    }

    @MainActor
    private func handleActivateTab(_ tabId: String) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let uuid = UUID(uuidString: tabId),
              state.tabs.contains(where: { $0.id == uuid }) else {
            return .error("Tab not found", status: 404)
        }
        state.activeTabId = uuid
        return .ok("Tab activated")
    }

    // MARK: - Current Document

    @MainActor
    private func handleGetCurrentDocument() -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let doc = state.currentDocument else {
            return .error("No active document", status: 404)
        }

        let isDirty = doc.content != state.originalContent
        var result: [String: Any] = [
            "id": doc.id.uuidString,
            "title": doc.displayTitle,
            "content": doc.content,
            "word_count": doc.wordCount,
            "character_count": doc.characterCount,
            "is_draft": doc.isDraft,
            "is_dirty": isDirty,
            "created_at": ISO8601DateFormatter().string(from: doc.createdAt),
            "modified_at": ISO8601DateFormatter().string(from: doc.modifiedAt)
        ]

        if let url = doc.fileURL {
            result["file_url"] = url.path
        }

        if let fm = doc.frontmatter {
            var fmDict: [String: Any] = [:]
            if let title = fm.title { fmDict["title"] = title }
            if let date = fm.date { fmDict["date"] = ISO8601DateFormatter().string(from: date) }
            if !fm.tags.isEmpty { fmDict["tags"] = fm.tags }
            if !fm.aliases.isEmpty { fmDict["aliases"] = fm.aliases }
            if !fm.custom.isEmpty { fmDict["custom"] = fm.custom }
            result["frontmatter"] = fmDict
        }

        return .json(result)
    }

    @MainActor
    private func handleUpdateCurrentDocument(_ request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard state.currentDocument != nil else {
            return .error("No active document", status: 404)
        }
        guard let json = request.jsonDict else {
            return .error("Invalid JSON body", status: 400)
        }

        if let content = json["content"] as? String {
            state.updateContent(content)
        }
        if let title = json["title"] as? String {
            state.currentDocument?.title = title
        }

        return .ok("Document updated")
    }

    @MainActor
    private func handleInsertText(_ request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard var doc = state.currentDocument else {
            return .error("No active document", status: 404)
        }
        guard let json = request.jsonDict,
              let text = json["text"] as? String else {
            return .error("Missing 'text' in request body", status: 400)
        }

        if let position = json["position"] as? Int {
            let clamped = min(position, doc.content.count)
            let index = doc.content.index(doc.content.startIndex, offsetBy: clamped)
            doc.content.insert(contentsOf: text, at: index)
        } else if let after = json["after"] as? String,
                  let range = doc.content.range(of: after) {
            doc.content.insert(contentsOf: text, at: range.upperBound)
        } else if let before = json["before"] as? String,
                  let range = doc.content.range(of: before) {
            doc.content.insert(contentsOf: text, at: range.lowerBound)
        } else {
            doc.content.append(text)
        }

        doc.modifiedAt = Date()
        state.currentDocument = doc

        return .json([
            "status": "ok",
            "character_count": doc.characterCount,
            "word_count": doc.wordCount
        ])
    }

    // MARK: - Documents by ID

    @MainActor
    private func handleGetDocument(_ docId: String) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let uuid = UUID(uuidString: docId),
              let doc = state.documents[uuid] else {
            return .error("Document not found", status: 404)
        }

        var result: [String: Any] = [
            "id": doc.id.uuidString,
            "title": doc.displayTitle,
            "content": doc.content,
            "word_count": doc.wordCount,
            "character_count": doc.characterCount
        ]
        if let url = doc.fileURL {
            result["file_url"] = url.path
        }
        return .json(result)
    }

    @MainActor
    private func handleUpdateDocument(_ docId: String, request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let uuid = UUID(uuidString: docId),
              var doc = state.documents[uuid] else {
            return .error("Document not found", status: 404)
        }
        guard let json = request.jsonDict else {
            return .error("Invalid JSON body", status: 400)
        }

        if let content = json["content"] as? String {
            doc.content = content
        }
        if let title = json["title"] as? String {
            doc.title = title
        }
        doc.modifiedAt = Date()
        state.documents[uuid] = doc

        return .ok("Document updated")
    }

    // MARK: - Actions

    @MainActor
    private func handleOpenFile(_ request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let json = request.jsonDict,
              let path = json["path"] as? String else {
            return .error("Missing 'path' in request body", status: 400)
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error("File not found: \(path)", status: 404)
        }

        let inNewTab = json["new_tab"] as? Bool ?? true
        state.openDocument(at: url, inNewTab: inNewTab)

        return .ok("Opening file: \(url.lastPathComponent)")
    }

    @MainActor
    private func handleSave() async -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard state.currentDocument != nil else {
            return .error("No active document", status: 404)
        }
        await state.saveCurrentDocument()
        return .ok("Document saved")
    }

    @MainActor
    private func handleCommand(_ request: HTTPRequest) -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }
        guard let json = request.jsonDict,
              let command = json["command"] as? String else {
            return .error("Missing 'command' in request body", status: 400)
        }

        switch command {
        case "toggle_sidebar":
            state.sidebarVisible.toggle()
            return .ok("Sidebar toggled")
        case "show_sidebar":
            state.sidebarVisible = true
            return .ok("Sidebar shown")
        case "hide_sidebar":
            state.sidebarVisible = false
            return .ok("Sidebar hidden")
        case "toggle_inspector":
            state.inspectorVisible.toggle()
            return .ok("Inspector toggled")
        case "show_inspector":
            state.inspectorVisible = true
            return .ok("Inspector shown")
        case "hide_inspector":
            state.inspectorVisible = false
            return .ok("Inspector hidden")
        case "view_source":
            state.viewMode = .source
            return .ok("Switched to source view")
        case "view_split":
            state.viewMode = .split
            return .ok("Switched to split view")
        case "view_preview":
            state.viewMode = .preview
            return .ok("Switched to preview view")
        case "new_tab":
            state.createNewTab()
            return .ok("New tab created")
        case "next_tab":
            state.selectNextTab()
            return .ok("Switched to next tab")
        case "previous_tab":
            state.selectPreviousTab()
            return .ok("Switched to previous tab")
        case "show_command_palette":
            state.showCommandPalette = true
            return .ok("Command palette shown")
        case "new_draft":
            state.createNewDraft()
            return .ok("New draft created")
        default:
            let available = [
                "toggle_sidebar", "show_sidebar", "hide_sidebar",
                "toggle_inspector", "show_inspector", "hide_inspector",
                "view_source", "view_split", "view_preview",
                "new_tab", "next_tab", "previous_tab",
                "show_command_palette", "new_draft"
            ]
            return .json([
                "error": "Unknown command: \(command)",
                "available_commands": available
            ], status: 400)
        }
    }

    // MARK: - Info

    @MainActor
    private func handleGetVaults() -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }

        let vaults: [[String: Any]] = state.vaults.map { vault in
            [
                "id": vault.id.uuidString,
                "name": vault.displayName,
                "path": vault.rootPath.path,
                "is_default": vault.id == state.settings.defaultVaultId
            ]
        }
        return .json(["vaults": vaults, "count": state.vaults.count])
    }

    @MainActor
    private func handleGetSettings() -> HTTPResponse {
        guard let state = appState else { return .error("App not available", status: 500) }

        return .json([
            "view_mode": state.viewMode.rawValue,
            "sidebar_visible": state.sidebarVisible,
            "inspector_visible": state.inspectorVisible,
            "theme": state.settings.theme.rawValue,
            "editor_theme": state.settings.editorTheme.rawValue,
            "font_name": state.settings.fontName,
            "font_size": state.settings.fontSize,
            "autosave": state.settings.autosaveEnabled,
            "show_line_numbers": state.settings.showLineNumbers,
            "soft_wrap": state.settings.softWrap,
            "wiki_links": state.settings.enableWikiLinks,
            "callouts": state.settings.enableCallouts
        ])
    }
}
