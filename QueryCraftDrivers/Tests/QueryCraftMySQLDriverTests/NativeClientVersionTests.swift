import CMariaDB
import Testing

struct MySQLNativeClientVersionTests {
    @Test
    func bundledConnectorMatchesDeclaredVersion() {
        #expect(MARIADB_PACKAGE_VERSION_ID == 30409)
        #expect(String(cString: mysql_get_client_info()) == "3.4.9")
    }
}
