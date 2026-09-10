public actor LicenseAccessGate {
    public static let shared = LicenseAccessGate()

    func update(for _: LicenseState) {}

    public func requireDatabaseAccess() throws {}
}
