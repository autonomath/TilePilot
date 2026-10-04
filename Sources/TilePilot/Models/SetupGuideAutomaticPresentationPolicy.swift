enum SetupGuideAutomaticPresentationPolicy {
    static func shouldPresentImmediatelyOnFirstLaunch(initialSetupLandingShown: Bool) -> Bool {
        !initialSetupLandingShown
    }

    static func shouldPresent(
        startupGraceElapsed: Bool,
        hasBootstrapSnapshot: Bool,
        hasDoctorSnapshot: Bool,
        hasIncompleteEssentialSteps: Bool,
        dismissedThisSession: Bool
    ) -> Bool {
        startupGraceElapsed
            && hasBootstrapSnapshot
            && hasDoctorSnapshot
            && hasIncompleteEssentialSteps
            && !dismissedThisSession
    }
}
