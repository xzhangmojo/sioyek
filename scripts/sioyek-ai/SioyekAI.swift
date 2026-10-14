// A chat window which talks to Claude (through the `claude` command line tool) about a PDF opened in sioyek.
//
// usage: sioyek-ai <pdf path> <document checksum> [action] [selected text] [page]
//
// each document has one chat which is saved in ~/Library/Application Support/sioyek/ai_chats/<checksum>.json and
// restored when the chat is opened again. like a chat with an uploaded file on claude.ai, the document is sent once,
// when the chat's claude session starts, and later questions resume that session (so the document is read from
// claude's prompt cache instead of being processed again). documents too long to include are saved as a text file
// which claude searches with its Grep and Read tools.
//
// sioyek sends requests as json lines on stdin: {"action": "explain", "text": "<selected text>", "page": 3}
// actions: explain, summarize, define, translate (or translate:<language>), ask (type a question about the selected
// text), chat (just show the chat). the optional command line action is handled like a first request (for testing).
//
// optional settings are read from ~/.config/sioyek/sioyek-ai.conf, one `key=value` per line:
//   model=sonnet                  model passed to `claude --model` (default sonnet; opus for harder documents)
//   translate_to=English          default target language of the translate action
//   reply_language=English        language of the replies (default: the language of the question)
//   max_inline_chars=300000       documents with more text are searched by claude instead of being included
//   claude_path=/path/claude      location of the claude executable

import AppKit
import PDFKit

// MARK: - settings

struct Settings {
    var model: String? = "sonnet"
    var translateTo = "English"
    var replyLanguage: String?
    var maxInlineChars = 300_000
    var claudePath: String?

    static func load() -> Settings {
        var settings = Settings()
        let path = NSString(string: "~/.config/sioyek/sioyek-ai.conf").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return settings }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            switch key {
            case "model": settings.model = value
            case "translate_to": settings.translateTo = value
            case "reply_language": settings.replyLanguage = value
            case "max_inline_chars": settings.maxInlineChars = Int(value) ?? settings.maxInlineChars
            case "claude_path": settings.claudePath = NSString(string: value).expandingTildeInPath
            default: break
            }
        }
        return settings
    }
}

// MARK: - chat history

struct Turn: Codable {
    var question: String         // what is shown for the question, e.g. "Explain" or the typed question
    var quote: String?           // the selected text the question is about
    var page: Int?               // 0-based page of the quote
    var answer: String
    var date: Date
}

struct ChatHistory: Codable {
    var document: String
    // the claude session which has the document and the conversation, resumed for every question
    var sessionId: String?
    // the user allowed sending this document to claude although SioLibrary marked it sensitive
    var allowSensitive: Bool?
    var turns: [Turn] = []

    // where the histories, the text of long documents and the claude sessions (which belong to the working directory
    // they were started in) are kept
    static var directory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("sioyek/ai_chats")
    }

    static func url(checksum: String) -> URL {
        return directory.appendingPathComponent("\(checksum).json")
    }

    static func load(checksum: String, document: String) -> ChatHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url(checksum: checksum)),
           let history = try? decoder.decode(ChatHistory.self, from: data) {
            return history
        }
        return ChatHistory(document: document)
    }

    func save(checksum: String) {
        let url = ChatHistory.url(checksum: checksum)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - requests

struct Request {
    var action: String
    var text: String
    var page: Int?

    static func parse(_ line: String) -> Request? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Request(action: json["action"] as? String ?? "chat",
                       text: (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       page: json["page"] as? Int)
    }
}

// what to ask claude for a request, nil when the user has to type the question
func instruction(for request: Request, settings: Settings) -> (label: String, prompt: String)? {
    let parts = request.action.split(separator: ":", maxSplits: 1).map(String.init)
    let hasText = !request.text.isEmpty
    switch parts.first?.lowercased() ?? "" {
    case "explain" where hasText:
        return ("Explain", "Explain the selected passage clearly and concisely, using the rest of the document for context where it helps. Define technical terms and give any background needed to understand it.")
    case "summarize":
        if hasText {
            return ("Summarize", "Summarize the selected passage in a few short bullet points.")
        }
        return ("Summarize the document", "Summarize the whole document: its main question, approach and conclusions, in a few short paragraphs or bullet points.")
    case "define" where hasText:
        return ("Define", "Define the selected term or phrase as it is used in this document. Keep it short.")
    case "translate" where hasText:
        let language = parts.count > 1 ? parts[1] : settings.translateTo
        return ("Translate", "Translate the selected text into \(language). Output only the translation.")
    default:
        return nil
    }
}

// MARK: - document text

func extractDocumentText(path: String) -> (text: String, pageCount: Int) {
    guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else { return ("", 0) }
    var text = ""
    for index in 0..<document.pageCount {
        text += "[page \(index + 1)]\n\(document.page(at: index)?.string ?? "")\n\n"
    }
    return (text, document.pageCount)
}

// MARK: - claude process

final class ClaudeRunner {
    private var process: Process?
    private var buffer = Data()
    private var stderrData = Data()
    private var receivedText = false
    private var resultError: String?
    private var sessionId: String?

    var onText: ((String) -> Void)?
    var onFinish: ((_ error: String?, _ sessionId: String?) -> Void)?

    static func findClaude(settings: Settings) -> String? {
        let fm = FileManager.default
        if let path = settings.claudePath, fm.isExecutableFile(atPath: path) { return path }

        var candidates = [
            "~/.local/bin/claude",
            "~/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ].map { NSString(string: $0).expandingTildeInPath }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        candidates += pathDirs.map { "\($0)/claude" }

        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // the prompt is written to stdin because it can contain the whole document, which is too long for an argument.
    // `resume` continues an existing session, `tools` are the claude tools which may be used (e.g. "Read,Grep")
    func run(claudePath: String, prompt: String, systemPrompt: String, model: String?, resume: String?, tools: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)

        var args = [
            "-p",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            // none of the user's settings, hooks, MCP servers or skills, which would make every question slower
            "--tools", tools,
            "--allowedTools", tools,
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--system-prompt", systemPrompt,
        ]
        if let resume = resume {
            args += ["--resume", resume]
        }
        if let model = model {
            args += ["--model", model]
        }
        process.arguments = args
        // sessions are found by the directory they were started in, so it must always be the same
        try? FileManager.default.createDirectory(at: ChatHistory.directory, withIntermediateDirectories: true)
        process.currentDirectoryURL = ChatHistory.directory

        // apps launched from Finder get a minimal PATH, make sure claude can find its dependencies
        var environment = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", NSString(string: "~/.local/bin").expandingTildeInPath]
        environment["PATH"] = (extraPaths + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.stderrData.append(data) }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self?.finished(status: proc.terminationStatus)
            }
        }

        buffer = Data()
        stderrData = Data()
        receivedText = false
        resultError = nil
        sessionId = nil
        self.process = process

        do {
            try process.run()
        } catch {
            onFinish?("Could not run claude: \(error.localizedDescription)", nil)
            return
        }

        // write on a background thread, a large prompt fills the pipe before claude starts reading it
        let promptData = Data(prompt.utf8)
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: promptData)
            try? stdin.fileHandleForWriting.close()
        }
    }

    func cancel() {
        if let process = process, process.isRunning {
            process.terminate()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        let type = json["type"] as? String
        if let id = json["session_id"] as? String {
            sessionId = id
        }

        if type == "stream_event",
           let event = json["event"] as? [String: Any],
           event["type"] as? String == "content_block_delta",
           let delta = event["delta"] as? [String: Any],
           let text = delta["text"] as? String {
            receivedText = true
            onText?(text)
        }
        else if type == "result", json["is_error"] as? Bool == true {
            resultError = (json["result"] as? String) ?? "claude reported an error"
        }
    }

    private func finished(status: Int32) {
        if let error = resultError {
            onFinish?(error, sessionId)
        }
        else if status != 0 && !receivedText {
            let message = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            onFinish?(message.isEmpty ? "claude exited with status \(status)" : message, sessionId)
        }
        else {
            onFinish?(nil, sessionId)
        }
    }
}

// MARK: - markdown

// renders the small subset of markdown that the replies use: headings, lists, **bold**, *italic* and `code`
func renderMarkdown(_ markdown: String) -> NSAttributedString {
    let bodyFont = NSFont.systemFont(ofSize: 14)
    let boldFont = NSFont.boldSystemFont(ofSize: 14)
    let italicFont = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = 4
    paragraph.lineSpacing = 2

    let result = NSMutableAttributedString()
    let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]

    let lines = markdown.components(separatedBy: "\n")
    var inCodeBlock = false
    for (index, rawLine) in lines.enumerated() {
        var line = rawLine
        var lineAttributes = base

        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            inCodeBlock.toggle()
            continue
        }

        if inCodeBlock {
            lineAttributes[.font] = codeFont
            result.append(NSAttributedString(string: line, attributes: lineAttributes))
        }
        else {
            if let match = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                line.removeSubrange(match)
                lineAttributes[.font] = NSFont.boldSystemFont(ofSize: 15)
            }
            if let match = line.range(of: "^(\\s*)[-*]\\s+", options: .regularExpression) {
                let indent = line[match].prefix { $0 == " " }
                line.replaceSubrange(match, with: indent + "• ")
            }
            result.append(renderInline(line, base: lineAttributes, bold: boldFont, italic: italicFont, code: codeFont))
        }

        if index < lines.count - 1 {
            result.append(NSAttributedString(string: "\n", attributes: base))
        }
    }
    return result
}

private func renderInline(_ line: String, base: [NSAttributedString.Key: Any], bold: NSFont, italic: NSFont, code: NSFont) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let pattern = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|`([^`]+)`|(?<![\\w*])\\*(?!\\s)(.+?)(?<!\\s)\\*(?![\\w*])")
    let nsLine = line as NSString
    var position = 0

    for match in pattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
        if match.range.location > position {
            result.append(NSAttributedString(string: nsLine.substring(with: NSRange(location: position, length: match.range.location - position)), attributes: base))
        }
        var attributes = base
        var content = ""
        if match.range(at: 1).location != NSNotFound {
            content = nsLine.substring(with: match.range(at: 1))
            attributes[.font] = bold
        }
        else if match.range(at: 2).location != NSNotFound {
            content = nsLine.substring(with: match.range(at: 2))
            attributes[.font] = code
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor
        }
        else {
            content = nsLine.substring(with: match.range(at: 3))
            attributes[.font] = italic
        }
        result.append(NSAttributedString(string: content, attributes: attributes))
        position = match.range.location + match.range.length
    }
    if position < nsLine.length {
        result.append(NSAttributedString(string: nsLine.substring(from: position), attributes: base))
    }
    return result
}

func truncated(_ text: String, limit: Int) -> String {
    let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
}

// MARK: - window

final class ChatController: NSObject, NSWindowDelegate {
    let settings: Settings
    let documentPath: String
    let checksum: String
    var history: ChatHistory

    var window: NSWindow!
    let textView = NSTextView()
    let scrollView = NSScrollView()
    let statusLabel = NSTextField(labelWithString: "")
    let spinner = NSProgressIndicator()
    let quoteLabel = NSTextField(labelWithString: "")
    let clearQuoteButton = NSButton(title: "✕", target: nil, action: nil)
    let quoteRow = NSStackView()
    // shown instead of sending anything when SioLibrary marked the document sensitive
    let sensitiveRow = NSStackView()
    let sensitiveLabel = NSTextField(wrappingLabelWithString: "")
    let sendAnywayButton = NSButton(title: "Send to Claude anyway", target: nil, action: nil)

    // SioLibrary's marker for sensitive files (stored with the file, like a finder tag)
    var isMarkedSensitive: Bool {
        getxattr(documentPath, "local.siolibrary.sensitive", nil, 0, 0, 0) >= 0
    }
    var isBlocked: Bool { isMarkedSensitive && history.allowSensitive != true }
    let inputField = NSTextField()
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let newChatButton = NSButton(title: "New Chat", target: nil, action: nil)

    let runner = ClaudeRunner()
    var claudePath: String?

    // the document text is extracted in the background when the chat opens
    var documentText: String?
    var pageCount = 0

    // requests which arrived while claude was answering
    var queue: [(label: String, prompt: String, quote: String?, page: Int?)] = []
    var current: (label: String, prompt: String, quote: String?, page: Int?)?
    // whether the current question resumed the saved session (if it fails, the question is asked in a new session)
    var currentResumed = false
    var currentAnswer = ""
    var transcriptPrefix = NSAttributedString()

    // the selected text which the next typed question is about
    var pendingQuote: (text: String, page: Int?)?

    var documentName: String { (documentPath as NSString).lastPathComponent }

    init(settings: Settings, documentPath: String, checksum: String) {
        self.settings = settings
        self.documentPath = documentPath
        self.checksum = checksum
        self.history = ChatHistory.load(checksum: checksum, document: (documentPath as NSString).lastPathComponent)
        super.init()
    }

    func show() {
        let size = NSSize(width: 620, height: 640)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Claude · \(documentName)"
        window.delegate = self
        window.minSize = NSSize(width: 380, height: 320)
        window.isReleasedWhenClosed = false
        position(window: window, size: size)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 6

        quoteLabel.textColor = .secondaryLabelColor
        quoteLabel.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        quoteLabel.lineBreakMode = .byTruncatingTail
        quoteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearQuoteButton.bezelStyle = .inline
        clearQuoteButton.isBordered = false
        clearQuoteButton.target = self
        clearQuoteButton.action = #selector(clearQuote)
        clearQuoteButton.toolTip = "Ask without the selected text"
        quoteRow.setViews([quoteLabel, clearQuoteButton], in: .leading)
        quoteRow.spacing = 4
        quoteRow.isHidden = true

        inputField.placeholderString = "Ask about \(documentName)…"
        inputField.target = self
        inputField.action = #selector(send)
        for (button, selector) in [(sendButton, #selector(send)), (copyButton, #selector(copyAnswer)), (newChatButton, #selector(newChat))] {
            button.target = self
            button.action = selector
            button.bezelStyle = .rounded
        }
        copyButton.toolTip = "Copy the last answer"
        newChatButton.toolTip = "Delete this document's chat history and start over"
        let inputRow = NSStackView(views: [inputField, sendButton, copyButton, newChatButton])
        inputRow.spacing = 8

        sensitiveLabel.stringValue = "🔒 SioLibrary marked this document as sensitive. Asking Claude sends its text to Anthropic, so nothing is sent until you allow it for this document."
        sensitiveLabel.font = NSFont.systemFont(ofSize: 12)
        sensitiveLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sendAnywayButton.bezelStyle = .rounded
        sendAnywayButton.target = self
        sendAnywayButton.action = #selector(allowSensitive)
        sensitiveRow.setViews([sensitiveLabel, sendAnywayButton], in: .leading)
        sensitiveRow.spacing = 8
        sensitiveRow.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        sensitiveRow.wantsLayer = true
        sensitiveRow.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
        sensitiveRow.layer?.cornerRadius = 6
        sensitiveRow.isHidden = !isBlocked

        let stack = NSStackView(views: [sensitiveRow, scrollView, statusRow, quoteRow, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            sensitiveRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            quoteRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        runner.onText = { [weak self] text in self?.appendAnswer(text) }
        runner.onFinish = { [weak self] error, sessionId in self?.finishAnswer(error: error, sessionId: sessionId) }

        textView.textStorage?.setAttributedString(renderHistory())
        textView.scrollToEndOfDocument(nil)

        claudePath = ClaudeRunner.findClaude(settings: settings)
        if claudePath == nil {
            showError("Could not find the `claude` command line tool. Install Claude Code, or set claude_path in ~/.config/sioyek/sioyek-ai.conf.")
        }

        bringToFront()

        statusLabel.stringValue = "Reading \(documentName)…"
        spinner.startAnimation(nil)
        let path = documentPath
        DispatchQueue.global().async {
            let extracted = extractDocumentText(path: path)
            DispatchQueue.main.async {
                self.documentText = extracted.text
                self.pageCount = extracted.pageCount
                self.spinner.stopAnimation(nil)
                self.statusLabel.stringValue = extracted.text.isEmpty ? "Could not read the text of this document" : ""
                self.runNext()
            }
        }
    }

    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(inputField)
    }

    // place the window next to the mouse (which is where the user right clicked), kept inside the screen
    private func position(window: NSWindow, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - size.height / 2)
        if origin.x + size.width > visible.maxX { origin.x = mouse.x - size.width - 16 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(origin)
    }

    // MARK: requests

    func handle(_ request: Request) {
        bringToFront()
        if let (label, prompt) = instruction(for: request, settings: settings) {
            enqueue(label: label, prompt: prompt, quote: request.text.isEmpty ? nil : request.text, page: request.page)
        }
        else if !request.text.isEmpty {
            // "ask" (or an action which needs a selection): the next typed question is about the selected text
            pendingQuote = (request.text, request.page)
            quoteLabel.stringValue = "Asking about: “\(truncated(request.text, limit: 300))”"
            quoteRow.isHidden = false
            inputField.placeholderString = "Ask about the selected text…"
        }
    }

    @objc func clearQuote() {
        pendingQuote = nil
        quoteRow.isHidden = true
        inputField.placeholderString = "Ask about \(documentName)…"
    }

    @objc func send() {
        let question = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.isEmpty { return }
        inputField.stringValue = ""
        enqueue(label: question, prompt: question, quote: pendingQuote?.text, page: pendingQuote?.page)
        clearQuote()
    }

    private func enqueue(label: String, prompt: String, quote: String?, page: Int?) {
        queue.append((label, prompt, quote, page))
        runNext()
    }

    @objc func allowSensitive() {
        history.allowSensitive = true
        history.save(checksum: checksum)
        sensitiveRow.isHidden = true
        statusLabel.stringValue = ""
        runNext()
    }

    private func runNext() {
        guard current == nil, documentText != nil, claudePath != nil, !queue.isEmpty else { return }
        // checked for every question, since the document may have been marked while the chat was open
        if isBlocked {
            sensitiveRow.isHidden = false
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Waiting: \(queue.count) question\(queue.count == 1 ? "" : "s") not sent (sensitive document)"
            return
        }
        let request = queue.removeFirst()
        current = request
        currentAnswer = ""

        // keep the previous answers visible above the new one
        let transcript = NSMutableAttributedString(attributedString: textView.textStorage ?? NSAttributedString())
        if transcript.length > 0 {
            transcript.append(NSAttributedString(string: "\n\n"))
        }
        transcript.append(renderQuestion(request.label, quote: request.quote, page: request.page))
        transcriptPrefix = transcript
        textView.textStorage?.setAttributedString(transcript)
        textView.scrollToEndOfDocument(nil)

        spinner.startAnimation(nil)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Thinking…"
        statusLabel.toolTip = nil
        ask(request)
    }

    var isDocumentInline: Bool { (documentText ?? "").count <= settings.maxInlineChars }

    // the text file which claude searches when the document is too long to include
    var documentTextFile: URL { ChatHistory.directory.appendingPathComponent("\(checksum).txt") }

    private func ask(_ request: (label: String, prompt: String, quote: String?, page: Int?)) {
        guard let claudePath = claudePath else { return }
        var tools = ""
        if !isDocumentInline {
            try? FileManager.default.createDirectory(at: ChatHistory.directory, withIntermediateDirectories: true)
            try? (documentText ?? "").write(to: documentTextFile, atomically: true, encoding: .utf8)
            tools = "Read,Grep"
        }

        currentResumed = history.sessionId != nil
        let prompt = currentResumed
            ? questionPrompt(request.prompt, quote: request.quote, page: request.page)
            : sessionStartPrompt() + questionPrompt(request.prompt, quote: request.quote, page: request.page)
        runner.run(claudePath: claudePath, prompt: prompt, systemPrompt: systemPrompt, model: settings.model,
                   resume: history.sessionId, tools: tools)
    }

    private var systemPrompt: String {
        var prompt = """
        You are a reading assistant inside the Sioyek PDF reader. The user is reading the document given at the start \
        of the conversation and talks with you about it in one ongoing conversation. Questions may come with text the user \
        selected in the document (<selected_text>). Answer directly without preamble, be concise, cite page numbers \
        when pointing to other parts of the document, and use only light Markdown (bold, italics, bullet lists, \
        inline code). Do not use tables or LaTeX.
        """
        if let language = settings.replyLanguage {
            prompt += " Reply in \(language)."
        }
        else {
            prompt += " Reply in the language of the user's question, or of the selected text if there is no typed question."
        }
        return prompt
    }

    // the first message of a session: the document, and the saved conversation if the previous session was lost
    private func sessionStartPrompt() -> String {
        var prompt: String
        if isDocumentInline {
            prompt = "<document name=\"\(documentName)\" pages=\"\(pageCount)\">\n\(documentText ?? "")</document>\n"
        }
        else {
            prompt = "The document \"\(documentName)\" (\(pageCount) pages) is too long to include here. Its text is in the file " +
                "\(documentTextFile.path), where each page starts with a [page N] line. Use Grep and Read to look up the " +
                "parts you need instead of reading the whole file.\n"
        }

        let recent = history.turns.suffix(30)
        if !recent.isEmpty {
            prompt += "\n<conversation_so_far>\n"
            for turn in recent {
                prompt += "<user>\n"
                if let quote = turn.quote {
                    prompt += selectedTextTag(quote, page: turn.page)
                }
                prompt += "\(turn.question)\n</user>\n<assistant>\n\(turn.answer)\n</assistant>\n"
            }
            prompt += "</conversation_so_far>\n"
        }
        return prompt + "\n"
    }

    private func questionPrompt(_ question: String, quote: String?, page: Int?) -> String {
        var prompt = ""
        if let quote = quote {
            prompt += selectedTextTag(quote, page: page)
        }
        return prompt + question
    }

    private func selectedTextTag(_ text: String, page: Int?) -> String {
        let pageAttribute = page.map { " page=\"\($0 + 1)\"" } ?? ""
        return "<selected_text\(pageAttribute)>\n\(text)\n</selected_text>\n"
    }

    private func appendAnswer(_ text: String) {
        if currentAnswer.isEmpty {
            statusLabel.stringValue = "Writing…"
        }
        currentAnswer += text
        let rendered = NSMutableAttributedString(attributedString: transcriptPrefix)
        rendered.append(renderMarkdown(currentAnswer))
        textView.textStorage?.setAttributedString(rendered)
        textView.scrollToEndOfDocument(nil)
    }

    private func finishAnswer(error: String?, sessionId: String?) {
        guard let request = current else { return }

        if error != nil && currentResumed && currentAnswer.isEmpty {
            // the saved session is gone (claude code deletes old sessions), ask again in a new session which starts
            // with the document and the saved conversation
            history.sessionId = nil
            ask(request)
            return
        }

        spinner.stopAnimation(nil)
        current = nil
        if let error = error {
            showError(error)
        }
        else {
            history.sessionId = sessionId ?? history.sessionId
            history.turns.append(Turn(question: request.label, quote: request.quote, page: request.page,
                                      answer: currentAnswer, date: Date()))
            history.save(checksum: checksum)
            statusLabel.stringValue = ""
        }
        runNext()
    }

    // MARK: rendering

    private func renderQuestion(_ question: String, quote: String?, page: Int?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: question + "\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if let quote = quote {
            let pageString = page.map { "  (p. \($0 + 1))" } ?? ""
            result.append(NSAttributedString(string: "“\(truncated(quote, limit: 400))”\(pageString)\n", attributes: [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        return result
    }

    private func renderHistory() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for turn in history.turns {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(renderQuestion(turn.question, quote: turn.quote, page: turn.page))
            result.append(renderMarkdown(turn.answer))
        }
        return result
    }

    private func showError(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message.components(separatedBy: .newlines).first ?? message
        statusLabel.toolTip = message
    }

    // MARK: buttons

    @objc func copyAnswer() {
        let answer = history.turns.last?.answer ?? currentAnswer
        if answer.isEmpty { return }
        // rich text for apps like Apple Notes, markdown for plain text editors. the colors are dropped because they
        // are resolved for the current appearance (e.g. white text in dark mode)
        let rendered = NSMutableAttributedString(attributedString: renderMarkdown(answer))
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.removeAttribute(.foregroundColor, range: fullRange)
        rendered.removeAttribute(.backgroundColor, range: fullRange)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let rtf = rendered.rtf(from: fullRange, documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(answer, forType: .string)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Copied"
    }

    @objc func newChat() {
        let alert = NSAlert()
        alert.messageText = "Start a new chat?"
        alert.informativeText = "The chat history of \(documentName) will be deleted."
        alert.addButton(withTitle: "New Chat")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.runner.cancel()
            self.queue.removeAll()
            self.current = nil
            self.history.turns.removeAll()
            self.history.sessionId = nil
            self.history.save(checksum: self.checksum)
            self.textView.textStorage?.setAttributedString(NSAttributedString())
            self.spinner.stopAnimation(nil)
            self.statusLabel.stringValue = ""
        }
    }

    func windowWillClose(_ notification: Notification) {
        runner.cancel()
        NSApp.terminate(nil)
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ChatController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: sioyek-ai <pdf path> <document checksum> [action] [selected text] [page]\n".utf8))
            NSApp.terminate(nil)
            return
        }

        let controller = ChatController(settings: Settings.load(), documentPath: args[1], checksum: args[2])
        self.controller = controller
        controller.show()

        if args.count > 3 {
            controller.handle(Request(action: args[3], text: args.count > 4 ? args[4] : "", page: args.count > 5 ? Int(args[5]) : nil))
        }

        // requests from sioyek, one json object per line
        if isatty(STDIN_FILENO) == 0 {
            DispatchQueue.global().async {
                while let line = readLine() {
                    if let request = Request.parse(line) {
                        DispatchQueue.main.async { controller.handle(request) }
                    }
                }
            }
        }

        // close with escape
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && NSApp.keyWindow?.attachedSheet == nil {
                NSApp.keyWindow?.performClose(nil)
                return nil
            }
            return event
        }
    }

    // without a main menu the standard shortcuts (copy, paste, select all, close, quit) don't work
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// no dock icon, the chat belongs to sioyek
app.setActivationPolicy(.accessory)
app.run()
