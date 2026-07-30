import Testing
@testable import LogosGateway

@Suite struct GatewayModuleTests {

    /// The module exists and is importable. This is the scaffold's only claim;
    /// real behavior arrives in later tasks.
    @Test func moduleIsImportable() {
        #expect(GatewayLog.subsystem == "app.getlogos.logos")
    }
}
