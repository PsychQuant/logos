import Testing
import Foundation
@testable import Logos

@Suite("PDFLivePreviewModel", .serialized)
@MainActor
struct PDFLivePreviewModelTests {

    @Test("starts idle")
    func startsIdle() {
        let m = PDFLivePreviewModel()
        guard case .idle = m.state else {
            Issue.record("Expected .idle, got \(m.state)")
            return
        }
    }

    @Test("unsupported extension goes to idle with reason")
    func unsupportedExt() {
        let m = PDFLivePreviewModel()
        m.bind(sourcePath: "/tmp/notes.txt", config: nil)
        if case .idle(let reason) = m.state {
            #expect(reason != nil)
        } else {
            Issue.record("Expected .idle with reason")
        }
    }

    @Test("clears binding returns to idle")
    func unbind() {
        let m = PDFLivePreviewModel()
        m.unbind()
        guard case .idle = m.state else {
            Issue.record("Expected .idle after unbind")
            return
        }
        #expect(m.activeSourcePath == nil)
    }
}
