import Testing
@testable import Logos

@Suite("StatusBarViewModel", .serialized)
@MainActor
struct StatusBarViewModelTests {

    @Test("default account name is placeholder")
    func defaultAccount() {
        let vm = StatusBarViewModel()
        #expect(vm.accountName == "personal")
    }

    @Test("default cost is zero formatted")
    func defaultCost() {
        let vm = StatusBarViewModel()
        #expect(vm.sessionCostFormatted == "$0.00")
    }

    @Test("default auto-handle is armed")
    func defaultAutoHandle() {
        let vm = StatusBarViewModel()
        #expect(vm.autoHandleStatus == .armed)
    }

    @Test("token usage formats with k suffix")
    func tokenFormat() {
        let vm = StatusBarViewModel()
        vm.tokensUsed = 12_345
        vm.tokensMax = 200_000
        #expect(vm.tokenUsageFormatted == "12k / 200k")
    }

    @Test("zero tokens still formats correctly")
    func zeroTokensFormat() {
        let vm = StatusBarViewModel()
        #expect(vm.tokenUsageFormatted == "0 / 200k")
    }

    @Test("auto-handle status has three cases")
    func autoHandleCases() {
        #expect(StatusBarViewModel.AutoHandleStatus.allCases.count == 3)
    }
}
