/// Shared, bounded sampling for desktop and touch grids. Never scan every row to size a column.
public enum WorkspaceGridSampling {
    public static let minimumColumnWidth = 60.0
    public static let maximumAutomaticColumnWidth = 480.0
    public static let sampleRowCount = 30
    public static let wideGridSampleRowCount = 10
    public static let wideGridColumnThreshold = 50
    public static let maximumMeasuredCharacters = 50

    public static func sampleIndexes(rowCount: Int, columnCount: Int) -> [Int] {
        guard rowCount > 0 else { return [] }
        let maximumSamples = columnCount > wideGridColumnThreshold
            ? wideGridSampleRowCount
            : sampleRowCount
        guard rowCount > maximumSamples else {
            return Array(0..<rowCount)
        }
        let leadingSampleCount = maximumSamples / 2
        let distributedSampleCount = maximumSamples - leadingSampleCount
        var indexes = Array(0..<leadingSampleCount)
        guard distributedSampleCount > 1 else {
            indexes.append(rowCount - 1)
            return indexes
        }

        indexes.append(contentsOf: (0..<distributedSampleCount).map {
            sampleIndex in
            leadingSampleCount
                + sampleIndex * (rowCount - 1 - leadingSampleCount)
                    / (distributedSampleCount - 1)
        })
        return indexes
    }
}
