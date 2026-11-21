import Testing
import Foundation
@testable import LobsterOne

@MainActor @Test func debugLogCircularBuffer() {
    let log = DebugLog()
    for i in 1...60 {
        log.log("Entry \(i)")
    }
    #expect(log.entries.count == 50)
    #expect(log.entries.first?.message == "Entry 11")
    #expect(log.entries.last?.message == "Entry 60")
}

@MainActor @Test func debugLogFormatted() {
    let log = DebugLog()
    log.log("Hello")
    log.log("World")
    let output = log.formatted
    #expect(output.contains("Hello"))
    #expect(output.contains("World"))
    #expect(output.contains("] "))
}

@Test func debugLogFlagsErrorLines() {
    #expect(DebugLogView.isError("Pace notification failed: denied"))
    #expect(DebugLogView.isError("[ClaudeScanner] Uploaded batch — HTTP 502, imported=0"))
    #expect(!DebugLogView.isError("[ClaudeScanner] Uploaded batch — HTTP 200, imported=1"))
    #expect(!DebugLogView.isError("Anthropic quota OK: 5h=72%, 7d=67%"))
}
