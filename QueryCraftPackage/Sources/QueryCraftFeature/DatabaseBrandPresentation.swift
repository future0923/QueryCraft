import CoreGraphics

struct DatabaseBrandPresentation: Equatable, Sendable {
    let assetName: String
    let opticalScale: CGFloat
    let darkModeBrightness: Double
    let contrast: Double

    static let mysql = DatabaseBrandPresentation(
        assetName: "DatabaseBrandMySQL",
        opticalScale: 1.15,
        darkModeBrightness: 0.10,
        contrast: 1.12
    )

    static let postgreSQL = DatabaseBrandPresentation(
        assetName: "DatabaseBrandPostgreSQL",
        opticalScale: 1,
        darkModeBrightness: 0.16,
        contrast: 1.04
    )

    static let apacheDoris = DatabaseBrandPresentation(
        assetName: "DatabaseBrandApacheDoris",
        opticalScale: 1.08,
        darkModeBrightness: 0.05,
        contrast: 1.04
    )

    static let selectDB = DatabaseBrandPresentation(
        assetName: "DatabaseBrandSelectDB",
        opticalScale: 0.84,
        darkModeBrightness: 0,
        contrast: 1
    )

    static let redis = DatabaseBrandPresentation(
        assetName: "DatabaseBrandRedis",
        opticalScale: 0.92,
        darkModeBrightness: 0.08,
        contrast: 1.04
    )

    static let elasticsearch = DatabaseBrandPresentation(
        assetName: "DatabaseBrandElasticsearch",
        opticalScale: 0.94,
        darkModeBrightness: 0.06,
        contrast: 1.04
    )
}
