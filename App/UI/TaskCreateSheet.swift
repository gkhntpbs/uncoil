import SwiftUI

/// Adding a task to a TODO file from the Tasks screen.
///
/// The new line is written the way an agent would write it: same indent and
/// list marker as its siblings, under the heading the user picked, through the
/// same byte-range patch path every other edit takes — the rest of the file is
/// never rewritten.
struct TaskCreateSheet: View {
    /// The documents a task can go into, in display order.
    let documents: [TaskDocument]
    /// Called with the target and the text; the owner writes the patch.
    let onCreate: (TaskDocument, [String], String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var selectedPath: String?
    @State private var headingPath: [String] = []
    @State private var didSeed = false

    private var document: TaskDocument? {
        documents.first { $0.path == selectedPath } ?? documents.first
    }

    /// Heading chains of the chosen file, in file order: what "add under"
    /// can point at. The root (file end) is always offered.
    private var headingChoices: [[String]] {
        guard let document else { return [] }
        var stack: [String] = []
        var chains: [[String]] = []
        for heading in document.headings {
            while stack.count >= heading.level { stack.removeLast() }
            // A jump from h1 to h3 leaves a short stack; the chain is whatever
            // the file actually nests, not an invented level.
            stack.append(heading.text)
            chains.append(stack)
        }
        return chains
    }

    private var preview: String {
        guard let document else { return "" }
        let sibling = document.tasks(under: headingPath).last
        let marker = sibling.map {
            TodoEditor.nextListMarker(after: $0.checkbox.listMarker)
        } ?? "-"
        let indent = sibling?.checkbox.indent ?? ""
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(indent)\(marker) [ ] \(title.isEmpty ? "…" : title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("New task")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.text)
                Text("Added to the file as a single line, under the heading you pick.")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider().overlay(Theme.border)

            VStack(alignment: .leading, spacing: 12) {
                if documents.count > 1 {
                    field("File") {
                        Picker("", selection: Binding(
                            get: { document?.path },
                            set: { path in
                                selectedPath = path
                                headingPath = []
                            }
                        )) {
                            ForEach(documents, id: \.path) { candidate in
                                Text(URL(fileURLWithPath: candidate.path).lastPathComponent)
                                    .tag(String?.some(candidate.path))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("tasks.create.source")
                    }
                }

                field("Title") {
                    Picker("", selection: $headingPath) {
                        Text("End of file (no heading)").tag([String]())
                        ForEach(headingChoices, id: \.self) { chain in
                            Text(chain.joined(separator: " › ")).tag(chain)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("tasks.create.heading")
                }

                field("Task") {
                    TextField("What should happen?", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(11.5))
                        .onSubmit(create)
                        .accessibilityIdentifier("tasks.create.text")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Line to write to the file")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.textFaint)
                    Text(preview)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("tasks.create.preview")
                }
            }
            .padding(16)

            Divider().overlay(Theme.border)
            HStack(spacing: 9) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add", action: create)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(
                        document == nil
                            || text.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                    .accessibilityIdentifier("tasks.create.confirm")
            }
            .padding(14)
        }
        .frame(width: 520)
        .background(Theme.bg)
        .onAppear(perform: seed)
        .accessibilityIdentifier("tasks.createSheet")
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    /// The last heading is where new work usually goes; starting there saves a
    /// click without hiding the choice.
    private func seed() {
        guard !didSeed else { return }
        didSeed = true
        selectedPath = documents.first?.path
        headingPath = headingChoices.last ?? []
    }

    private func create() {
        guard let document,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCreate(document, headingPath, text)
    }
}
