import ChangelogKit
import SwiftUI

/// Rows that wrap: chips side by side, onto the next line when the width runs
/// out, as the web's lists of tags do.
struct FlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(subviews, width: proposal.width ?? .infinity)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(subviews, width: bounds.width) {
      var x = bounds.minX
      for i in row.items {
        let size = subviews[i].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + lineSpacing
    }
  }

  private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

  private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
    var rows: [Row] = []
    var row = Row()
    for i in subviews.indices {
      let size = subviews[i].sizeThatFits(ProposedViewSize(width: width, height: nil))
      let wide = row.items.isEmpty ? size.width : row.width + spacing + size.width
      if !row.items.isEmpty, wide > width {
        rows.append(row)
        row = Row()
      }
      row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
      row.height = max(row.height, size.height)
      row.items.append(i)
    }
    if !row.items.isEmpty { rows.append(row) }
    return rows
  }
}

/// One tag as a chip: its name as written, and a button that takes it off.
struct TagChip: View {
  let tag: Tag
  var disabled = false
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 2) {
      Text(verbatim: tag.name).face(.tagOn).foregroundStyle(Color.ink).lineLimit(1)
      Button(action: remove) {
        Image(systemName: "xmark").imageScale(.small).foregroundStyle(Color.ink2).frame(width: 32, height: 36).contentShape(.rect)
      }
      .buttonStyle(.plain)
      .disabled(disabled)
      .accessibilityLabel("Remove tag \(tag.name)")
    }
    .padding(.leading, 10)
    .background(Color.rule, in: .capsule)
  }
}

/// A tags field, as the web's (`tag-field.tsx`): the tags as chips, each with
/// its own remove button, and a box to type one more. Return adds what is
/// typed, and so does leaving the box; a leading # goes, and spaces and emoji
/// stay ("Road Trip", "🚗 Lake"). It refuses a tag over 50 characters, a 21st
/// tag, a comma and a line break, saying why (call 4). A tag already there by
/// any spelling stays as it is. What a chip's removal does is the caller's: a
/// note's #words leave its words too (call 1).
struct TagField: View {
  let tags: [Tag]
  var label = "Tags"
  var hint: String?
  /// Tags to offer as one is typed: the ones used before.
  var offer: [Tag] = []
  /// Saving the last change, where each one saves: the box keeps what is
  /// typed until it is done.
  var busy = false
  let add: (Tag) -> Void
  let remove: (Tag) -> Void

  @State private var typed = ""
  @State private var problem: String?
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !tags.isEmpty {
        FlowLayout {
          ForEach(tags) { tag in
            TagChip(tag: tag, disabled: busy) {
              problem = nil
              remove(tag)
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
      }
      TextField(label, text: $typed, prompt: Text(tags.isEmpty ? "Add a tag" : "Add another").foregroundStyle(Color.ink3))
        .face(.tag)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.done)
        .focused($focused)
        .onSubmit {
          commit()
          focused = true
        }
        .onChange(of: typed) { _, _ in problem = nil }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .accessibilityLabel(label)
        .accessibilityHint(hint ?? "")
      let offered = suggestions
      if !offered.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 14) {
            ForEach(offered) { tag in
              Button(tag.name) {
                typed = tag.name
                commit()
              }
              .buttonStyle(QuietButtonStyle())
              .accessibilityLabel("Add tag \(tag.name)")
            }
          }
        }
      }
      if let problem {
        Text(problem).face(.meta).foregroundStyle(Color.tangerineInk)
      } else if let hint, focused {
        Text(hint).face(.meta).foregroundStyle(Color.ink2)
      }
    }
  }

  /// While typing: the tags used before that begin with what is typed, or
  /// have a word that does, and aren't here yet.
  private var suggestions: [Tag] {
    let start = typed.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.lowercased()
    guard focused, !start.isEmpty else { return [] }
    return offer.filter { tag in
      !tags.contains { $0.key == tag.key }
        && (tag.name.lowercased().hasPrefix(start) || tag.name.lowercased().split(separator: " ").contains { $0.hasPrefix(start) })
    }
    .prefix(6).map { $0 }
  }

  private func commit() {
    guard !busy, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    switch Hashtags.adding(typed, to: tags) {
    case .failure(let why):
      problem = why.said
    case .success(let done):
      problem = nil
      typed = ""
      if let added = done.added { add(added) }
    }
  }
}

/// Tags as a line of links to their pages, as a note, a date or a stay has
/// them under it: "Tags: Road Trip, lake".
struct TagLinks: View {
  let tags: [Tag]

  var body: some View {
    if !tags.isEmpty {
      FlowLayout(spacing: 4, lineSpacing: 2) {
        Text("Tags:").face(.meta).foregroundStyle(Color.ink3)
        ForEach(Array(tags.enumerated()), id: \.element.key) { i, tag in
          NavigationLink(value: TagRoute(tag)) {
            Text(verbatim: tag.name + (i < tags.count - 1 ? "," : "")).face(.meta).foregroundStyle(Color.cobalt)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Tag \(tag.name)")
        }
      }
    }
  }
}

/// Every tag's list.
struct TagsRoute: Hashable {}

/// A tag's page, by its key, with the name to call it.
struct TagRoute: Hashable {
  let key: String
  let name: String

  init(_ tag: Tag) {
    key = tag.key
    name = tag.name
  }
}

/// Every tag, as the web's Search lists them with the box empty: its latest
/// name, what has it, and a page of its own.
struct TagsPage: View {
  @Environment(AppModel.self) private var model
  @State private var all: TagTotals?
  @State private var problem: String?

  var body: some View {
    List {
      Group {
        if let all {
          if all.tags.isEmpty {
            Text("No tags yet. Add one to a note, an Upcoming date or a check-in.")
              .face(.hint).foregroundStyle(Color.ink2).paperRow(top: 16)
          }
          ForEach(all.tags, id: \.tag) { total in
            NavigationLink(value: TagRoute(total.named)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: total.named.name).face(.line).foregroundStyle(Color.ink)
                Text(total.carried).face(.meta).foregroundStyle(Color.ink3)
              }
            }
            .paperRow(top: 8, bottom: 8)
          }
        } else if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 16)
        } else {
          ProgressView().paperRow(top: 16)
        }
      }
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle("Tags")
    .refreshable { await read() }
    .task(id: model.changes) { await read() }
  }

  private func read() async {
    do throws(APIError) {
      all = try await model.allTags()
      problem = nil
    } catch {
      if all == nil { problem = error.message }
    }
  }
}

/// One tag's page, as the web's (call 5): its Upcoming dates, its check-ins,
/// then its notes, newest first, a page at a time.
struct TagPage: View {
  @Environment(AppModel.self) private var model
  let route: TagRoute
  @State private var found: SearchResults?
  @State private var notes: [NoteDetail] = []
  @State private var next: String?
  @State private var readingNext: String?
  @State private var dates: [UpcomingEntry] = []
  @State private var stays: [CheckIn] = []
  @State private var problem: String?
  /// Each read numbered: only the newest one's answer is shown.
  @State private var reads = 0

  var body: some View {
    List {
      Group {
        Text("Tag").face(.head).foregroundStyle(Color.ink3).paperRow(top: 14)
        Text(verbatim: route.name).face(.title).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader).paperRow(top: 2)
        if let found {
          Text(lede(found)).face(.lede).foregroundStyle(Color.ink2).paperRow(top: 8, bottom: 4)
        } else if let problem {
          Text(problem).face(.hint).foregroundStyle(Color.tangerineInk).paperRow(top: 8)
        } else {
          ProgressView().paperRow(top: 12)
        }
        if !dates.isEmpty {
          head("Upcoming")
          ForEach(dates) { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: entry.line).face(.line).foregroundStyle(Color.ink)
              Text(Day.label(entry.next, today: model.me?.today ?? entry.next)).face(.meta).foregroundStyle(Color.ink3)
            }
            .paperRow(top: 8, bottom: 8)
          }
        }
        if !stays.isEmpty {
          head("Check-ins")
          ForEach(stays) { stay in
            NavigationLink(value: ActivityStop(day: stay.day, id: stay.id)) {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: stay.label).face(.line).foregroundStyle(Color.ink)
                Text(Day.label(stay.day, today: model.me?.today ?? stay.day)).face(.meta).foregroundStyle(Color.ink3)
              }
            }
            .paperRow(top: 8, bottom: 8)
          }
        }
        let shown = notes.filter { !model.isBeingDeleted($0) }
        if !shown.isEmpty, !dates.isEmpty || !stays.isEmpty { head("Notes") }
        ForEach(shown) { note in
          NavigationLink(value: note) { NoteRow(note: note) }
            .paperRow(top: 10, bottom: 10)
            .onAppear { if note.id == shown.last?.id { Task { await more() } } }
        }
        Color.clear.frame(height: 24).paperRow()
      }
      .listRowSeparator(.hidden)
    }
    .paperList()
    .navigationTitle(route.name)
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await read() }
    .task(id: model.changes &+ model.checkInChanges) { await read() }
  }

  private func head(_ title: String) -> some View {
    Text(title).face(.head).foregroundStyle(Color.ink2).accessibilityAddTraits(.isHeader).paperRow(top: 24, bottom: 4)
  }

  /// "3 notes. 1 Upcoming date and 2 check-ins.", as the web's lede.
  private func lede(_ found: SearchResults) -> String {
    var lines: [String] = []
    if found.total > 0 { lines.append(found.total == 1 ? "1 note." : "\(found.total.formatted()) notes.") }
    let others = [dates.isEmpty ? nil : dates.count == 1 ? "1 Upcoming date" : "\(dates.count) Upcoming dates",
                  stays.isEmpty ? nil : stays.count == 1 ? "1 check-in" : "\(stays.count) check-ins"].compactMap { $0 }
    if !others.isEmpty { lines.append(others.joined(separator: " and ") + ".") }
    return lines.isEmpty ? "Nothing has this tag now." : lines.joined(separator: " ")
  }

  /// The notes, dates and check-ins side by side; a date or check-in that
  /// can't be read leaves its section out, as the notes are what the page is.
  private func read() async {
    reads += 1
    let read = reads
    let key = route.key
    let datesRead = Task { () -> [UpcomingEntry]? in
      guard model.canRemind else { return [] }
      return try? await model.upcoming().entries.filter { $0.fields.tags.contains { $0.key == key } }
    }
    let staysRead = Task { try? await model.checkIns(tagged: key, before: nil).items }
    do throws(APIError) {
      let page = try await model.search(.tag(key), after: nil)
      let upcoming = await datesRead.value, checkIns = await staysRead.value
      guard read == reads else { return }
      if let upcoming { dates = upcoming }
      if let checkIns { stays = checkIns }
      found = page
      notes = page.items
      next = page.next
      problem = nil
    } catch {
      guard read == reads else { return }
      if found == nil { problem = error.message }
    }
  }

  private func more() async {
    guard let after = next, readingNext != after else { return }
    let read = reads
    readingNext = after
    defer { if readingNext == after { readingNext = nil } }
    guard let page = try? await model.search(.tag(route.key), after: after), read == reads else { return }
    notes += page.items
    next = page.next
  }
}
