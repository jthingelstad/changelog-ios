import ChangelogKit
import SwiftUI
import WidgetKit

@main
struct ChangelogWidgets: WidgetBundle {
  var body: some Widget {
    TodayWidget()
    NewNoteControl()
  }
}

/// Today's version and whether anything is written yet, with what's coming
/// up on the Home Screen. Read from what the app left in the App Group
/// (`WidgetSnapshot`): a widget never calls the API, never works out a
/// version, and never shows a note's words. A tap opens Log, ready to write.
struct TodayWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "com.yourversionnumber.changelog.today", provider: TodayProvider()) { entry in
      TodayView(entry: entry)
    }
    .configurationDisplayName("Today")
    .description("Today's version and whether you've written yet. Tap to write a note.")
    .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

struct TodayEntry: TimelineEntry {
  enum Shows: Equatable {
    case day(WidgetSnapshot.Day)
    /// No one is signed in to Changelog.
    case signedOut
    /// The days the app last read have run out.
    case behind
  }

  var date: Date
  var shows: Shows
  var tz = "UTC"

  /// For the widget gallery: a version no one has.
  static let sample = TodayEntry(date: .now, shows: .day(WidgetSnapshot.Day(
    date: "2026-01-01", start: .now, end: .now.addingTimeInterval(86400), version: "1.2.345", wrote: false,
    upcoming: [WidgetSnapshot.Soon(date: "2026-01-04", title: "Lake weekend", kind: .trip)])))
}

struct TodayProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayEntry { .sample }

  func getSnapshot(in context: Context, completion: @escaping @Sendable (TodayEntry) -> Void) {
    completion(context.isPreview ? .sample : Self.entries(now: .now).first ?? TodayEntry(date: .now, shows: .signedOut))
  }

  /// One entry a day from each local midnight, then one saying the app has
  /// to be opened. The app has them drawn again whenever it reads `/v1/me`.
  func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<TodayEntry>) -> Void) {
    completion(Timeline(entries: Self.entries(now: .now), policy: .never))
  }

  static func entries(now: Date) -> [TodayEntry] {
    guard let snapshot = WidgetSnapshot.load() else { return [TodayEntry(date: now, shows: .signedOut)] }
    let days = snapshot.timeline(now: now)
    guard let last = days.last else { return [TodayEntry(date: now, shows: .behind, tz: snapshot.tz)] }
    return days.enumerated().map { i, day in
      TodayEntry(date: i == 0 ? min(day.start, now) : day.start, shows: .day(day), tz: snapshot.tz)
    } + [TodayEntry(date: last.end, shows: .behind, tz: snapshot.tz)]
  }
}

struct TodayView: View {
  var entry: TodayEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    content
      .widgetURL(AppRoute.newNoteURL)
      .containerBackground(.fill.tertiary, for: .widget)
  }

  @ViewBuilder private var content: some View {
    switch entry.shows {
    case .day(let day):
      switch family {
      case .accessoryInline:
        Label(day.version, systemImage: day.wrote ? "checkmark.circle" : "square.and.pencil")
      case .accessoryCircular:
        ZStack {
          AccessoryWidgetBackground()
          VStack(spacing: 1) {
            Text(day.version)
              .font(.system(.caption, design: .monospaced).weight(.semibold))
              .minimumScaleFactor(0.5)
              .lineLimit(1)
            Image(systemName: day.wrote ? "checkmark" : "square.and.pencil")
              .font(.caption2)
          }
          .padding(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(day.version), \(day.wrote ? "written today" : "nothing yet today")")
      case .accessoryRectangular:
        VStack(alignment: .leading, spacing: 1) {
          Text("Today").font(.caption2).foregroundStyle(.secondary)
          Text(day.version).font(.system(.headline, design: .monospaced))
          Text(day.wrote ? "Written today" : "Nothing yet").font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      case .systemMedium:
        HStack(alignment: .top, spacing: 16) {
          TodayColumn(day: day)
          Divider()
          SoonColumn(day: day, tz: entry.tz)
        }
      default:
        TodayColumn(day: day)
      }
    case .signedOut:
      Notice(text: "Sign in to Changelog to see today's version.", short: "Sign in", family: family)
    case .behind:
      Notice(text: "Open Changelog to catch up.", short: "Open", family: family)
    }
  }
}

private struct TodayColumn: View {
  var day: WidgetSnapshot.Day

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Today").font(.caption).foregroundStyle(.secondary)
      Text(day.version)
        .font(.system(.title, design: .monospaced).weight(.semibold))
        .minimumScaleFactor(0.5)
        .lineLimit(1)
      Spacer(minLength: 0)
      Label(day.wrote ? "Written today" : "Nothing yet", systemImage: day.wrote ? "checkmark.circle.fill" : "square.and.pencil")
        .font(.caption)
        .foregroundStyle(day.wrote ? .primary : .secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

/// The next Upcoming dates. Their titles are the owner's own words, so they
/// are on the Home Screen only, never the Lock Screen.
private struct SoonColumn: View {
  var day: WidgetSnapshot.Day
  var tz: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Coming up").font(.caption).foregroundStyle(.secondary)
      if let soon = day.upcoming, !soon.isEmpty {
        ForEach(Array(soon.enumerated()), id: \.offset) { _, entry in
          VStack(alignment: .leading, spacing: 0) {
            Text(entry.title).font(.subheadline).lineLimit(1)
            Text(when(entry)).font(.caption).foregroundStyle(.secondary)
          }
        }
      } else {
        Text(day.upcoming == nil ? "Tap to write a note." : "Nothing coming up.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private func when(_ entry: WidgetSnapshot.Soon) -> String {
    if entry.date <= day.date { return entry.through == nil || entry.through == day.date ? "Today" : "On now" }
    guard let zone = TimeZone(identifier: tz),
          let date = try? Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash).parse(entry.date) else {
      return entry.date
    }
    var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
    style.timeZone = zone
    return date.formatted(style)
  }
}

private struct Notice: View {
  var text: String
  var short: String
  var family: WidgetFamily

  var body: some View {
    switch family {
    case .accessoryInline, .accessoryCircular:
      Label(short, systemImage: "square.and.pencil")
    default:
      VStack(alignment: .leading, spacing: 4) {
        Text("Changelog").font(.caption).foregroundStyle(.secondary)
        Text(text).font(.subheadline)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }
}

/// Control Center, the Lock Screen and the Action Button: open Log, ready
/// to write.
struct NewNoteControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "com.yourversionnumber.changelog.new-note") {
      ControlWidgetButton(action: NewNoteIntent()) {
        Label("New Note", systemImage: "square.and.pencil")
      }
    }
    .displayName("New Note")
    .description("Opens Changelog ready to write a note.")
  }
}
