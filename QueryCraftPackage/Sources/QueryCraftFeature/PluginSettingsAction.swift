enum PluginSettingsAction: Equatable, Sendable {
    case install(DatabaseType)
    case update(DatabaseType)
    case uninstall(DatabaseType)
}
