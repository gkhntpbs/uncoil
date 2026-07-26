import Foundation

/// Whether the first-run flow is on screen.
///
/// Onboarding is not a second window: it covers the main one completely and the
/// app appears underneath only once setup is finished or skipped. Two windows
/// meant the user could click the half-configured app behind the setup screen,
/// which is exactly the state the flow exists to get them out of.
@MainActor
final class OnboardingPresenter: ObservableObject {
    static let shared = OnboardingPresenter()

    @Published private(set) var isPresenting = false

    private init() {}

    func present() { isPresenting = true }
    func dismiss() { isPresenting = false }
}
