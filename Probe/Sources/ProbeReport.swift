import Foundation
import Observation   // @Observable 宏来自这里，只 import Foundation 会编译失败
import OSLog

/// 探针日志。Mac 侧用下面这条命令实时读取，操作者不必截图或手抄：
///
///     log stream --device <UDID> --style compact \
///       --predicate 'subsystem == "com.biily.parallax.ParallaxProbe"'
///
/// ⚠️ 所有插值都必须标 `privacy: .public`。os_log 默认把动态字符串打成 `<private>`，
/// 不标的话读到的会是一堆尖括号——这是这类日志最常见的坑。
let probeLogger = Logger(subsystem: "com.biily.parallax.ParallaxProbe", category: "probe")

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

/// 全部 13 项探针的测量结果。编号与 docs/api-facts-arkit-depth.md §6 一一对应。
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
        ProbeMeasurement(id: "P12", title: "双眼中点在相机空间的完整向量"),
        ProbeMeasurement(id: "P13", title: "界面方向与数据新鲜度")
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

    /// 把当前全部测量打进系统日志，供 Mac 侧实时读取。
    ///
    /// 单行输出（而非多行表格）是有意的：`log stream` 每条记录一行，
    /// 多行内容会被折叠得难以阅读，也不好用 grep 切。
    /// note 里的换行统一压成 `⏎`，保证一项一行。
    func logSnapshot(reason: String) {
        var lines = ["SNAPSHOT-BEGIN \(reason)"]
        for m in measurements {
            let flatNote = m.note
                .replacingOccurrences(of: "\n", with: "⏎")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(m.id) | \(m.title) | \(m.value) | \(flatNote)")
        }
        lines.append("SNAPSHOT-END \(reason)")
        let text = lines.joined(separator: "\n")

        // 两条通道各有各的用处，都留着：
        // print → stdout，由 `devicectl device process launch --console` 转发到 Mac 终端，
        //          这是命令行取数的通道。必须 fflush，否则 stdout 缓冲会让数据迟迟不出来。
        // Logger → 系统日志，Console.app 里能按 subsystem 过滤，事后回溯用。
        print(text)
        fflush(stdout)
        probeLogger.info("\(text, privacy: .public)")
    }
}
