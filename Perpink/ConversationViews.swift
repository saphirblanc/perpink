import SwiftUI

#if os(macOS)
private let bubbleCornerRadius: CGFloat = 16
private let composerCornerRadius: CGFloat = 20
/// Room left beside a question: a Mac window is wide enough that a bubble
/// running the full column stops reading as one.
private let bubbleLeadingInset: CGFloat = 96
private let thumbnailSize: CGFloat = 56
#else
/// Corner radius of the user message bubble.
private let bubbleCornerRadius: CGFloat = 18

/// Corner radius of the floating composer pill. Large enough to read as a
/// capsule at single-line height, echoing the keyboard's own rounded corners.
private let composerCornerRadius: CGFloat = 26
private let bubbleLeadingInset: CGFloat = 48
private let thumbnailSize: CGFloat = 64
#endif

/// The widest the thread and composer grow on the Mac: a column of text past
/// about 70 characters is hard to read, which a window easily exceeds.
let readableColumnWidth: CGFloat = 720

// MARK: - Thread

/// The conversation itself, newest at the bottom: what both the iPhone screen
/// and the Mac window's detail column show.
struct MessageList<Empty: View>: View {
    let viewModel: ChatViewModel
    let settings: SettingsStore
    /// How wide the thread may grow.
    var maxWidth: CGFloat = .infinity
    @ViewBuilder var emptyState: () -> Empty

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            activity: message.isStreaming ? viewModel.activity : nil,
                            onVerify: canVerify(message)
                                ? { viewModel.verify(settings: settings) }
                                : nil
                        )
                        .padding(.horizontal)
                        .id(message.id)
                    }
                    if let approval = viewModel.approval {
                        ApprovalCard(request: approval) { viewModel.answer($0) }
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
                .readingFont(.body)
                .environment(\.hermesClient, settings.isConfigured ? settings.client : nil)
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
            }
            .anchoredToNewest()
            // `defaultScrollAnchor` only positions the view on first layout;
            // swapping the whole thread in (loading an older chat) leaves it
            // scrolled up over blank space, so jump to the newest message.
            .onChange(of: viewModel.messages.first?.id) {
                if let lastID = viewModel.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .overlay {
                if viewModel.isLoadingThread {
                    ProgressView()
                } else if viewModel.messages.isEmpty {
                    emptyState()
                }
            }
        }
    }

    /// The newest answer is the only one that can be checked: the follow-up
    /// asks Hermes about the answer it just gave, which is that one.
    private func canVerify(_ message: ChatMessage) -> Bool {
        viewModel.canVerify && message.id == viewModel.messages.last?.id
    }
}

// MARK: - Composer

/// Floating pill that hovers above the keyboard, leaving the keyboard's
/// own rounded corners visible instead of covering them with a flush bar.
struct Composer<AttachMenu: View>: View {
    @Bindable var viewModel: ChatViewModel
    let settings: SettingsStore
    var focused: FocusState<Bool>.Binding
    /// The ways in for a photo, which differ by platform.
    @ViewBuilder var attachMenu: () -> AttachMenu

    // Bumped on every send: recreating the TextField is the only reliable
    // way to drop the keyboard's pending autocorrect text with the message.
    @State private var generation = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let quote = viewModel.quote {
                quoteBar(quote)
            }
            if !viewModel.attachments.isEmpty || viewModel.isPreparingPhotos {
                attachmentStrip
            }
            row
        }
        .animation(.snappy, value: viewModel.quote)
        .sensoryFeedback(.selection, trigger: viewModel.quote) { before, after in
            before == nil && after != nil
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: composerCornerRadius))
        #if os(macOS)
        // No keyboard rises to say where typing goes, so the pill says it.
        .overlay {
            RoundedRectangle(cornerRadius: composerCornerRadius)
                .strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.7) : .white.opacity(0.1))
        }
        .background {
            if focused.wrappedValue {
                RoundedRectangle(cornerRadius: composerCornerRadius + 3)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 3)
                    .padding(-1.5)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .overlay(alignment: .bottom) {
            Text(viewModel.isSending ? "⌘. to stop" : "⏎ to send · ⇧⏎ new line")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .offset(y: 18)
        }
        .frame(maxWidth: readableColumnWidth)
        .padding(.horizontal, 24)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        #else
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        #endif
    }

    /// The copied passage the next question will be about: a chip no wider
    /// than its own text, sitting above the field the way an attachment does.
    /// Tapping it opens the keyboard, which is what it is there for.
    private func quoteBar(_ quote: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .readingFont(.caption2)
                .foregroundStyle(.secondary)
            Text(Self.condensed(quote))
                .readingFont(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                viewModel.quote = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove quote")
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        .padding(.top, 2)
        .padding(.leading, 2)
        .transition(.scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity))
    }

    /// A copied passage on one flowing line: a selection comes with the
    /// answer's own line breaks, which read as ragged gaps in a two-line card.
    private static func condensed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The photos waiting to go out, each with a button to take it back.
    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.attachments.enumerated()), id: \.offset) { index, data in
                    if let image = PlatformImage(data: data) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: thumbnailSize, height: thumbnailSize)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    viewModel.removeAttachment(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                        .font(.system(size: 20))
                                }
                                .composerButton()
                                .padding(3)
                                .accessibilityLabel("Remove photo")
                            }
                    }
                }
                if viewModel.isPreparingPhotos {
                    ProgressView()
                        .frame(width: thumbnailSize, height: thumbnailSize)
                }
            }
            .padding(.top, 6)
            .padding(.leading, 4)
        }
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                attachMenu()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: iconSize(28)))
                    .foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            // The Mac draws a menu's label as a small popup control, shrinking
            // the symbol; the plain button style hands the label back as is.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            #endif
            .disabled(viewModel.remainingPhotoSlots == 0 || viewModel.isSending)
            .accessibilityLabel("Add photo")

            TextField(
                viewModel.quote == nil ? String(localized: "Message Hermes…") : String(localized: "Ask about this passage…"),
                text: $viewModel.input,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .readingFont(.body)
                .lineLimit(1...6)
                .padding(.leading, 8)
                // Matches the container's vertical padding so the text sits
                // at the optical center of the pill (12pt top and bottom).
                .padding(.vertical, 6)
                .focused(focused)
                .id(generation)
                #if os(macOS)
                .onSubmit(send)
                // Return sends, as in Messages; Shift-Return starts a new line.
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        viewModel.input.append("\n")
                    } else {
                        send()
                    }
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard viewModel.quote != nil else { return .ignored }
                    viewModel.quote = nil
                    return .handled
                }
                #endif

            Button {
                if viewModel.isSending {
                    viewModel.stop()
                } else {
                    send()
                }
            } label: {
                Image(systemName: viewModel.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: iconSize(32)))
                    #if os(macOS)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .opacity(!viewModel.isSending && !viewModel.canSend ? 0.4 : 1)
                    #endif
            }
            .composerButton()
            .disabled(!viewModel.isSending && !viewModel.canSend)
            #if os(iOS)
            // A hardware keyboard's shortcuts; the Mac has them in its menus.
            .keyboardShortcut(viewModel.isSending ? "." : .return, modifiers: .command)
            #endif
        }
    }

    /// The composer's symbols are sized for a finger on iOS and for a
    /// pointer on the Mac.
    private func iconSize(_ touch: CGFloat) -> CGFloat {
        #if os(macOS)
        touch - 4
        #else
        touch
        #endif
    }

    private func send() {
        guard viewModel.canSend, !viewModel.isSending else { return }
        let wasFocused = focused.wrappedValue
        viewModel.send(settings: settings)
        generation += 1
        if wasFocused {
            Task { @MainActor in focused.wrappedValue = true }
        }
    }
}

private extension View {
    /// Opens a thread on its newest message and keeps it there as an answer
    /// streams in.
    ///
    /// On the Mac the anchor's third role — pushing a thread shorter than the
    /// window down to the bottom — makes AppKit lighten the whole scroll view
    /// whenever the pointer is over it, so a short thread starts at the top
    /// there instead, as in other Mac chat apps.
    @ViewBuilder
    func anchoredToNewest() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            defaultScrollAnchor(.bottom)
        }
        #else
        defaultScrollAnchor(.bottom)
        #endif
    }

    /// The composer's icon buttons: bare symbols, as iOS draws them by
    /// default, rather than the Mac's push-button bezel.
    func composerButton() -> some View {
        #if os(macOS)
        buttonStyle(.borderless)
        #else
        self
        #endif
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    /// What Hermes is doing, shown while the answer is still arriving.
    var activity: String? = nil
    /// Set on the newest answer: sends it back to be checked against the web.
    var onVerify: (() -> Void)? = nil

    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    sentPhotos
                }
                if message.missingPhotos > 0 {
                    Label(
                        message.missingPhotos == 1 ? String(localized: "Photo") : String(localized: "\(message.missingPhotos) photos"),
                        systemImage: "photo"
                    )
                    .readingFont(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.raisedBackground, in: RoundedRectangle(cornerRadius: bubbleCornerRadius))
                }
                if !message.text.isEmpty {
                    askedQuestion
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: bubbleCornerRadius))
                        .foregroundStyle(.white)
                }
            }
            .padding(.leading, bubbleLeadingInset)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if message.isError {
                    Label(message.text, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else if message.text.isEmpty && message.isStreaming {
                    progress(activity ?? String(localized: "Thinking…"))
                } else {
                    MarkdownView(text: message.text)
                    if message.isStreaming {
                        if let activity {
                            progress(activity)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                if canCopy {
                    actions
                }
            }
        }
    }

    /// What was asked, with the passage a follow-up quoted set off above it.
    @ViewBuilder
    private var askedQuestion: some View {
        let (passage, question) = message.quoted
        if let passage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.5))
                        .frame(width: 3)
                    Text(passage)
                        .readingFont(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                }
                if !question.isEmpty {
                    Text(question)
                }
            }
        } else {
            Text(question)
        }
    }

    /// The photos a question went out with, right-aligned above its text.
    private var sentPhotos: some View {
        HStack(spacing: 6) {
            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                if let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: message.images.count == 1 ? 200 : 96,
                            height: message.images.count == 1 ? 200 : 96
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .readingFont(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// There is nothing to copy from an error or from a reply that is still arriving.
    private var canCopy: Bool {
        !message.isError && !message.isStreaming && !message.text.isEmpty
    }

    private var actions: some View {
        HStack(spacing: 8) {
            copyControl
            if let onVerify {
                Button(action: onVerify) {
                    ActionLabel(title: "Verify", systemImage: "checkmark.shield")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        #if os(macOS)
        .controlSize(.small)
        #endif
    }

    /// Copies the answer's Markdown source rather than the rendered text, so
    /// headings, lists and tables survive the trip into another app.
    private var copyControl: some View {
        Button {
            Clipboard.copy(message.text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            ActionLabel(title: copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .animation(.default, value: copied)
    }
}

/// A label for the buttons under an answer. Their symbols differ in height —
/// `doc.on.doc` stands taller than `checkmark.shield` or `checkmark` — and a
/// bordered button is as tall as its label, so each icon sits in the box of
/// the tallest one: the capsules match, and Copy doesn't shrink as it turns
/// into Copied.
private struct ActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "doc.on.doc")
                .hidden()
                .overlay { Image(systemName: systemImage) }
        }
        .font(.subheadline)
    }
}

// MARK: - Approval

/// Hermes asking before it runs something, with the choices it offered.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let onAnswer: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hermes wants to run", systemImage: "hand.raised")
                .readingFont(.subheadline, weight: .semibold)
            if let command = request.command, !command.isEmpty {
                Text(command)
                    .readingFont(.callout, design: .monospaced)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.raisedBackground2, in: RoundedRectangle(cornerRadius: 8))
            }
            if let description = request.description, !description.isEmpty {
                Text(description)
                    .readingFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(request.offeredChoices, id: \.self) { choice in
                    Button(ApprovalRequest.title(for: choice)) {
                        onAnswer(choice)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(choice == "deny" ? .red : .accentColor)
                    .font(.subheadline)
                }
            }
        }
        .padding(12)
        .background(Color.raisedBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
