import SwiftUI
import WidgetKit

private struct EcardPayEntry: TimelineEntry {
  let date: Date
}

private struct EcardPayProvider: TimelineProvider {
  func placeholder(in context: Context) -> EcardPayEntry {
    EcardPayEntry(date: Date())
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (EcardPayEntry) -> Void
  ) {
    completion(EcardPayEntry(date: Date()))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<EcardPayEntry>) -> Void
  ) {
    completion(
      Timeline(
        entries: [EcardPayEntry(date: Date())],
        policy: .never
      )
    )
  }
}

private struct EcardPayWidgetView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: "qrcode")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(Color.accentColor)
      Spacer(minLength: 0)
      Text("消费码")
        .font(.headline)
        .foregroundStyle(.primary)
      Text("eCard")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .containerBackground(.fill.tertiary, for: .widget)
    .widgetURL(URL(string: "techpie://ecard/pay"))
  }
}

@main
struct EcardPayWidget: Widget {
  let kind = "EcardPayWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: EcardPayProvider()) { _ in
      EcardPayWidgetView()
    }
    .configurationDisplayName("消费码")
    .description("点击后直接打开 eCard 消费码")
    .supportedFamilies([.systemSmall])
  }
}
