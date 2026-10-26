import SwiftUI
import WidgetKit
import AppKit
import OSLog

struct NeptuneEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var stale: Bool { snapshot?.isStale(at: date) ?? true }
}

struct NeptuneProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeptuneEntry { example }
    func getSnapshot(in context: Context, completion: @escaping (NeptuneEntry) -> Void) {
        completion(context.isPreview ? example : NeptuneEntry(date: Date(), snapshot: .read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NeptuneEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.read()
        Logger(subsystem: "local.milos.neptune-control.widget", category: "timeline").info("Status snapshot available: \(snapshot != nil, privacy: .public)")
        let expiry = snapshot?.updated.addingTimeInterval(301) ?? now.addingTimeInterval(301)
        var entries = [NeptuneEntry(date: now, snapshot: snapshot)]
        if expiry > now { entries.append(NeptuneEntry(date: expiry, snapshot: snapshot)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
    }
    private var example: NeptuneEntry {
        NeptuneEntry(date: Date(), snapshot: WidgetSnapshot(apps: [
            WidgetAppStatus(id: "claudeCode", title: "Claude Code", state: "Ready to sync", allowed: true, needsAttention: false),
            WidgetAppStatus(id: "cursor", title: "Cursor", state: "Off", allowed: false, needsAttention: false)
        ]))
    }
}

struct NeptuneWidgetView: View {
    let entry: NeptuneEntry
    @Environment(\.widgetFamily) var family
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    private var monthly: NeptuneMonthlyStats? {
        guard let stats = entry.snapshot?.stats, stats.isFresh(at: entry.date) else { return nil }
        return stats
    }
    private let controlURL = URL(string: "neptune-control://control")!
    private let statsURL = URL(string: "https://app.neptune.spaceinch.tech/stats")!

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 20 : 10) {
            HStack(spacing: 5) {
                FullColorWidgetImage(name: "NeptuneLogo").scaledToFit().frame(width: 14, height: 17).accessibilityHidden(true)
                Text("Neptune").font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 0)
            }
            VStack(spacing: family == .systemLarge ? 14 : 8) {
            if let snapshot = entry.snapshot {
                ForEach(Array(snapshot.apps.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.leading, family == .systemLarge ? 45 : 33) }
                    HStack(spacing: family == .systemSmall ? 6 : 9) {
                        icon(app.id).frame(width: family == .systemLarge ? 36 : 24, height: family == .systemLarge ? 36 : 24)
                        Text(family == .systemSmall && app.id == "claudeCode" ? "Claude" : app.title)
                            .font(.system(size: family == .systemSmall ? 11 : 12, weight: .medium))
                            .lineLimit(1).fixedSize()
                        Spacer(minLength: 4)
                        HStack(spacing: 5) {
                            if app.allowed && !entry.stale { activeDot }
                            Text(status(app))
                                .font(.system(size: family == .systemLarge ? 12 : 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(family == .systemSmall ? 2 : 1)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(app.title), \(status(app))")
                }
            } else {
                Text("Open Neptune Control to see collection status.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spaceinch accounts only").font(.system(size: 9))
                    statsLink
                }.foregroundStyle(.secondary)
            } else {
                HStack(spacing: 4) {
                    Label("Spaceinch accounts only", systemImage: "lock.shield")
                    Spacer(minLength: 8)
                    statsLink
                }.font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(statsURL)
    }

    private var statsLink: some View {
        Link(destination: statsURL) {
            Label("My stats", systemImage: "arrow.up.right")
                .font(.system(size: 10, weight: .medium))
        }.accessibilityLabel("Open my Neptune statistics")
    }

    private func status(_ app: WidgetAppStatus) -> String {
        if entry.stale { return family == .systemSmall ? "Update" : "Open app to update" }
        if app.allowed && monthly != nil { return family == .systemSmall ? "Synced" : "Synced with Neptune" }
        if family == .systemSmall {
            if app.needsAttention { return "Check" }
            if app.allowed { return "Ready" }
            if app.state == "Off" { return "Off" }
            return "Blocked"
        }
        return app.state
    }
    private var activeDot: some View {
        Group {
            if #available(macOS 15.0, *) {
                Image(systemName: "circle.fill").widgetAccentedRenderingMode(.fullColor)
            } else { Image(systemName: "circle.fill") }
        }
        .font(.system(size: 6)).foregroundStyle(.green)
        .symbolEffect(.pulse, options: .repeat(1), value: reduceMotion ? nil : entry.snapshot?.updated)
        .accessibilityHidden(true)
    }

    private func icon(_ id: String) -> some View {
        FullColorWidgetImage(name: id == "claudeCode" ? "Claude" : "Cursor")
            .scaledToFit().accessibilityHidden(true)
    }

}

private struct FullColorWidgetImage: View {
    let name: String
    var body: some View {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let bitmap = NSBitmapImageRep(data: data), let cgImage = bitmap.cgImage {
            let image = Image(decorative: cgImage, scale: 1, orientation: .up)
                .renderingMode(.original).resizable()
            if #available(macOS 15.0, *) {
                image.widgetAccentedRenderingMode(.fullColor)
            } else { image }
        }
    }
}

struct NeptuneStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NeptuneStatus", provider: NeptuneProvider()) { entry in
            NeptuneWidgetView(entry: entry)
        }
        .configurationDisplayName("Neptune Control")
        .description("Claude Code and Cursor collection status. Open to manage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct NeptuneWidgets: WidgetBundle {
    var body: some Widget { NeptuneStatusWidget() }
}
