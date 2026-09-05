import XCTest
@testable import Uncoil

/// The registry is the one place a provider fact is stated. These tests are
/// what makes that claim enforceable: they fail when a case is added without a
/// row, when a row contradicts itself, or when a fact drifts from the value the
/// rest of the app reads through `AgentProvider`.
final class AgentRegistryTests: XCTestCase {
    func testEveryProviderHasExactlyOneDescriptor() {
        XCTAssertEqual(AgentRegistry.all.count, AgentProvider.allCases.count)
        XCTAssertEqual(AgentRegistry.all.map(\.provider), AgentProvider.allCases)
        for provider in AgentProvider.allCases {
            XCTAssertEqual(AgentRegistry.descriptor(for: provider).provider, provider)
        }
    }

    func testProviderPropertiesReadTheDescriptor() {
        for provider in AgentProvider.allCases {
            let d = provider.descriptor
            XCTAssertEqual(provider.displayName, d.displayName)
            XCTAssertEqual(provider.launchCommand, d.launchCommand)
            XCTAssertEqual(provider.loginCommand, d.loginCommand)
            XCTAssertEqual(provider.isAgent, d.isAgent)
            XCTAssertEqual(provider.reportsStatusThroughHooks, d.statusSource == .hooks)
            XCTAssertEqual(provider.wiresControlPlane, d.controlPlane.isWired)
            XCTAssertEqual(provider.extensionScoping, d.extensionScoping)
            XCTAssertEqual(provider.hasBuiltInUpdater, d.hasBuiltInUpdater)
            XCTAssertEqual(provider.resumesConversation, d.resumesConversation)
            XCTAssertEqual(provider.defaultShiftEnterNewline, d.defaultShiftEnterNewline)
            XCTAssertEqual(AgentWorkingMode.options(for: provider), d.workingModes)
            XCTAssertEqual(AgentWorkingMode.unattended(for: provider), d.unattendedMode)
        }
    }

    /// A shell is not an agent, and every fact that only makes sense for an
    /// agent has to say so — this is the check that stopped a plain terminal
    /// from claiming a status, a control plane and an updater.
    func testTerminalClaimsNothingAnAgentWouldClaim() {
        let terminal = AgentProvider.terminal.descriptor
        XCTAssertFalse(terminal.isAgent)
        XCTAssertNil(terminal.launchCommand)
        XCTAssertNil(terminal.loginCommand)
        XCTAssertNil(terminal.cliBinaryName)
        XCTAssertNil(terminal.extensionAgentID)
        XCTAssertEqual(terminal.statusSource, .none)
        XCTAssertEqual(terminal.controlPlane, .none)
        XCTAssertEqual(terminal.extensionScoping, .none)
        XCTAssertFalse(terminal.hasBuiltInUpdater)
        XCTAssertFalse(terminal.resumesConversation)
        XCTAssertEqual(terminal.workingModes, [.providerDefault])
    }

    func testEveryAgentIsLaunchableAndDetectable() {
        for descriptor in AgentRegistry.agents {
            XCTAssertNotNil(
                descriptor.launchCommand,
                "\(descriptor.provider) runs an agent, so it needs a command to run"
            )
            XCTAssertNotNil(
                descriptor.cliBinaryName,
                "\(descriptor.provider) cannot be detected without a binary to look for"
            )
            XCTAssertNotNil(descriptor.defaultConfigDirectory)
            XCTAssertTrue(
                descriptor.workingModes.contains(.providerDefault),
                "every agent must be startable in its own default mode"
            )
            XCTAssertTrue(
                descriptor.workingModes.contains(descriptor.unattendedMode),
                "the unattended mode has to be one the agent actually offers"
            )
        }
    }

    /// Handing a session the control socket while nothing serves it looks like
    /// a broken socket rather than a missing feature, so the two have to agree.
    func testOnlyAgentsWireAControlPlaneOrScopeExtensions() {
        for descriptor in AgentRegistry.all where !descriptor.isAgent {
            XCTAssertFalse(descriptor.controlPlane.isWired)
            XCTAssertFalse(descriptor.extensionScoping.scopesMCPServers)
        }
    }

    func testExtensionAgentIDsMapBackOntoDistinctProviders() {
        let mapped = AgentRegistry.all.compactMap(\.extensionAgentID)
        XCTAssertEqual(Set(mapped).count, mapped.count, "two providers cannot share one extension agent")
        for id in ExtensionAgentID.allCases {
            guard let provider = id.provider else {
                XCTAssertEqual(id, .amp, "only Amp has no provider Uncoil launches")
                continue
            }
            XCTAssertEqual(provider.descriptor.extensionAgentID, id)
            XCTAssertEqual(id.displayName, provider.descriptor.fullName)
            XCTAssertEqual(id.cliBinaryName, provider.descriptor.cliBinaryName)
            XCTAssertEqual(id.defaultConfigDirectory, provider.descriptor.defaultConfigDirectory)
        }
    }
}
