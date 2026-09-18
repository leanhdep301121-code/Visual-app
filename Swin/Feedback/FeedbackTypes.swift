import Foundation

enum FeedbackSource: String, Codable, Sendable {
    case cloud, template, none
}

struct FeedbackTip: Codable, Sendable, Identifiable {
    var id: String { "\(event ?? "_")-\(metric ?? "_")-\(tip.prefix(20))" }
    let event: String?
    let userFrame: Int?
    let metric: String?
    let tip: String
    let cause: String
    let fix: String
    let drill: String?
}

struct FeedbackResponse: Codable, Sendable {
    let summary: String
    let eventTips: [FeedbackTip]
    let source: FeedbackSource
}

/// JSON payload sent to LLM. Now includes per-event joint angles so the LLM
/// can produce structured tips anchored to specific events + joints.
struct SignalsPayload: Codable, Sendable {
    let events: [Int]
    let handedness: String
    let metrics: SwingMetricsPayload?
    let perEvent: [PerEventMetrics]
    let captureFrameRate: Double
    let totalFrames: Int
}

struct SwingMetricsPayload: Codable, Sendable {
    let xFactor: Double
    let spineTilt: Double
    let tempoRatio: Double
    let hipTurn: Double
    let shoulderTurn: Double
}

extension SignalsPayload {
    init(report: SwingReport, captureFrameRate: Double = 60) {
        self.events = report.events.frames
        self.handedness = report.events.handedness == .right ? "right" : "left"
        self.metrics = report.metrics.map {
            SwingMetricsPayload(
                xFactor: $0.xFactor, spineTilt: $0.spineTilt, tempoRatio: $0.tempoRatio,
                hipTurn: $0.hipTurn, shoulderTurn: $0.shoulderTurn
            )
        }
        self.perEvent = report.perEvent
        self.captureFrameRate = captureFrameRate
        self.totalFrames = report.poseFrames.count
    }
}
