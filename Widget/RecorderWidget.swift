import SwiftUI
import WidgetKit

private struct RecorderEntry: TimelineEntry { let date: Date }
private struct RecorderProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecorderEntry { RecorderEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (RecorderEntry) -> Void) {
        completion(RecorderEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecorderEntry>) -> Void) {
        completion(Timeline(entries: [RecorderEntry(date: Date())], policy: .never))
    }
}

private struct RecorderWidgetView: View {
    @Environment(\.widgetFamily) private var family
    private let mint = Color(red: 0.31, green: 0.94, blue: 0.68)
    private let background = Color(red: 0.025, green: 0.035, blue: 0.035)
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "moon.stars.fill").foregroundStyle(mint)
                Text("ATHLETEOS").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Text("Start / end night").font(.headline).foregroundStyle(.white)
            if family == .systemMedium {
                Text("Opens Recorder and handles your next step.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            HStack {
                Image(systemName: "power")
                Text("Night recorder").font(.caption.weight(.semibold))
            }.foregroundStyle(.black).padding(10).frame(maxWidth: .infinity)
                .background(mint, in: RoundedRectangle(cornerRadius: 12))
        }
        .widgetURL(URL(string: "athleteos-recorder://night-action")!)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Start or end night. Opens AthleteOS Recorder and runs the next night action.")
    }
    var body: some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(background, for: .widget)
        } else {
            content.padding().background(background)
        }
    }
}

@main
struct RecorderWidget: Widget {
    let kind = "AthleteOSNightRecorder"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecorderProvider()) { _ in RecorderWidgetView() }
            .configurationDisplayName("Night recorder")
            .description("One tap to open Recorder and start or end your H10 night.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
