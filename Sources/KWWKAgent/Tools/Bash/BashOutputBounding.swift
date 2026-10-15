import Foundation
import KWWKAI

/// Bound bash output before it enters the transcript. Command output is most
/// useful at the tail (errors and summaries land at the end), so keep the last
/// lines/bytes within the read tool's budget. Callers that keep a full copy on
/// disk (the flip/background paths) still expose it via the output file; this
/// only bounds what the model sees inline, and is not duplicated into `details`.
func boundBashOutput(_ text: String) -> String {
    boundBashOutputDetailed(text).text
}

/// `boundBashOutput` plus the truncation verdict, so callers holding the raw
/// artifact on disk can decide whether to keep it. When `fullOutputPath` is
/// given, the truncation notice points the model at that file — a first
/// compile error buried mid-log is one `grep` away instead of unreachable.
func boundBashOutputDetailed(
    _ text: String,
    fullOutputPath: String? = nil
) -> (text: String, truncated: Bool) {
    let result = Truncate.truncateTail(text)
    guard result.truncated else { return (result.content, false) }
    let omitted = result.totalLines - result.outputLines
    var notice = "[output truncated: \(omitted) earlier line(s) omitted; showing last "
        + "\(result.outputLines) of \(result.totalLines) lines, "
        + "\(Truncate.formatSize(result.totalBytes)) total"
    if let fullOutputPath {
        notice += "; full output kept at \(fullOutputPath) — grep that file to reach "
            + "the omitted middle, e.g. grep -n \"error:\" \(bashShellQuote(fullOutputPath))"
    }
    notice += "]\n"
    return (notice + result.content, true)
}
