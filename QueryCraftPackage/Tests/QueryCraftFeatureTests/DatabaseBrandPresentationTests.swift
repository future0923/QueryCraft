import Testing
@testable import QueryCraftFeature

struct DatabaseBrandPresentationTests {
    @Test func databaseTypesUseTheirMatchingBrandAssets() {
        #expect(DatabaseType.mysql.brandAssetName == "DatabaseBrandMySQL")
        #expect(
            DatabaseType.postgresql.brandAssetName
                == "DatabaseBrandPostgreSQL"
        )
        #expect(
            DatabaseType.doris.brandAssetName
                == "DatabaseBrandApacheDoris"
        )
        #expect(DatabaseType.redis.brandAssetName == "DatabaseBrandRedis")
        #expect(
            DatabaseType.elasticsearch.brandAssetName
                == "DatabaseBrandElasticsearch"
        )
    }

    @Test func dorisProductsKeepDistinctBrandAssets() {
        #expect(
            DatabaseProduct.apacheDoris.brandAssetName
                == "DatabaseBrandApacheDoris"
        )
        #expect(
            DatabaseProduct.selectDB.brandAssetName
                == "DatabaseBrandSelectDB"
        )
    }

    @Test func opticalScalesBalanceSmallBrandMarks() {
        #expect(DatabaseBrandPresentation.mysql.opticalScale > 1)
        #expect(DatabaseBrandPresentation.apacheDoris.opticalScale > 1)
        #expect(DatabaseBrandPresentation.postgreSQL.opticalScale == 1)
        #expect(DatabaseBrandPresentation.selectDB.opticalScale < 0.9)
    }

    @Test func darkModeCompensationTargetsLowContrastBrands() {
        #expect(DatabaseBrandPresentation.mysql.darkModeBrightness > 0)
        #expect(
            DatabaseBrandPresentation.postgreSQL.darkModeBrightness
                > DatabaseBrandPresentation.mysql.darkModeBrightness
        )
        #expect(DatabaseBrandPresentation.selectDB.darkModeBrightness == 0)
    }
}
