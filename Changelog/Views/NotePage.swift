import ChangelogKit
import QuickLook
import SwiftUI

/// One note in full: its words as the web sets them, its files with their
/// transcripts and descriptions, its place and where it came from. Edit and
/// Delete go through the queue, as they do from Log.
struct NotePage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var note: NoteDetail
  @State private var editing = false
  @State private var confirmDelete = false
  @State private var gone = false

  init(note: NoteDetail) {
    _note = State(initialValue: note)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let version = note.version {
          versionText(version).face(.head).foregroundStyle(Color.ink2)
        }
        if gone {
          Text("This note is gone: it was deleted somewhere else.").face(.hint).foregroundStyle(Color.tangerineInk)
        }
        NoteLine(note: note)
        NoteWords(note: note, selectable: true)
        ForEach(note.media ?? []) { NoteFileView(file: $0, note: note) }
        if let attachments = note.attachments, attachments > 0 {
          Text(attachments == 1 ? "Its email had 1 more file, not kept here. It's in the original email."
               : "Its email had \(attachments) more files, not kept here. They're in the original email.")
            .face(.meta).foregroundStyle(Color.ink3)
        }
        VStack(alignment: .leading, spacing: 4) {
          if let place = note.place { Text(place.label) }
          if note.late == true { Text("Written after the day ended.") }
          if note.editedAt != nil { Text("Edited.") }
          if model.hasChangeWaiting(note) { Text("A change is waiting to send.") }
        }
        .face(.meta)
        .foregroundStyle(Color.ink3)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
    .background(Color.paper)
    .navigationTitle(Day.label(note.date, today: model.me?.today ?? note.date))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if model.canChange(note), !gone {
        ToolbarItem(placement: .primaryAction) {
          Menu("Change", systemImage: "ellipsis.circle") {
            Button("Edit", systemImage: "pencil") { editing = true }
            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
          }
        }
      }
    }
    .sheet(isPresented: $editing) {
      EditNoteView(date: note.date, id: note.id, title: note.version.map { "Edit in \($0)" } ?? "Edit")
    }
    .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        Task {
          await model.delete(note)
          dismiss()
        }
      }
    } message: {
      Text(note.hasEmail ? "It goes from Release Notes, with its photos and files and the email it came in. This can't be undone."
           : "It goes from Release Notes, with its photos and files. This can't be undone.")
    }
    // The stack closes when reading locks; these go first, so nothing shows
    // over it on the way.
    .onChange(of: model.readingOpen) { _, open in
      if !open {
        editing = false
        confirmDelete = false
      }
    }
    // Read fresh on opening, and again once a change has gone: a list's copy
    // may be behind, and an edit needs the newest revision.
    .task(id: model.changes) { await read() }
  }

  private func read() async {
    do throws(APIError) {
      note = try await model.load(date: note.date, id: note.id, urls: true)
      gone = false
    } catch {
      if error.status == 404 { gone = true }
    }
  }
}

/// A note's words: its parts, with links and tags, and in a rich note its
/// marks, lists and quotes set as the web sets them.
struct NoteWords: View {
  let note: NoteDetail
  var selectable = false
  @ScaledMetric(relativeTo: .body) private var size: CGFloat = 17

  var body: some View {
    let parts = note.parts ?? [.text(note.text)]
    Group {
      if note.text.isEmpty {
        if (note.media ?? []).isEmpty {
          Text(note.hasEmail ? "Attachments only. They are in the original email." : "Nothing written.")
            .face(.hint)
            .foregroundStyle(Color.ink2)
        }
      } else if note.isRich {
        NoteBlocks(blocks: Rich.blocks(parts), size: size)
      } else {
        Text(NoteRuns(size: size).plain(parts))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .foregroundStyle(Color.ink)
    .modifier(Selectable(on: selectable))
  }
}

private struct Selectable: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    if on { content.textSelection(.enabled) } else { content }
  }
}

/// Words as runs of type: each its face, links underlined and only to the web.
private struct NoteRuns {
  let size: CGFloat

  private func face(_ marks: Rich.Marks) -> Face {
    switch (marks.strong, marks.em) {
    case (true, true): .noteStrongEm
    case (true, false): .noteStrong
    case (false, true): .noteEm
    case (false, false): .note
    }
  }

  private func run(_ words: String, _ marks: Rich.Marks) -> AttributedString {
    var run = AttributedString(words)
    run.font = face(marks).font(size: size)
    return run
  }

  private func atom(_ part: NotePart, _ marks: Rich.Marks) -> AttributedString {
    var out = run(Rich.text(of: part), marks)
    switch part {
    case .link(let url, _, _):
      if let url = URL(string: url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        out.link = url
        out.underlineStyle = .single
      }
    case .tag:
      out.foregroundColor = Color.tangerineInk
    default:
      break
    }
    return out
  }

  func plain(_ parts: [NotePart]) -> AttributedString {
    parts.reduce(into: AttributedString()) { all, part in
      if case .text(let words) = part { all += run(words, Rich.Marks()) } else { all += atom(part, Rich.Marks()) }
    }
  }

  func line(_ line: Rich.Line) -> AttributedString {
    line.reduce(into: AttributedString()) { all, piece in
      switch piece {
      case .text(let words, let marks): all += run(words, marks)
      case .atom(let part, let marks): all += atom(part, marks)
      }
    }
  }

  func lines(_ lines: [Rich.Line]) -> AttributedString {
    var all = AttributedString()
    for (i, one) in lines.enumerated() {
      if i > 0 { all += AttributedString("\n") }
      all += line(one)
    }
    return all
  }
}

private struct NoteBlocks: View {
  let blocks: [Rich.Block]
  let size: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        NoteBlock(block: block, size: size)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct NoteBlock: View {
  let block: Rich.Block
  let size: CGFloat

  var body: some View {
    let runs = NoteRuns(size: size)
    switch block {
    case .para(let lines):
      Text(runs.lines(lines))
    case .bullets(let entries):
      list(entries, marker: { _ in "•" })
    case .numbers(let start, let entries):
      list(entries, marker: { "\(start + $0)." })
    case .quote(let inner):
      HStack(spacing: 10) {
        Rectangle().fill(Color.ink3).frame(width: 2)
        NoteBlocks(blocks: inner, size: size).foregroundStyle(Color.ink2)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func list(_ entries: [[Rich.Line]], marker: @escaping (Int) -> String) -> some View {
    let runs = NoteRuns(size: size)
    return VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(entries.enumerated()), id: \.offset) { i, lines in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(marker(i)).face(.note).foregroundStyle(Color.ink2)
          Text(runs.lines(lines))
        }
      }
    }
  }
}

/// A photo's small copy, held by this view alone.
struct NoteThumb: View {
  @Environment(AppModel.self) private var model
  let file: NoteFileEntry
  let note: NoteDetail
  @State private var image: UIImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      Rectangle().fill(Color.ink3.opacity(0.12))
      if let image {
        Image(uiImage: image).resizable().scaledToFill()
      } else if failed {
        Image(systemName: "photo").foregroundStyle(Color.ink3)
      } else {
        ProgressView()
      }
    }
    .clipShape(.rect(cornerRadius: 6))
    .accessibilityLabel(file.description ?? "Photo")
    .task(id: file.n) {
      // A photo too small to have a small copy shows itself.
      let data = await model.fileData(file, of: note, thumb: file.thumb != nil)
      image = data.flatMap(UIImage.init(data:))
      failed = image == nil
    }
  }
}

/// One of a note's files on its page. A tap fetches the whole file and opens
/// it in Quick Look, on this phone only for as long as it is open.
private struct NoteFileView: View {
  @Environment(AppModel.self) private var model
  let file: NoteFileEntry
  let note: NoteDetail
  @State private var previewing: URL?
  @State private var download: Task<Void, Never>?
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button { open() } label: {
        if file.kind == "image" {
          NoteThumb(file: file, note: note).aspectRatio(aspect, contentMode: .fit).frame(maxWidth: .infinity)
        } else {
          Label(title, systemImage: file.kind == "audio" ? "waveform" : "doc").face(.action).foregroundStyle(Color.cobalt)
        }
      }
      .buttonStyle(.plain)
      .disabled(download != nil)
      .overlay { if download != nil { ProgressView() } }
      if failed {
        Text("This file couldn't be fetched. Try again in a moment.").face(.meta).foregroundStyle(Color.tangerineInk)
      }
      if let description = file.description {
        Text(verbatim: description).face(.meta).foregroundStyle(Color.ink2).textSelection(.enabled)
      }
      if let transcript = file.transcript {
        Text(verbatim: transcript).face(.note).foregroundStyle(Color.ink).textSelection(.enabled)
      } else if file.writing == true {
        Text("Its words are still being written.").face(.meta).foregroundStyle(Color.ink3)
      }
    }
    .quickLookPreview($previewing)
    .onChange(of: previewing) { before, now in
      if now == nil, let before { PreviewFiles.remove(before) }
    }
    // Only the fetch stops here. Quick Look open over this view keeps its file.
    .onDisappear {
      download?.cancel()
      download = nil
    }
  }

  private var title: String {
    file.name ?? (file.kind == "audio" ? "Voice memo" : "File")
  }

  private var aspect: CGFloat {
    guard let width = file.thumb?.width, let height = file.thumb?.height, width > 0, height > 0 else { return 4.0 / 3.0 }
    return CGFloat(width) / CGFloat(height)
  }

  private func open() {
    failed = false
    download = Task {
      let data = await model.fileData(file, of: note, thumb: false)
      // The page closed, or the lock or a sign-out swept while it came: nothing
      // goes on disk. No wait between this and the write, so no sweep slips in.
      guard !Task.isCancelled, model.readingOpen else { return }
      previewing = data.flatMap { PreviewFiles.keep($0, name: file.previewName) }
      failed = previewing == nil
      download = nil
    }
  }
}
