import CLibPQ
import Testing

struct PostgreSQLNativeClientVersionTests {
    @Test
    func bundledLibPQMatchesDeclaredVersion() {
        #expect(PQlibVersion() == 180006)
    }
}
