import Testing
@testable import QueryCraftFeature

struct WorkspaceReadOnlyQueryValidatorTests {
    @Test
    func acceptsSupportedStatementsWithCommentsAndQuotedSemicolons() throws {
        let sql = """
            -- inspect the current value
            SELECT 'first;second' AS value;
            # a trailing comment is still part of the same statement
            """

        let validated = try WorkspaceReadOnlyQueryValidator.validate(sql)

        #expect(validated == sql)
        #expect(
            try WorkspaceReadOnlyQueryValidator.validate("SHOW DATABASES")
                == "SHOW DATABASES"
        )
        #expect(
            try WorkspaceReadOnlyQueryValidator.validate("DESC `users`")
                == "DESC `users`"
        )
        let padded = " \nSELECT 1;\t "
        #expect(try WorkspaceReadOnlyQueryValidator.validate(padded) == padded)
    }

    @Test
    func rejectsOnlyEmptyInputBeforeDatabaseSubmission() {
        #expect(throws: WorkspaceReadOnlyQueryValidationError.empty) {
            try WorkspaceReadOnlyQueryValidator.validate("  \n")
        }
    }

    @Test
    func delegatesSyntaxAndStatementCountToTheDatabase() throws {
        for sql in [
            "BEGIN\nCOMMIT",
            "SELECT 1; SELECT 2",
            "UPDATE users SET active = 0",
            "SELECT 1 /*",
            "SELECT 'value",
        ] {
            #expect(try WorkspaceReadOnlyQueryValidator.validate(sql) == sql)
        }
    }

    @Test
    func rejectsServerFileWritesAndGatesExecutableComments() throws {
        #expect(throws: WorkspaceReadOnlyQueryValidationError.serverFileWrite) {
            try WorkspaceReadOnlyQueryValidator.validate(
                "SELECT * INTO OUTFILE '/tmp/querycraft-test' FROM users"
            )
        }
        #expect(throws: WorkspaceReadOnlyQueryValidationError.serverFileWrite) {
            try WorkspaceReadOnlyQueryValidator.validate(
                "SELECT * INTO OUTFILE '/tmp/querycraft-test' FROM users",
                policy: .writesAllowed
            )
        }
        #expect(
            throws: WorkspaceReadOnlyQueryValidationError
                .executableCommentRequiresWriteAccess
        ) {
            try WorkspaceReadOnlyQueryValidator.validate(
                "SELECT 1 /*!50000 SQL_NO_CACHE */"
            )
        }
        let executable = "SELECT 1 /*!50000 SQL_NO_CACHE */"
        #expect(
            try WorkspaceReadOnlyQueryValidator.validate(
                executable,
                policy: .writesAllowed
            ) == executable
        )
        #expect(throws: WorkspaceReadOnlyQueryValidationError.serverFileWrite) {
            try WorkspaceReadOnlyQueryValidator.validate(
                "SELECT 1 /*!50000 INTO OUTFILE '/tmp/querycraft-test' */",
                policy: .writesAllowed
            )
        }
    }

}
