import SwiftUI
import UIKit   // UIPasteboard 需要，不要依赖 SwiftUI 的传递导入
import ARKit

@main
struct ParallaxProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

struct ProbeView: View {
    @State private var report = ProbeReport()
    @State private var probe: FaceProbe?
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List(report.measurements) { measurement in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(measurement.id) · \(measurement.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(measurement.value)
                        .font(.system(.body, design: .monospaced))
                    if !measurement.note.isEmpty {
                        Text(measurement.note)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .navigationTitle("视差探针")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isRunning ? "停止" : "开始") {
                        if isRunning {
                            probe?.stop()
                        } else {
                            let newProbe = FaceProbe(report: report)
                            newProbe.start()
                            probe = newProbe
                        }
                        isRunning.toggle()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") {
                        UIPasteboard.general.string = report.markdownTable()
                    }
                }
            }
        }
    }
}
