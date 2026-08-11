import Foundation
import Observation   // @Observable 宏来自这里，只 import Foundation 会编译失败

/// 一条探针测量结果。
///
/// 探针只测量与打印，不做判断——判断留给人。
struct ProbeMeasurement: Identifiable {
    let id: String          // 探针编号，如 "P1"
    let title: String
    var value: String       // 实测值，未测时为 "—"
    var note: String        // 补充说明或异常

    init(id: String, title: String, value: String = "—", note: String = "") {
        self.id = id
        self.title = title
        self.value = value
        self.note = note
    }
}

/// 全部 12 项探针的测量结果。编号与 docs/api-facts-arkit-depth.md §6 一一对应。
@Observable
final class ProbeReport {
    var measurements: [ProbeMeasurement] = [
        ProbeMeasurement(id: "P1", title: "supportedVideoFormats 各档帧率"),
        ProbeMeasurement(id: "P2", title: "camera.transform 的实际基准"),
        ProbeMeasurement(id: "P3", title: "didUpdateFrame 实测频率"),
        ProbeMeasurement(id: "P4", title: "supportedNumberOfTrackedFaces"),
        ProbeMeasurement(id: "P5", title: "左右眼是否镜像"),
        ProbeMeasurement(id: "P6", title: "lookAtPoint 的尺度"),
        ProbeMeasurement(id: "P7", title: "faceGeometry 顶点坐标系"),
        ProbeMeasurement(id: "P8", title: "configurableCaptureDevice 是否为 nil"),
        ProbeMeasurement(id: "P9", title: "眼位单位（实测瞳距）"),
        ProbeMeasurement(id: "P10", title: "capturedDepthData 类型与分辨率"),
        ProbeMeasurement(id: "P11", title: "设备标识符与屏幕参数"),
        ProbeMeasurement(id: "P12", title: "双眼中点在相机空间的完整向量")
    ]

    func set(_ id: String, value: String, note: String = "") {
        guard let index = measurements.firstIndex(where: { $0.id == id }) else { return }
        measurements[index].value = value
        measurements[index].note = note
    }

    /// 导出为可直接贴进文档的 Markdown 表格。
    /// 只返回字符串，由用户手动复制——探针不写文件。
    func markdownTable() -> String {
        var lines = ["| 编号 | 项目 | 实测值 | 备注 |", "|---|---|---|---|"]
        for m in measurements {
            lines.append("| \(m.id) | \(m.title) | \(m.value) | \(m.note) |")
        }
        return lines.joined(separator: "\n")
    }
}
