import XCTest

final class QueryCraftUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeWindowShowsCreateConnection() throws {
        let app = launchApp()

        XCTAssertTrue(app.buttons["createConnectionButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["emptyConnectionProfilesMessage"].exists)
    }

    @MainActor
    func testCreatesConnectionProfile() throws {
        let app = launchApp()

        app.buttons["createConnectionButton"].click()

        let nameField = app.textFields["connectionNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.typeText("Local MySQL")

        app.buttons["saveConnectionButton"].click()

        XCTAssertTrue(
            app.descendants(matching: .any)["connectionProfileRow"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.staticTexts["emptyConnectionProfilesMessage"].exists)
    }

    @MainActor
    func testConnectionReportsSuccess() throws {
        let app = launchApp()

        app.buttons["createConnectionButton"].click()

        let testButton = app.buttons["testConnectionButton"]
        XCTAssertTrue(testButton.waitForExistence(timeout: 5))
        testButton.click()

        XCTAssertTrue(
            app.staticTexts["connectionTestSuccess"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testEditingConnectionPrefillsSavedProfile() throws {
        let app = launchApp(seededProfile: true)

        let profile = app.descendants(matching: .any)["connectionProfileRow"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.rightClick()

        let editMenuItem = app.menuItems["Edit"].exists
            ? app.menuItems["Edit"]
            : app.menuItems["编辑"]
        XCTAssertTrue(editMenuItem.waitForExistence(timeout: 5))
        editMenuItem.click()

        let nameField = app.textFields["connectionNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        XCTAssertEqual(nameField.value as? String, "Local MySQL")
        XCTAssertEqual(
            app.textFields["connectionHostField"].value as? String,
            "db.internal.test"
        )
        XCTAssertEqual(
            app.textFields["connectionPortField"].value as? String,
            "4407"
        )
        XCTAssertEqual(
            app.textFields["connectionUsernameField"].value as? String,
            "querycraft_editor"
        )
        XCTAssertEqual(
            app.textFields["defaultDatabaseField"].value as? String,
            "saved_database"
        )
    }

    @MainActor
    func testOpensWorkspaceAndLoadsDatabaseList() throws {
        let app = launchApp(seededProfile: true)

        let profile = app.descendants(matching: .any)["connectionProfileRow"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.doubleClick()

        let openDatabase = app.buttons["openDatabaseButton"].firstMatch
        XCTAssertTrue(openDatabase.waitForExistence(timeout: 5))
        openDatabase.click()
        let database = app.descendants(matching: .any)[
            "databasePicker.app_database"
        ]
        XCTAssertTrue(database.waitForExistence(timeout: 5))
        database.doubleClick()

        let tables = app.descendants(matching: .any)[
            "databaseObjectGroup.app_database.table"
        ]
        XCTAssertTrue(tables.waitForExistence(timeout: 5))
        tables.click()

        let users = app.descendants(matching: .any)[
            "databaseObject.app_database.users"
        ]
        XCTAssertTrue(
            users.waitForExistence(timeout: 5)
        )
        users.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectData"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["1-2 of 2 rows"].waitForExistence(timeout: 5)
        )

        let idHeader = app.descendants(matching: .any)[
            "databaseDataColumnHeader.0"
        ]
        XCTAssertTrue(idHeader.waitForExistence(timeout: 5))
        clickCenter(of: idHeader)
        expectation(
            for: NSPredicate(format: "value == %@", "Ascending"),
            evaluatedWith: idHeader
        )
        waitForExpectations(timeout: 5)
        clickCenter(of: idHeader)
        expectation(
            for: NSPredicate(format: "value == %@", "Descending"),
            evaluatedWith: idHeader
        )
        waitForExpectations(timeout: 5)

        XCTAssertTrue(idHeader.waitForExistence(timeout: 5))
        clickCenter(of: idHeader)
        expectation(
            for: NSPredicate(format: "value == %@", "Unsorted"),
            evaluatedWith: idHeader
        )
        waitForExpectations(timeout: 5)

        app.radioButtons["Structure"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectStructure"]
                .waitForExistence(timeout: 5)
        )

        app.radioButtons["Indexes"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectIndexes"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["PRIMARY"].exists)

        app.radioButtons["DDL"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectDDL"]
                .waitForExistence(timeout: 5)
        )

        app.radioButtons["Data"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectData"]
                .waitForExistence(timeout: 5)
        )

        app.radioButtons["Structure"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectStructure"]
                .waitForExistence(timeout: 2)
        )

        app.buttons["openDatabaseButton"].firstMatch.click()
        let mysql = app.descendants(matching: .any)["databasePicker.mysql"]
        XCTAssertTrue(mysql.waitForExistence(timeout: 5))
        mysql.doubleClick()

        let appContext = app.descendants(matching: .any)[
            "databaseContext.app_database"
        ]
        let mysqlContext = app.descendants(matching: .any)[
            "databaseContext.mysql"
        ]
        XCTAssertTrue(appContext.waitForExistence(timeout: 5))
        XCTAssertTrue(mysqlContext.exists)

        appContext.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["databaseObjectStructure"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testWorkspaceSidebarAndConnectionSwitcher() throws {
        let app = launchApp(seededProfile: true, multipleProfiles: true)

        let profile = app.descendants(matching: .any)["connectionProfileRow"]
            .firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.doubleClick()

        let sidebar = app.descendants(matching: .any)["objectBrowser"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))
        let sidebarToggle = app.buttons["workspaceSidebarToggleButton"]
            .firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5))
        let switchConnection = app.buttons["switchConnectionButton"].firstMatch
        let openDatabase = app.buttons["openDatabaseButton"].firstMatch
        XCTAssertTrue(switchConnection.exists)
        XCTAssertTrue(openDatabase.exists)
        XCTAssertLessThan(sidebarToggle.frame.midX, switchConnection.frame.midX)
        XCTAssertLessThan(switchConnection.frame.midX, openDatabase.frame.midX)
        XCTAssertLessThanOrEqual(openDatabase.frame.maxX, sidebar.frame.maxX)
        sidebarToggle.click()

        XCTAssertFalse(sidebar.exists)
        XCTAssertTrue(sidebarToggle.exists)
        sidebarToggle.click()
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        switchConnection.click()

        let alternateProfile = app.descendants(matching: .any)[
            "connectionPicker.2D99D3D3-B0B8-4B44-AAD6-37C087CD4F08"
        ]
        XCTAssertTrue(alternateProfile.waitForExistence(timeout: 5))
        alternateProfile.doubleClick()

        XCTAssertTrue(
            app.buttons.matching(identifier: "switchConnectionButton")
                .element(boundBy: 1)
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    private func launchApp(
        seededProfile: Bool = false,
        multipleProfiles: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launchEnvironment["QUERYCRAFT_UI_TESTING"] = "1"
        if seededProfile {
            app.launchEnvironment["QUERYCRAFT_UI_TEST_SEEDED_PROFILE"] = "1"
        }
        if multipleProfiles {
            app.launchEnvironment["QUERYCRAFT_UI_TEST_MULTIPLE_PROFILES"] = "1"
        }
        app.launch()
        return app
    }

    private func clickCenter(of element: XCUIElement) {
        element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
    }

}
