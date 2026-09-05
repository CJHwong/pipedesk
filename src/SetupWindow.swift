import AppKit

final class SetupWindowController: NSWindowController {
    private let onSave: (PipeProfile) throws -> Void
    private let modeControl = NSSegmentedControl(labels: ["Connect", "Share"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let nameField = NSTextField(string: "")
    private let ticketField = NSTextField(string: "")
    private let portField = NSTextField(string: "2222")
    private let ticketRow = NSStackView()
    private let portLabel = NSTextField(labelWithString: "Local port")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save Connection", target: nil, action: nil)
    private let binaryLabel = NSTextField(wrappingLabelWithString: "")
    private let installButton = NSButton(title: "Install with Homebrew…", target: nil, action: nil)

    init(onSave: @escaping (PipeProfile) throws -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PipeDesk Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildWindow(window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshBinaryStatus()
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(sender)
    }

    private func buildWindow(_ window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        guard let content = window.contentView else { return }
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        let title = NSTextField(labelWithString: "A simple path between your devices.")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.setContentHuggingPriority(.required, for: .vertical)
        root.addArrangedSubview(title)
        let subtitle = NSTextField(wrappingLabelWithString:
            "Connect with a Dumbpipe ticket, or share a service from this Mac.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.setContentHuggingPriority(.required, for: .vertical)
        root.addArrangedSubview(subtitle)
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        let profileTab = NSTabViewItem(identifier: "profile")
        profileTab.label = "Add a Pipe"
        profileTab.view = makeProfileView()
        let remoteTab = NSTabViewItem(identifier: "remote")
        remoteTab.label = "Remote Setup"
        remoteTab.view = makeRemoteView()
        tabs.addTabViewItem(profileTab)
        tabs.addTabViewItem(remoteTab)
        root.addArrangedSubview(tabs)
        tabs.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        root.setHuggingPriority(.defaultLow, for: .vertical)
    }

    private func makeProfileView() -> NSView {
        let stack = makeStack()
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        stack.addArrangedSubview(modeControl)
        nameField.placeholderString = "For example: Home server"
        stack.addArrangedSubview(fieldRow(label: "Name", field: nameField))
        ticketField.placeholderString = "Paste the ticket from the other device"
        ticketField.lineBreakMode = .byTruncatingMiddle
        ticketField.usesSingleLineMode = true
        ticketRow.orientation = .vertical
        ticketRow.alignment = .leading
        ticketRow.spacing = 5
        ticketRow.addArrangedSubview(NSTextField(labelWithString: "Ticket"))
        ticketRow.addArrangedSubview(ticketField)
        ticketField.widthAnchor.constraint(equalTo: ticketRow.widthAnchor).isActive = true
        stack.addArrangedSubview(ticketRow)
        let portRow = NSStackView(views: [portLabel, portField])
        portRow.orientation = .vertical
        portRow.alignment = .leading
        portRow.spacing = 5
        portField.widthAnchor.constraint(equalToConstant: 120).isActive = true
        stack.addArrangedSubview(portRow)
        detailLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detailLabel)
        binaryLabel.font = .systemFont(ofSize: 11)
        binaryLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(binaryLabel)
        installButton.bezelStyle = .rounded
        installButton.target = self
        installButton.action = #selector(installDumbpipe)
        stack.addArrangedSubview(installButton)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(errorLabel)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(saveProfile)
        stack.addArrangedSubview(saveButton)
        for view in [ticketRow, detailLabel, binaryLabel, errorLabel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        pinContentHeight(stack)
        modeChanged()
        return stack
    }

    private func makeStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        return stack
    }

    private func pinContentHeight(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
    }

    private func fieldRow(label: String, field: NSTextField) -> NSStackView {
        let row = NSStackView(views: [NSTextField(labelWithString: label), field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        row.setContentHuggingPriority(.required, for: .vertical)
        field.widthAnchor.constraint(equalToConstant: 490).isActive = true
        return row
    }

    private func makeRemoteView() -> NSView {
        let stack = makeStack()
        let intro = NSTextField(wrappingLabelWithString:
            "Run these steps on the remote machine. Keep its shell service authenticated.")
        intro.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(intro)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let instructions = NSTextView(frame: NSRect(x: 0, y: 0, width: 490, height: 330))
        instructions.isEditable = false
        instructions.isSelectable = true
        instructions.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        instructions.textContainerInset = NSSize(width: 12, height: 12)
        instructions.string = Self.remoteInstructions
        instructions.isVerticallyResizable = true
        instructions.isHorizontallyResizable = false
        instructions.autoresizingMask = [.width]
        instructions.textContainer?.widthTracksTextView = true
        scroll.documentView = instructions
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 330).isActive = true
        let copy = NSButton(title: "Copy Instructions", target: self, action: #selector(copyRemoteInstructions))
        copy.bezelStyle = .rounded
        stack.addArrangedSubview(copy)
        pinContentHeight(stack)
        return stack
    }

    @objc private func modeChanged() {
        let sharing = modeControl.selectedSegment == 1
        ticketRow.isHidden = sharing
        portLabel.stringValue = sharing ? "Local service port" : "Local port"
        saveButton.title = sharing ? "Save Share" : "Save Connection"
        detailLabel.stringValue = sharing
            ? "Share forwards ticket holders to 127.0.0.1 on this Mac. Use an authenticated service, such as Secure Shell (SSH)."
            : "Connect listens on 127.0.0.1 on this Mac. Use this local port to reach the service at the other end."
        errorLabel.stringValue = ""
    }

    private var homebrewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func refreshBinaryStatus() {
        let installed = DumbpipeBinary.locate() != nil
        installButton.isHidden = installed
        installButton.isEnabled = homebrewPath != nil
        if installed {
            binaryLabel.stringValue = "Dumbpipe is installed. Save a profile, then start it from the menu."
            return
        }
        binaryLabel.stringValue = homebrewPath != nil
            ? "Install opens Terminal and runs brew install dumbpipe. You can save a profile before installation."
            : "Install Homebrew separately, then run brew install dumbpipe.\nOr, with Rust installed: cargo install dumbpipe"
    }

    @objc private func installDumbpipe() {
        guard let executable = homebrewPath else {
            refreshBinaryStatus()
            return
        }
        // The executable comes only from the two fixed paths above.
        let source = """
        tell application "Terminal"
            activate
            do script "'\(executable)' install dumbpipe"
        end tell
        """
        guard let script = NSAppleScript(source: source) else {
            errorLabel.stringValue = "Could not prepare the Terminal command. Run brew install dumbpipe in Terminal."
            return
        }
        var failure: NSDictionary?
        script.executeAndReturnError(&failure)
        if let failure {
            let message = failure["NSAppleScriptErrorMessage"] as? String ?? "Terminal did not open."
            errorLabel.stringValue = "\(message) Run brew install dumbpipe in Terminal."
            return
        }
        errorLabel.stringValue = ""
        binaryLabel.stringValue = "Complete installation in Terminal, then reopen PipeDesk Setup to check it."
    }

    @objc private func saveProfile() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ticket = ticketField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorLabel.stringValue = "Enter a name for this pipe."
            return
        }
        guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            errorLabel.stringValue = "Enter a port from 1 to 65535."
            return
        }
        let mode: PipeMode = modeControl.selectedSegment == 1 ? .share : .connect
        guard mode == .share || !ticket.isEmpty else {
            errorLabel.stringValue = "Paste the ticket from the other device."
            return
        }
        do {
            try onSave(PipeProfile(id: UUID(), name: name, mode: mode, ticket: mode == .connect ? ticket : "", port: port))
            nameField.stringValue = ""
            ticketField.stringValue = ""
            close()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func copyRemoteInstructions() {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(Self.remoteInstructions, forType: .string) else {
            let alert = NSAlert()
            alert.messageText = "Could not copy instructions"
            alert.informativeText = "Select the instructions and copy them manually."
            alert.runModal()
            return
        }
    }

    private static let remoteInstructions = """
    1. Enable Secure Shell (SSH) on the remote machine.
       On macOS, enable Remote Login in System Settings.
       On Linux, install and start the OpenSSH server.
       Check that you can sign in with your SSH key.

    2. Install Dumbpipe on the remote machine.
       With Homebrew installed, run:

       brew install dumbpipe

       Or, with Rust installed:

       cargo install dumbpipe

    3. Create a private identity once:

       umask 077
       mkdir -p ~/.config/pipedesk
       if [ ! -f ~/.config/pipedesk/remote.key ]; then
         openssl rand -hex 32 > ~/.config/pipedesk/remote.key
       fi
       chmod 600 ~/.config/pipedesk/remote.key

       Keep this file private. Retain it across restarts.
       Run this command each time you start the listener:

       IROH_SECRET="$(cat ~/.config/pipedesk/remote.key)" \\
         dumbpipe listen-tcp --host 127.0.0.1:22

       Keep the process running. In another terminal,
       create a stable ticket with the same identity:

       IROH_SECRET="$(cat ~/.config/pipedesk/remote.key)" \\
         dumbpipe generate-ticket

       Copy the ticket from that command.

    4. In PipeDesk, choose Connect.
       Paste the ticket. Set the local port to 2222.
       Save the connection, then start it from the menu.

    5. On this Mac, sign in with your remote username:

       ssh -p 2222 YOUR_REMOTE_USER@127.0.0.1

       Check the remote host fingerprint before you accept it.

    Reuse the saved secret for the same listener identity.
    Use the stable ticket across network changes.
    Never share the secret. Ticket holders can reach the service.
    The remote machine must remain awake and connected.
    Use launchd on macOS or systemd on Linux for startup.
    PipeDesk does not install a remote startup service.
    """
}
