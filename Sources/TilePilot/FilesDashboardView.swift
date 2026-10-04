import AppKit
import SwiftUI

struct FilesDashboardView: View {
    @EnvironmentObject private var model: AppModel
    let showNavigationContainer: Bool
    @State private var searchText = ""
    @State private var editorJumpLine: Int?
    @State private var showResetDefaultsConfirm = false

    init(showNavigationContainer: Bool = true) {
        self.showNavigationContainer = showNavigationContainer
    }

    private var filteredFiles: [EditableConfigFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.editableFiles }
        return model.editableFiles.filter { file in
            file.displayName.lowercased().contains(query) || file.path.lowercased().contains(query)
        }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { model.editableFileDraft },
            set: { model.updateEditableFileDraft($0) }
        )
    }

    var body: some View {
        Group {
            if showNavigationContainer {
                NavigationStack {
                    dashboardBody
                        .navigationTitle("TilePilot")
                }
            } else {
                dashboardBody
            }
        }
    }

    private var dashboardBody: some View {
        HSplitView {
            leftPane
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)

            rightPane
                .frame(minWidth: 500)
        }
        .task {
            await syncFilesTabState()
        }
        .onAppear {
            Task { await syncFilesTabState() }
        }
        .onChange(of: model.requestedFileEditorTarget) { _ in
            Task {
                await syncFilesTabState()
            }
        }
        .onChange(of: model.selectedEditableFilePath) { _ in
            if let line = model.consumeEditableFileJumpTargetLine() {
                editorJumpLine = line
            } else {
                editorJumpLine = nil
            }
        }
        .alert("Restore All Default Settings?", isPresented: $showResetDefaultsConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) {
                model.resetToReleaseDefaults()
            }
        } message: {
            Text("This restores TilePilot app settings and the TilePilot-managed sections of skhdrc and yabairc to their default values. Any non-managed lines stay unchanged.")
        }
    }

    private var leftPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Config & Script Files", systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    Button("Restore All Default Settings") {
                        showResetDefaultsConfirm = true
                    }
                    .font(.caption)
                    Button(model.isRefreshingEditableFiles ? "Reloading..." : "Reload") {
                        Task {
                            await model.refreshEditableFiles()
                            await syncFilesTabState(allowRefresh: false)
                        }
                    }
                    .font(.caption)
                    .disabled(model.isRefreshingEditableFiles)
                    if model.isRefreshingEditableFiles || model.isLoadingEditableFile {
                        ProgressView().controlSize(.small)
                    }
                }
                TextField("Search files", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Text("Includes `yabairc`, `skhdrc`, and scripts referenced by your shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filteredFiles) { file in
                        fileRow(file)
                    }

                    if filteredFiles.isEmpty {
                        EmptyStateView(
                            title: "No files found",
                            systemImage: "doc.text.magnifyingglass",
                            message: "Reload Shortcuts or adjust your search."
                        )
                        .frame(minHeight: 180)
                    }
                }
                .padding(10)
            }
        }
    }

    private func fileRow(_ file: EditableConfigFile) -> some View {
        let isSelected = model.selectedEditableFilePath == file.path
        let isDirty = isSelected && model.isEditableFileDraftDirty

        return Button {
            Task { await model.openEditableFile(path: file.path, line: nil) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon(for: file.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(file.displayName)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        kindBadge(file.kind)
                        if isDirty {
                            Text("●")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !file.exists {
                            Text("missing")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(file.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private var rightPane: some View {
        VStack(spacing: 0) {
            if let selected = model.selectedEditableFile {
                fileHeader(selected)
                Divider()

                VStack(spacing: 0) {
                    if let line = editorJumpLine {
                        HStack {
                            Text("Editing at line \(line).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.04))
                    }

                    JumpingCodeEditorView(
                        text: draftBinding,
                        jumpTargetLine: $editorJumpLine
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                backupsSection
                Divider()
                filesBottomBar(selected)
            } else {
                EmptyStateView(
                    title: "Select a file",
                    systemImage: "doc.plaintext",
                    message: "Pick `yabairc`, `skhdrc`, or a discovered script to edit it here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fileHeader(_ file: EditableConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(file.displayName, systemImage: icon(for: file.kind))
                    .font(.headline)
                kindBadge(file.kind)
                if model.isEditableFileDraftDirty {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if model.isSavingEditableFile || model.isRestoringEditableFile {
                    ProgressView().controlSize(.small)
                }
            }
            Text(file.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 10) {
                Text("\(model.editableFileLineCount) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !file.exists {
                    Text(file.kind == .yabairc || file.kind == .skhdrc ? "Missing file (will be created on save)" : "Missing file")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backupsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Backups", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.selectedEditableFileBackups.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.selectedEditableFileBackups.isEmpty {
                Text("Backups appear here after you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.selectedEditableFileBackups.prefix(3))) { backup in
                    HStack {
                        Text(URL(fileURLWithPath: backup.path).lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filesBottomBar(_ file: EditableConfigFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(model.isSavingEditableFile ? "Saving..." : "Save") {
                    model.saveSelectedEditableFile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSavingEditableFile || model.isRestoringEditableFile)

                Button("Revert") {
                    model.revertSelectedEditableFileDraft()
                }
                .disabled(!model.isEditableFileDraftDirty || model.isSavingEditableFile || model.isRestoringEditableFile)

                Menu("Restore Backup") {
                    if model.selectedEditableFileBackups.isEmpty {
                        Text("No backups available")
                    } else {
                        ForEach(model.selectedEditableFileBackups.prefix(20)) { backup in
                            Button("\(URL(fileURLWithPath: backup.path).lastPathComponent)") {
                                model.restoreSelectedEditableFileBackup(backup)
                            }
                        }
                    }
                }
                .disabled(model.selectedEditableFileBackups.isEmpty || model.isSavingEditableFile || model.isRestoringEditableFile)

                Button("Reveal in Finder") {
                    model.revealSelectedEditableFileInFinder()
                }

                if file.kind == .yabairc {
                    Button("Apply / Restart yabai") {
                        model.restartYabaiAfterRawFileEdit()
                    }
                }

                Spacer(minLength: 0)
            }

            if let message = model.filesLastActionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
            }
            if let error = model.filesLastErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private func kindBadge(_ kind: EditableFileKind) -> some View {
        Text(kind.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func icon(for kind: EditableFileKind) -> String {
        switch kind {
        case .yabairc: return "square.grid.2x2"
        case .skhdrc: return "keyboard"
        case .script: return "terminal"
        case .other: return "doc.text"
        }
    }

    private func syncFilesTabState(allowRefresh: Bool = true) async {
        if allowRefresh, model.editableFiles.isEmpty, !model.isRefreshingEditableFiles {
            await model.refreshEditableFiles()
        } else {
            await model.handlePendingFileEditorTargetIfNeeded()
        }

        if model.selectedEditableFilePath == nil,
           !model.isLoadingEditableFile,
           let first = model.editableFiles.first {
            await model.loadEditableFile(path: first.path, line: nil)
        }

        if let line = model.consumeEditableFileJumpTargetLine() {
            editorJumpLine = line
        }
    }
}

struct JumpingCodeEditorView: NSViewRepresentable {
    @Binding var text: String
    @Binding var jumpTargetLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 2000, height: CGFloat.greatestFiniteMagnitude)
        }

        textView.string = text
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        let contentWidth = max(180, nsView.contentSize.width)
        if abs(textView.frame.width - contentWidth) > 0.5 {
            var frame = textView.frame
            frame.size.width = contentWidth
            if frame.size.height < 200 {
                frame.size.height = 200
            }
            textView.frame = frame
            if let textContainer = textView.textContainer {
                let targetWidth = max(40, contentWidth - (textView.textContainerInset.width * 2))
                if abs(textContainer.containerSize.width - targetWidth) > 0.5 {
                    textContainer.containerSize = NSSize(width: targetWidth, height: CGFloat.greatestFiniteMagnitude)
                }
            }
        }

        if textView.string != text {
            context.coordinator.isProgrammaticUpdate = true
            let selected = textView.selectedRange()
            textView.string = text
            let maxLocation = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, maxLocation), length: 0))
            context.coordinator.isProgrammaticUpdate = false
            textView.needsDisplay = true
        }

        if let line = jumpTargetLine {
            scrollToLine(line, in: textView)
            DispatchQueue.main.async {
                self.jumpTargetLine = nil
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let text: Binding<String>
        weak var textView: NSTextView?
        var isProgrammaticUpdate = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate else { return }
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }

    private func scrollToLine(_ line: Int, in textView: NSTextView) {
        let range = nsRangeForLine(max(1, line), in: textView.string)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    private func nsRangeForLine(_ line: Int, in text: String) -> NSRange {
        let ns = text as NSString
        if ns.length == 0 { return NSRange(location: 0, length: 0) }

        var currentLine = 1
        var searchIndex = 0
        while currentLine < line && searchIndex < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: searchIndex, length: 0))
            searchIndex = NSMaxRange(lineRange)
            currentLine += 1
        }

        if searchIndex >= ns.length {
            return NSRange(location: max(0, ns.length - 1), length: 0)
        }
        return ns.lineRange(for: NSRange(location: searchIndex, length: 0))
    }
}
