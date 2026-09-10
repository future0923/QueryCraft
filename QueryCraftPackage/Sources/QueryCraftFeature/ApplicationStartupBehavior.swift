enum ApplicationStartupBehavior: String, CaseIterable, Identifiable {
    case restoreWorkspaces
    case showWelcomeWindow

    var id: Self { self }

}
