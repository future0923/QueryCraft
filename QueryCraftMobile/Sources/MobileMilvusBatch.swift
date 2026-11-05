import QueryCraftMobileCore

actor MobileMilvusBatch {
    private(set) var value: WorkspaceDatabaseDataBatch?
    func receive(_ batch: WorkspaceDatabaseDataBatch) { value = batch }
}
