import AppKit
import Observation
import Synchronization
import SwiftUI
import Testing
@testable import QueryCraftFeature

struct RedisWorkspaceFeatureTests {
    @Test
    func commandParserPreservesQuotedAndEscapedArguments() async throws {
        let invocation = try await RedisCommandParser().parse(
            "SET user:1 \"Ada Lovelace\" EX 60"
        )

        #expect(invocation.arguments == [
            "SET", "user:1", "Ada Lovelace", "EX", "60",
        ])
    }

    @Test
    func commandParserPreservesEmptyQuotedArgument() async throws {
        let invocation = try await RedisCommandParser().parse("SET empty \"\"")

        #expect(invocation.arguments == ["SET", "empty", ""])
    }

    @MainActor
    @Test
    func redisCodeInputDisablesSmartTextSubstitutions() {
        let textView = NSTextView()
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.smartInsertDeleteEnabled = true

        textView.configureForCodeInput()

        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
    }

    @Test
    func redisKeySearchModesEscapeGlobCharacters() {
        let chinese = AppCopy(language: .simplifiedChinese)
        let english = AppCopy(language: .english)

        #expect(RedisKeySearchMatchMode.contains.title(using: chinese) == "包含")
        #expect(RedisKeySearchMatchMode.contains.title(using: english) == "Contains")
        #expect(RedisKeySearchMatchMode.prefix.title(using: chinese) == "前缀")
        #expect(RedisKeySearchMatchMode.prefix.title(using: english) == "Prefix")
        #expect(RedisKeySearchMatchMode.exact.title(using: chinese) == "精确")
        #expect(RedisKeySearchMatchMode.exact.title(using: english) == "Exact")
        #expect(
            RedisKeySearchMatchMode.contains.scanPattern(for: "user:*")
                == "user:*"
        )
        #expect(
            RedisKeySearchMatchMode.contains.scanPattern(for: "user")
                == "*user*"
        )
        #expect(
            RedisKeySearchMatchMode.prefix.scanPattern(for: "user:?")
                == "user:\\?*"
        )
        #expect(
            RedisKeySearchMatchMode.exact.scanPattern(for: "[user]")
                == "\\[user\\]"
        )
        #expect(
            RedisKeySearchMatchMode.contains.scanPattern(for: "") == nil
        )
    }

    @Test
    func redisKeyScanLoaderLoadsOnlyOnePageWhenRequested() async throws {
        let probe = RedisKeyScanProbe(
            pages: [
                0: RedisKeyScanPage(
                    nextCursor: 8,
                    keys: [
                        RedisKeyReference(databaseIndex: 0, name: "user:1"),
                    ]
                ),
                8: RedisKeyScanPage(
                    nextCursor: 0,
                    keys: [
                        RedisKeyReference(databaseIndex: 0, name: "user:2"),
                    ]
                ),
            ]
        )

        let result = try await RedisKeyScanLoader().load(
            existingKeys: [],
            cursor: 0,
            search: RedisKeySearchRequest(text: "user", mode: .prefix),
            databaseIndex: 0,
            scope: .nextPage,
            fetchPage: { cursor, pattern, count in
                try await probe.fetchPage(
                    cursor: cursor,
                    pattern: pattern,
                    count: count
                )
            },
            exactLookup: { key in await probe.exactLookup(key) },
            progress: { progress in await probe.record(progress) }
        )

        #expect(result.nextCursor == 8)
        #expect(result.keys.map(\.name) == ["user:1"])
        #expect(await probe.requestedCursors == [0])
        #expect(await probe.requestedPatterns == ["user*"])
        #expect(await probe.requestedCounts == [10_000])
    }

    @Test
    func unfilteredRedisKeyPageKeepsTheBoundedScanCount() async throws {
        let probe = RedisKeyScanProbe(
            pages: [
                0: RedisKeyScanPage(
                    nextCursor: 8,
                    keys: [
                        RedisKeyReference(databaseIndex: 0, name: "user:1"),
                    ]
                ),
            ]
        )

        _ = try await RedisKeyScanLoader().load(
            existingKeys: [],
            cursor: 0,
            search: RedisKeySearchRequest(text: "", mode: .contains),
            databaseIndex: 0,
            scope: .nextPage,
            fetchPage: { cursor, pattern, count in
                try await probe.fetchPage(
                    cursor: cursor,
                    pattern: pattern,
                    count: count
                )
            },
            exactLookup: { key in await probe.exactLookup(key) },
            progress: { progress in await probe.record(progress) }
        )

        #expect(await probe.requestedCursors == [0])
        #expect(await probe.requestedPatterns == [nil])
        #expect(await probe.requestedCounts == [500])
    }

    @Test
    func redisKeyScanLoaderFollowsAllCursorsAndDeduplicatesKeys() async throws {
        let probe = RedisKeyScanProbe(
            pages: [
                0: RedisKeyScanPage(
                    nextCursor: 8,
                    keys: [
                        RedisKeyReference(databaseIndex: 0, name: "user:1"),
                        RedisKeyReference(databaseIndex: 0, name: "user:2"),
                    ]
                ),
                8: RedisKeyScanPage(
                    nextCursor: 0,
                    keys: [
                        RedisKeyReference(databaseIndex: 0, name: "user:2"),
                        RedisKeyReference(databaseIndex: 0, name: "user:3"),
                    ]
                ),
            ]
        )

        let result = try await RedisKeyScanLoader().load(
            existingKeys: [],
            cursor: 0,
            search: RedisKeySearchRequest(text: "user", mode: .contains),
            databaseIndex: 0,
            scope: .allRemaining,
            fetchPage: { cursor, pattern, count in
                try await probe.fetchPage(
                    cursor: cursor,
                    pattern: pattern,
                    count: count
                )
            },
            exactLookup: { key in
                await probe.exactLookup(key)
            },
            progress: { progress in
                await probe.record(progress)
            }
        )

        #expect(result.nextCursor == 0)
        #expect(result.keys.map(\.name) == ["user:1", "user:2", "user:3"])
        #expect(await probe.requestedCursors == [0, 8])
        #expect(await probe.requestedPatterns == ["*user*", "*user*"])
        #expect(await probe.requestedCounts == [10_000, 10_000])
        #expect(await probe.progressCounts == [2, 3])
    }

    @Test
    func matchingRedisKeyPageContinuesAcrossEmptyScanBatches() async throws {
        let probe = RedisKeyScanProbe(
            pages: [
                0: RedisKeyScanPage(nextCursor: 8, keys: []),
                8: RedisKeyScanPage(nextCursor: 13, keys: []),
                13: RedisKeyScanPage(
                    nextCursor: 0,
                    keys: [
                        RedisKeyReference(
                            databaseIndex: 10,
                            name: "querycraft:edit-demo:string"
                        ),
                    ]
                ),
            ]
        )

        let result = try await RedisKeyScanLoader().load(
            existingKeys: [],
            cursor: 0,
            search: RedisKeySearchRequest(
                text: "querycraft:edit-demo",
                mode: .prefix
            ),
            databaseIndex: 10,
            scope: .matchingPage,
            fetchPage: { cursor, pattern, count in
                try await probe.fetchPage(
                    cursor: cursor,
                    pattern: pattern,
                    count: count
                )
            },
            exactLookup: { key in await probe.exactLookup(key) },
            progress: { progress in await probe.record(progress) }
        )

        #expect(result.nextCursor == 0)
        #expect(result.keys.map(\.name) == [
            "querycraft:edit-demo:string",
        ])
        #expect(await probe.requestedCursors == [0, 8, 13])
        #expect(await probe.requestedPatterns == [
            "querycraft:edit-demo*",
            "querycraft:edit-demo*",
            "querycraft:edit-demo*",
        ])
        #expect(await probe.requestedCounts == [10_000, 10_000, 10_000])
        #expect(await probe.progressCounts == [0, 0, 1])
    }

    @Test
    func exactRedisKeySearchUsesExistsWithoutScanning() async throws {
        let probe = RedisKeyScanProbe(pages: [:], existingKeys: ["user:42"])

        let result = try await RedisKeyScanLoader().load(
            existingKeys: [],
            cursor: 0,
            search: RedisKeySearchRequest(text: "user:42", mode: .exact),
            databaseIndex: 3,
            scope: .allRemaining,
            fetchPage: { cursor, pattern, count in
                try await probe.fetchPage(
                    cursor: cursor,
                    pattern: pattern,
                    count: count
                )
            },
            exactLookup: { key in
                await probe.exactLookup(key)
            },
            progress: { progress in
                await probe.record(progress)
            }
        )

        #expect(result.keys == [
            RedisKeyReference(databaseIndex: 3, name: "user:42"),
        ])
        #expect(await probe.requestedCursors.isEmpty)
        #expect(await probe.exactLookups == ["user:42"])
        #expect(await probe.progressCounts == [1])
    }

    @Test
    func commandLineSnapshotTracksHSETArgumentsAndRepeatingPairs() throws {
        let key = RedisCommandLineSnapshot(source: "HSET ")
        let field = RedisCommandLineSnapshot(source: "HSET user:1 ")
        let value = RedisCommandLineSnapshot(source: "HSET user:1 name ")
        let repeatedField = RedisCommandLineSnapshot(
            source: "HSET user:1 name Ada "
        )
        let repeatedValue = RedisCommandLineSnapshot(
            source: "HSET user:1 name Ada role "
        )

        #expect(key.activeArgumentIndex == 0)
        #expect(try #require(key.entry?.argument(at: 0)).name == "key")
        #expect(field.activeArgumentIndex == 1)
        #expect(try #require(field.entry?.argument(at: 1)).name == "field")
        #expect(value.activeArgumentIndex == 2)
        #expect(try #require(value.entry?.argument(at: 2)).name == "value")
        #expect(try #require(repeatedField.entry?.argument(at: 3)).name == "field")
        #expect(try #require(repeatedValue.entry?.argument(at: 4)).name == "value")
    }

    @Test
    func keyTreeBuildsColonSeparatedPrefixGroupsOffMainActor() async {
        let keys = [
            RedisKeyReference(databaseIndex: 0, name: "rate_limit:chat_im:a"),
            RedisKeyReference(databaseIndex: 0, name: "rate_limit:chat_im:b"),
            RedisKeyReference(databaseIndex: 0, name: "default"),
        ]

        let nodes = await RedisKeyTreeBuilder().build(
            keys: keys,
            matching: ""
        )

        #expect(nodes.count == 2)
        let prefix = nodes.first { $0.title == "rate_limit" }
        let leaf = nodes.first { $0.title == "default" }
        #expect(prefix?.keyCount == 2)
        #expect(prefix?.children.first?.title == "chat_im")
        #expect(prefix?.children.first?.children.count == 2)
        #expect(leaf?.keyCount == 1)
    }

    @Test
    func keyTreeSearchKeepsMatchingKeysInTheirPrefixGroups() async {
        let keys = [
            RedisKeyReference(databaseIndex: 2, name: "users:active:42"),
            RedisKeyReference(databaseIndex: 2, name: "users:blocked:7"),
        ]

        let nodes = await RedisKeyTreeBuilder().build(
            keys: keys,
            matching: "active"
        )

        #expect(nodes.count == 1)
        #expect(nodes[0].keyCount == 1)
        #expect(nodes[0].children.map(\.title) == ["active"])
    }

    @Test
    func keyTreeInterimSearchUsesTheSubmittedMatchMode() async {
        let keys = [
            RedisKeyReference(databaseIndex: 2, name: "query:exact"),
            RedisKeyReference(databaseIndex: 2, name: "query:exact:child"),
            RedisKeyReference(databaseIndex: 2, name: "other:query:exact"),
        ]
        let builder = RedisKeyTreeBuilder()

        let exact = await builder.build(
            keys: keys,
            matching: RedisKeySearchRequest(text: "query:exact", mode: .exact)
        )
        let prefix = await builder.build(
            keys: keys,
            matching: RedisKeySearchRequest(text: "query", mode: .prefix)
        )

        #expect(exact.keyReferences.map(\.name) == ["query:exact"])
        #expect(prefix.keyReferences.map(\.name).sorted() == [
            "query:exact",
            "query:exact:child",
        ])
    }

    @Test
    func keyTreeInterimSearchDefersGlobMatchingToRedis() async {
        let nodes = await RedisKeyTreeBuilder().build(
            keys: [
                RedisKeyReference(databaseIndex: 2, name: "query:one"),
                RedisKeyReference(databaseIndex: 2, name: "query:two"),
            ],
            matching: RedisKeySearchRequest(text: "query:*", mode: .contains)
        )

        #expect(nodes.isEmpty)
    }

    @Test
    func keyTreePrefixesNeverAppearSelectedWithoutAKeySelection() async throws {
        let reference = RedisKeyReference(
            databaseIndex: 0,
            name: "rate_limit:chat_im:groupApi"
        )
        let nodes = await RedisKeyTreeBuilder().build(
            keys: [reference],
            matching: ""
        )
        let prefix = try #require(nodes.first)
        let key = try #require(
            prefix.children.first?.children.first
        )

        #expect(!prefix.isSelected(nil))
        #expect(!prefix.isSelected(reference))
        #expect(!key.isSelected(nil))
        #expect(key.isSelected(reference))
    }

    @Test
    func keyTreeKeepsLargePrefixAsOneExpandableBranch() async throws {
        let keys = (0..<1_353).map { index in
            RedisKeyReference(
                databaseIndex: 10,
                name: "admin:user:\(index)"
            )
        }

        let nodes = await RedisKeyTreeBuilder().build(
            keys: keys,
            matching: ""
        )

        let admin = try #require(nodes.first)
        let user = try #require(admin.children.first)
        #expect(nodes.count == 1)
        #expect(admin.keyCount == 1_353)
        #expect(user.keyCount == 1_353)
        #expect(user.children.count == 1_353)
    }

    @MainActor
    @Test
    func multipleRedisKeysKeepIndependentContentTabs() {
        let tabs = WorkspaceContentTabsModel()
        let first = RedisKeyReference(databaseIndex: 0, name: "users:1")
        let second = RedisKeyReference(databaseIndex: 0, name: "users:2")

        tabs.open(first)
        tabs.open(second)
        tabs.open(first)

        #expect(tabs.contentItems.map(\.id) == [
            .redisKey(first),
            .redisKey(second),
        ])
        #expect(tabs.selectedContentID == .redisKey(first))
    }

    @MainActor
    @Test
    func redisKeyInspectorRegistryKeepsDetailsIndependentByTab() throws {
        let registry = WorkspaceInspectorRegistry()
        let first = RedisKeyReference(
            databaseIndex: 0,
            name: "users:1",
            type: .hash
        )
        let second = RedisKeyReference(
            databaseIndex: 0,
            name: "users:2",
            type: .string
        )
        let firstDetails = RedisKeyDetails(
            reference: first,
            ttlMilliseconds: nil,
            memoryUsageBytes: 176,
            encoding: "listpack",
            value: RedisKeyValueSnapshot(
                columns: ["field", "value"],
                rows: [["name", "Ada"]]
            )
        )
        let firstContext = WorkspaceRedisKeyInspectorContext(
            reference: first,
            details: firstDetails,
            errorMessage: nil,
            retry: {}
        )
        let secondContext = WorkspaceRedisKeyInspectorContext(
            reference: second,
            details: nil,
            errorMessage: nil,
            retry: {}
        )

        registry.update(.redisKey(firstContext), for: .redisKey(first))
        registry.update(.redisKey(secondContext), for: .redisKey(second))

        let storedFirst = try #require(
            registry.context(for: .redisKey(first))
        )
        let storedSecond = try #require(
            registry.context(for: .redisKey(second))
        )
        #expect(storedFirst == .redisKey(firstContext))
        #expect(storedSecond == .redisKey(secondContext))
        #expect(storedFirst.searchIdentity == "redis-key:0:users:1")
        #expect(storedSecond.searchIdentity == "redis-key:0:users:2")
    }

    @Test
    func safetyCatalogTreatsUnknownCommandsConservatively() {
        #expect(RedisCommandCatalog.entry(named: "GET")?.isReadOnly == true)
        #expect(RedisCommandCatalog.entry(named: "SET")?.isReadOnly == false)
        #expect(RedisCommandCatalog.entry(named: "CUSTOM") == nil)
        #expect(
            RedisCommandCatalog.entry(named: "HGET")?.compatibleKeyTypes
                == [.hash]
        )
        #expect(
            RedisCommandCatalog.entry(named: "DEL")?.compatibleKeyTypes == nil
        )
    }

    @Test
    func redisKeyIdentityDoesNotChangeWhenItsTypeIsResolved() {
        let unknown = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:test"
        )
        let resolved = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:test",
            type: .hash
        )

        #expect(unknown == resolved)
        #expect(Set([unknown, resolved]).count == 1)
        #expect(unknown.id == resolved.id)
    }

    @Test
    func redisKeyTypesUseCompactSidebarBadges() {
        let types: [RedisKeyType] = [
            .string, .hash, .list, .set, .sortedSet, .stream,
        ]

        #expect(Set(types.compactMap(\.sidebarBadgeText)).count == types.count)
        #expect(RedisKeyType.string.sidebarBadgeText == "str")
        #expect(RedisKeyType.sortedSet.sidebarBadgeText == "zset")
        #expect(RedisKeyType.unknown.sidebarBadgeText == nil)
    }

    @MainActor
    @Test
    func redisOutlineSelectionRemainsEmphasizedAfterFocusMovesAway() {
        let rowView = WorkspaceRedisKeyOutlineSelectionRowView()

        rowView.isEmphasized = false

        #expect(rowView.isEmphasized)
    }

    @Test
    func redisVisibleKeyTypeBatcherDoesNothingWhenDisabled() {
        var batcher = RedisVisibleKeyTypeBatcher(
            isEnabled: false,
            maximumBatchSize: 50
        )

        let didEnqueue = batcher.enqueue(RedisKeyReference(
            databaseIndex: 0,
            name: "querycraft:key"
        ))

        #expect(!didEnqueue)
        #expect(batcher.nextBatch().isEmpty)
    }

    @Test
    func redisVisibleKeyTypeBatcherLimitsAndContinuesBatches() {
        var batcher = RedisVisibleKeyTypeBatcher(
            isEnabled: true,
            maximumBatchSize: 2
        )
        let references = (0..<5).map { index in
            RedisKeyReference(
                databaseIndex: 0,
                name: "querycraft:key:\(index)"
            )
        }
        for reference in references {
            batcher.enqueue(reference)
        }

        let first = batcher.nextBatch()
        let second = batcher.nextBatch()
        let third = batcher.nextBatch()

        #expect(first.count == 2)
        #expect(second.count == 2)
        #expect(third.count == 1)
        #expect(Set(first + second + third) == Set(references))
        #expect(batcher.isEmpty)
    }

    @Test
    func disablingRedisVisibleKeyTypeBatcherClearsPendingKeys() {
        var batcher = RedisVisibleKeyTypeBatcher(
            isEnabled: true,
            maximumBatchSize: 50
        )
        batcher.enqueue(RedisKeyReference(
            databaseIndex: 0,
            name: "querycraft:key"
        ))

        batcher.configure(isEnabled: false, maximumBatchSize: 10)

        #expect(batcher.isEmpty)
        #expect(batcher.maximumBatchSize == 10)
        #expect(batcher.nextBatch().isEmpty)
    }

    @MainActor
    @Test
    func redisSearchOutlineExpandsFoldersAndNeverSelectsAStaleFolder() async throws {
        let first = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:edit-demo:first"
        )
        let second = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:edit-demo:second"
        )
        let builder = RedisKeyTreeBuilder()
        let firstTree = await builder.build(keys: [first], matching: "")
        let secondTree = await builder.build(keys: [second], matching: "")
        var selection: RedisKeyReference? = first
        let selectionBinding = Binding<RedisKeyReference?>(
            get: { selection },
            set: { selection = $0 }
        )
        let coordinator = WorkspaceRedisKeyOutlineCoordinator(
            nodes: firstTree,
            revision: 1,
            expandsAllItems: true,
            selection: selectionBinding,
            openKey: { _ in },
            renameKey: { _ in },
            copyKeyName: { _ in },
            deleteKey: { _ in }
        )
        let scrollView = coordinator.makeScrollView()
        let outlineView = try #require(
            scrollView.documentView as? WorkspaceRedisKeyOutlineNativeView
        )

        #expect(outlineView.numberOfRows == 3)
        #expect(outlineView.selectedRow == 2)
        let rootItem = try #require(outlineView.item(atRow: 0))
        let nestedItem = try #require(outlineView.item(atRow: 1))
        #expect(outlineView.isItemExpanded(rootItem))
        #expect(outlineView.isItemExpanded(nestedItem))
        let folderRow = try #require(
            coordinator.outlineView(
                outlineView,
                rowViewForItem: rootItem
            ) as? WorkspaceRedisKeyOutlineSelectionRowView
        )
        #expect(folderRow.suppressesSelectionHighlight)
        #expect(folderRow.interiorBackgroundStyle == .normal)

        coordinator.update(
            nodes: secondTree,
            revision: 2,
            expandsAllItems: true,
            selection: selectionBinding,
            openKey: { _ in },
            renameKey: { _ in },
            copyKeyName: { _ in },
            deleteKey: { _ in }
        )

        #expect(outlineView.numberOfRows == 3)
        #expect(outlineView.selectedRow == -1)
        #expect(selection == first)
    }

    @MainActor
    @Test
    func redisKeyOutlineContextMenuRenamesOnlyTheClickedKey() async throws {
        let reference = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:edit-demo:first"
        )
        let tree = await RedisKeyTreeBuilder().build(
            keys: [reference],
            matching: ""
        )
        var renamedReferences: [RedisKeyReference] = []
        let coordinator = WorkspaceRedisKeyOutlineCoordinator(
            nodes: tree,
            revision: 1,
            expandsAllItems: true,
            selection: .constant(nil),
            openKey: { _ in },
            renameKey: { renamedReferences.append($0) },
            copyKeyName: { _ in },
            deleteKey: { _ in },
            automaticallyResolvesKeyTypes: false
        )
        let scrollView = coordinator.makeScrollView()
        let outlineView = try #require(
            scrollView.documentView as? WorkspaceRedisKeyOutlineNativeView
        )

        #expect(outlineView.contextMenuForRow?(0) == nil)
        let keyRow = outlineView.numberOfRows - 1
        let menu = try #require(outlineView.contextMenuForRow?(keyRow))
        #expect(
            menu.items.map(\.title) == [
                AppCopy.current.text("打开 Key", "Open Key"),
                AppCopy.current.text("重命名 Key", "Rename Key"),
                AppCopy.current.text("复制 Key 名称", "Copy Key Name"),
                "",
                AppCopy.current.text("删除 Key", "Delete Key"),
            ]
        )
        let renameItem = menu.items[1]
        let action = try #require(renameItem.action)

        #expect(
            NSApp.sendAction(
                action,
                to: renameItem.target,
                from: renameItem
            )
        )
        #expect(renamedReferences == [reference])
    }

    @MainActor
    @Test
    func redisKeyActionRegistryDeliversPendingRenameToMatchingDetail() {
        let requestedReference = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:rename-me"
        )
        let otherReference = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:other"
        )
        let registry = WorkspaceRedisKeyActionRegistry()
        var requestedRenameCount = 0
        var otherRenameCount = 0

        registry.requestRename(for: requestedReference)
        registry.update(
            WorkspaceRedisKeyActions {
                otherRenameCount += 1
            },
            for: .redisKey(otherReference)
        )
        #expect(requestedRenameCount == 0)
        #expect(otherRenameCount == 0)

        registry.update(
            WorkspaceRedisKeyActions {
                requestedRenameCount += 1
            },
            for: .redisKey(requestedReference)
        )
        #expect(requestedRenameCount == 1)
        #expect(otherRenameCount == 0)

        registry.requestRename(for: requestedReference)
        #expect(requestedRenameCount == 2)
    }

    @Test
    func valueFormatterPrettyPrintsJSONAndRejectsPlainText() async {
        let formatter = RedisValueFormatter()

        let formatted = await formatter.formattedJSON(
            from: #"{"name":"QueryCraft","enabled":true}"#
        )

        #expect(formatted?.contains("\n") == true)
        #expect(formatted?.contains(#""enabled": true"#) == true)
        #expect(await formatter.formattedJSON(from: "plain text") == nil)
        #expect(await formatter.formattedJSON(from: "36") == nil)
    }

    @Test
    func redisCommandPreviewEscapesWhitespaceQuotesAndControlCharacters() {
        let invocation = RedisCommandInvocation(
            source: "",
            arguments: ["SET", "user name", "Ada \"Lovelace\"\n"]
        )

        #expect(
            RedisCommandPreviewFormatter.source(for: invocation)
                == #"SET "user name" "Ada \"Lovelace\"\n""#
        )
    }

    @Test
    func stringMutationUsesSetKeepTTLAndLeavesUnchangedTTLAlone() throws {
        let details = redisDetails(
            type: .string,
            ttlMilliseconds: 60_000,
            columns: ["value"],
            rows: [["before"]]
        )

        let plan = try RedisKeyMutationPlan.make(
            details: details,
            stringValue: "after",
            rows: [],
            expirationMode: .expires,
            ttlMillisecondsText: "60000"
        )

        #expect(plan.commands.map(\.arguments) == [
            ["SET", "querycraft:test", "after", "KEEPTTL"],
        ])
    }

    @Test
    func hashMutationBuildsOnlyRequiredDeletesAndSets() throws {
        let details = redisDetails(
            type: .hash,
            columns: ["field", "value"],
            rows: [["name", "Ada"], ["status", "active"]]
        )
        var name = RedisKeyEditableRow(
            isNew: false,
            firstValue: "name",
            secondValue: "Ada"
        )
        name.secondValue = "Ada Lovelace"
        let rows = [
            name,
            RedisKeyEditableRow(
                isNew: false,
                firstValue: "status",
                secondValue: "active",
                isDeleted: true
            ),
            RedisKeyEditableRow(
                isNew: true,
                firstValue: "plan",
                secondValue: "pro"
            ),
        ]

        let plan = try RedisKeyMutationPlan.make(
            details: details,
            stringValue: "",
            rows: rows,
            expirationMode: .persistent,
            ttlMillisecondsText: ""
        )

        #expect(plan.commands.map(\.arguments) == [
            ["HDEL", "querycraft:test", "status"],
            ["HSET", "querycraft:test", "name", "Ada Lovelace"],
            ["HSET", "querycraft:test", "plan", "pro"],
        ])
    }

    @Test
    func setAndSortedSetMutationsUseMemberDifferences() throws {
        let setDetails = redisDetails(
            type: .set,
            columns: ["value"],
            rows: [["admin"], ["viewer"]]
        )
        let setPlan = try RedisKeyMutationPlan.make(
            details: setDetails,
            stringValue: "",
            rows: [
                RedisKeyEditableRow(isNew: false, firstValue: "admin"),
                RedisKeyEditableRow(
                    isNew: false,
                    firstValue: "viewer",
                    isDeleted: true
                ),
                RedisKeyEditableRow(isNew: true, firstValue: "editor"),
            ],
            expirationMode: .persistent,
            ttlMillisecondsText: ""
        )
        #expect(setPlan.commands.map(\.arguments) == [
            ["SREM", "querycraft:test", "viewer"],
            ["SADD", "querycraft:test", "editor"],
        ])

        let sortedSetDetails = redisDetails(
            type: .sortedSet,
            columns: ["value", "score"],
            rows: [["Ada", "98"], ["Linus", "92"]]
        )
        var ada = RedisKeyEditableRow(
            isNew: false,
            firstValue: "Ada",
            secondValue: "98"
        )
        ada.secondValue = "99"
        let sortedSetPlan = try RedisKeyMutationPlan.make(
            details: sortedSetDetails,
            stringValue: "",
            rows: [
                RedisKeyEditableRow(
                    isNew: false,
                    firstValue: "Linus",
                    secondValue: "92",
                    isDeleted: true
                ),
                ada,
            ],
            expirationMode: .persistent,
            ttlMillisecondsText: ""
        )
        #expect(sortedSetPlan.commands.map(\.arguments) == [
            ["ZREM", "querycraft:test", "Linus"],
            ["ZADD", "querycraft:test", "99", "Ada"],
        ])
    }

    @Test
    func collectionPlansNeverInferDeletionFromTemporarilyMissingRows() throws {
        let sortedSetDetails = redisDetails(
            type: .sortedSet,
            columns: ["value", "score"],
            rows: [["Linus", "92"], ["Grace", "96"], ["Ada", "98"]]
        )
        var linus = RedisKeyEditableRow(
            isNew: false,
            firstValue: "Linus",
            secondValue: "92"
        )
        linus.secondValue = "91"

        let sortedSetPlan = try RedisKeyMutationPlan.make(
            details: sortedSetDetails,
            stringValue: "",
            rows: [linus],
            expirationMode: .persistent,
            ttlMillisecondsText: ""
        )

        #expect(sortedSetPlan.commands.map(\.arguments) == [
            ["ZADD", "querycraft:test", "91", "Linus"],
        ])

        let setDetails = redisDetails(
            type: .set,
            columns: ["value"],
            rows: [["admin"], ["viewer"]]
        )
        let setPlan = try RedisKeyMutationPlan.make(
            details: setDetails,
            stringValue: "",
            rows: [RedisKeyEditableRow(isNew: false, firstValue: "admin")],
            expirationMode: .persistent,
            ttlMillisecondsText: ""
        )

        #expect(setPlan.commands.isEmpty)
    }

    @MainActor
    @Test
    func editingOneSortedSetScorePreservesEveryEditorRow() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .sortedSet,
            columns: ["value", "score"],
            rows: [["Linus", "92"], ["Grace", "96"], ["Ada", "98"]]
        ))

        editor.updateRow(
            id: editor.rows[1].id,
            cell: .secondValue,
            value: "97"
        )

        #expect(editor.rows.map(\.firstValue) == ["Linus", "Grace", "Ada"])
        #expect(try editor.mutationPlan().commands.map(\.arguments) == [
            ["ZADD", "querycraft:test", "97", "Grace"],
        ])
    }

    @Test
    func ttlMutationUsesPersistOrPositivePExpire() throws {
        let expiring = redisDetails(
            type: .hash,
            ttlMilliseconds: 5_000,
            columns: ["field", "value"],
            rows: [["name", "Ada"]]
        )
        let persistentPlan = try RedisKeyMutationPlan.make(
            details: expiring,
            stringValue: "",
            rows: [
                RedisKeyEditableRow(
                    isNew: false,
                    firstValue: "name",
                    secondValue: "Ada"
                ),
            ],
            expirationMode: .persistent,
            ttlMillisecondsText: "5000"
        )
        #expect(persistentPlan.commands.map(\.arguments) == [
            ["PERSIST", "querycraft:test"],
        ])

        let persistent = redisDetails(
            type: .set,
            columns: ["value"],
            rows: [["admin"]]
        )
        let expiringPlan = try RedisKeyMutationPlan.make(
            details: persistent,
            stringValue: "",
            rows: [
                RedisKeyEditableRow(isNew: false, firstValue: "admin"),
            ],
            expirationMode: .expires,
            ttlMillisecondsText: "15000"
        )
        #expect(expiringPlan.commands.map(\.arguments) == [
            ["PEXPIRE", "querycraft:test", "15000"],
        ])
    }

    @MainActor
    @Test
    func editorRejectsIncompleteRowsAndInvalidSortedSetScores() throws {
        let setEditor = RedisKeyEditorState()
        setEditor.load(redisDetails(
            type: .set,
            columns: ["value"],
            rows: [["admin"]]
        ))
        setEditor.addRow()
        #expect(setEditor.validationError == .incompleteRow)

        let sortedSetEditor = RedisKeyEditorState()
        sortedSetEditor.load(redisDetails(
            type: .sortedSet,
            columns: ["value", "score"],
            rows: [["Ada", "98"]]
        ))
        sortedSetEditor.rows[0].secondValue = "not-a-score"
        #expect(sortedSetEditor.validationError == .invalidScore("not-a-score"))
    }

    @MainActor
    @Test
    func collectionRowsTrackInsertedModifiedAndDeletedStates() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .hash,
            columns: ["field", "value"],
            rows: [["name", "Ada"], ["status", "active"]]
        ))

        #expect(editor.rows.map(\.changeState) == [.unchanged, .unchanged])

        editor.rows[0].secondValue = "Ada Lovelace"
        #expect(editor.rows[0].changeState == .modified)
        #expect(!editor.rows[0].isFirstValueModified)
        #expect(editor.rows[0].isSecondValueModified)

        editor.addRow()
        let insertedID = try #require(editor.rows.last?.id)
        #expect(editor.rows.last?.changeState == .inserted)
        editor.removeRow(id: insertedID)
        #expect(editor.rows.count == 2)

        let modifiedID = editor.rows[0].id
        editor.removeRow(id: modifiedID)
        #expect(editor.rows[0].changeState == .deleted)
        editor.removeRow(id: modifiedID)
        #expect(editor.rows[0].changeState == .modified)
    }

    @MainActor
    @Test
    func collectionRowSelectionFollowsAddDeleteAndUndo() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .hash,
            columns: ["field", "value"],
            rows: [["name", "Ada"], ["status", "active"]]
        ))

        editor.addRow()
        #expect(editor.selectedRowIndexes == IndexSet(integer: 2))

        editor.removeRows(at: editor.selectedRowIndexes)
        #expect(editor.rows.count == 2)
        #expect(editor.selectedRowIndexes == IndexSet(integer: 1))

        editor.removeRows(at: editor.selectedRowIndexes)
        #expect(editor.rows[1].isDeleted)
        #expect(editor.selectedRowIndexes == IndexSet(integer: 1))

        editor.removeRows(at: editor.selectedRowIndexes)
        #expect(!editor.rows[1].isDeleted)
    }

    @MainActor
    @Test
    func collectionRowShortcutsUsePhysicalKeysWithChineseInput() async throws {
        var addCount = 0
        var deletedRows: [IndexSet] = []
        let actions = WorkspaceDatabaseDataRowCommandActions(
            selectedRowIndexes: IndexSet(integer: 1),
            canAddRow: true,
            canDuplicateRow: false,
            canDeleteRow: true,
            addRow: { addCount += 1 },
            duplicateRow: { _ in },
            deleteRows: { deletedRows.append($0) }
        )
        let coordinator = WorkspaceDatabaseDataRowKeyCommandHandler.Coordinator(
            actions: actions,
            filterPresentationActions: nil,
            objectDetailTabActions: nil,
            isSuspended: false
        )
        let addEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "中",
            charactersIgnoringModifiers: "中",
            isARepeat: false,
            keyCode: 34
        ))
        let deleteEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 51
        ))

        #expect(coordinator.handle(addEvent))
        #expect(coordinator.handle(deleteEvent))
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }

        #expect(addCount == 1)
        #expect(deletedRows == [IndexSet(integer: 1)])
    }

    @MainActor
    @Test
    func collectionGridMatchesSQLCellEditingNavigation() throws {
        let rows = [
            RedisKeyEditableRow(
                isNew: false,
                firstValue: "name",
                secondValue: "Ada"
            ),
            RedisKeyEditableRow(
                isNew: false,
                firstValue: "status",
                secondValue: "active"
            ),
        ]
        var updates: [(RedisKeyEditableRow.ID, RedisKeyEditableCell, String)] = []
        let searchController = WorkspaceGridSearchController()
        let coordinator = RedisCollectionGridCoordinator(
            rows: rows,
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: [],
            searchController: searchController,
            searchPresentationActions: WorkspaceGridSearchCommandActions(
                search: searchController.present,
                dismiss: searchController.dismiss,
                isPresented: { searchController.isPresented }
            ),
            addRow: {},
            updateValue: { updates.append(($0, $1, $2)) },
            removeRow: { _ in },
            selectRows: { _ in }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(tableView.singleClickCellHandler == nil)
        #expect(searchController.canSearch)
        #expect(searchController.sourceRowCount == 2)
        #expect(
            searchController.columns.map(\.name)
                == RedisCollectionGridKind.hash.columnTitles
        )
        searchController.present()
        #expect(searchController.isPresented)
        #expect(tableView.usesAlternatingRowBackgroundColors)
        #expect(tableView.columnAutoresizingStyle == .noColumnAutoresizing)
        #expect(tableView.tableColumns.map(\.identifier.rawValue) == [
            "redis.collection.rowNumber",
            "redis.collection.first",
            "redis.collection.second",
            "redis.collection.action",
        ])
        #expect(tableView.tableColumns[0].width == 48)
        #expect(tableView.tableColumns[0].minWidth == 48)
        #expect(tableView.tableColumns[0].maxWidth == 48)
        #expect(tableView.tableColumns[1].width == 180)
        #expect(tableView.tableColumns[2].width == 280)
        #expect(
            RedisCollectionGridRowView.actionSystemImageName(isDeleted: false)
                == "trash"
        )
        #expect(
            RedisCollectionGridRowView.actionSystemImageName(isDeleted: true)
                == "arrow.uturn.backward"
        )
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 0, column: 1),
            active: WorkspaceGridCoordinate(row: 0, column: 1)
        )
        tableView.cellEditHandler?(0, 1)
        let firstEditor = try #require(redisCollectionEditor(in: tableView))
        firstEditor.stringValue = "displayName"
        let returnTextView = NSTextView()
        returnTextView.string = "displayName"

        #expect(coordinator.control(
            firstEditor,
            textView: returnTextView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        #expect(tableView.gridSelection.active == .init(row: 0, column: 2))
        #expect(updates.count == 1)
        let update = try #require(updates.first)
        #expect(update.0 == rows[0].id)
        #expect(update.1 == .firstValue)
        #expect(update.2 == "displayName")

        let secondEditor = try #require(redisCollectionEditor(in: tableView))
        #expect(coordinator.control(
            secondEditor,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertTab(_:))
        ))
        #expect(tableView.gridSelection.active == .init(row: 0, column: 1))

        let wrappedEditor = try #require(redisCollectionEditor(in: tableView))
        #expect(coordinator.control(
            wrappedEditor,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        #expect(tableView.gridSelection.active == .init(row: 1, column: 1))

        let movedEditor = try #require(redisCollectionEditor(in: tableView))
        #expect(coordinator.control(
            movedEditor,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(tableView.gridSelection.active == .init(row: 1, column: 1))

        #expect(tableView.cellTypingHandler?(1, 2, "9") == true)
        #expect(redisCollectionEditor(in: tableView)?.stringValue == "9")
    }

    @MainActor
    @Test
    func collectionGridRoutesFindToRemoteRedisSearch() throws {
        let remoteSearchState = RedisCollectionRemoteSearchState()
        let coordinator = RedisCollectionGridCoordinator(
            rows: [
                RedisKeyEditableRow(
                    isNew: false,
                    firstValue: "name",
                    secondValue: "Ada"
                )
            ],
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: [],
            searchPresentationActions: WorkspaceGridSearchCommandActions(
                search: remoteSearchState.present,
                dismiss: remoteSearchState.dismiss,
                isPresented: { remoteSearchState.isPresented }
            ),
            addRow: {},
            updateValue: { _, _, _ in },
            removeRow: { _ in },
            selectRows: { _ in }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )

        #expect(
            tableView.tryToPerform(
                #selector(WorkspaceDirectDrawTableView.findInData(_:)),
                with: nil
            )
        )

        #expect(remoteSearchState.isPresented)
        #expect(remoteSearchState.focusRequest == 1)
        tableView.cancelOperation(nil)
        #expect(!remoteSearchState.isPresented)

        let commandF = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "中",
                charactersIgnoringModifiers: "中",
                isARepeat: false,
                keyCode: 3
            )
        )
        tableView.keyDown(with: commandF)

        #expect(remoteSearchState.isPresented)
        #expect(remoteSearchState.focusRequest == 2)
    }

    @MainActor
    @Test
    func collectionGridPreservesActiveColumnAndPendingSelection() async throws {
        let rows = [
            RedisKeyEditableRow(isNew: false, firstValue: "a", secondValue: "1"),
            RedisKeyEditableRow(isNew: false, firstValue: "b", secondValue: "2"),
            RedisKeyEditableRow(isNew: false, firstValue: "c", secondValue: "3"),
        ]
        let selectionProbe = RedisCollectionSelectionProbe()
        let searchController = WorkspaceGridSearchController()
        let searchPresentationActions = WorkspaceGridSearchCommandActions(
            search: searchController.present,
            dismiss: searchController.dismiss,
            isPresented: { searchController.isPresented }
        )
        let coordinator = RedisCollectionGridCoordinator(
            rows: rows,
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: IndexSet(integer: 0),
            searchController: searchController,
            searchPresentationActions: searchPresentationActions,
            addRow: {},
            updateValue: { _, _, _ in },
            removeRow: { _ in },
            selectRows: { selectionProbe.record($0) }
        )
        let tableView = try #require(
            coordinator.makeScrollView().documentView
                as? WorkspaceDirectDrawTableView
        )
        tableView.selectGridRange(
            anchor: WorkspaceGridCoordinate(row: 2, column: 2),
            active: WorkspaceGridCoordinate(row: 2, column: 2)
        )

        var refreshedRows = rows
        refreshedRows[0].secondValue = "updated"
        coordinator.update(
            rows: refreshedRows,
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: IndexSet(integer: 0),
            searchPresentationActions: searchPresentationActions,
            addRow: {},
            updateValue: { _, _, _ in },
            removeRow: { _ in },
            selectRows: { selectionProbe.record($0) }
        )

        #expect(tableView.gridSelection.active == .init(row: 2, column: 2))
        #expect(await selectionProbe.next() == IndexSet(integer: 2))

        coordinator.update(
            rows: refreshedRows,
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: IndexSet(integer: 2),
            searchPresentationActions: searchPresentationActions,
            addRow: {},
            updateValue: { _, _, _ in },
            removeRow: { _ in },
            selectRows: { selectionProbe.record($0) }
        )
        coordinator.update(
            rows: refreshedRows,
            kind: .hash,
            isEnabled: true,
            selectedRowIndexes: IndexSet(integer: 0),
            searchPresentationActions: searchPresentationActions,
            addRow: {},
            updateValue: { _, _, _ in },
            removeRow: { _ in },
            selectRows: { selectionProbe.record($0) }
        )
        #expect(tableView.gridSelection.active == .init(row: 0, column: 2))
    }

    @Test
    func collectionGridPresentationMatchesSQLPendingChangeCoverage() {
        let unchanged = RedisKeyEditableRow(
            isNew: false,
            firstValue: "name",
            secondValue: "Ada"
        )
        var modified = RedisKeyEditableRow(
            isNew: false,
            firstValue: "status",
            secondValue: "active"
        )
        modified.secondValue = "active1"
        let inserted = RedisKeyEditableRow(
            isNew: true,
            firstValue: "plan",
            secondValue: "pro"
        )
        let deleted = RedisKeyEditableRow(
            isNew: false,
            firstValue: "legacy",
            secondValue: "1",
            isDeleted: true
        )

        let unchangedPresentation = RedisCollectionGridRowPresentation(
            row: unchanged,
            kind: .hash
        )
        let modifiedPresentation = RedisCollectionGridRowPresentation(
            row: modified,
            kind: .hash
        )
        let insertedPresentation = RedisCollectionGridRowPresentation(
            row: inserted,
            kind: .hash
        )
        let deletedPresentation = RedisCollectionGridRowPresentation(
            row: deleted,
            kind: .hash
        )

        #expect(unchangedPresentation.changeState == .unchanged)
        #expect(unchangedPresentation.modifiedDataIndexes.isEmpty)
        #expect(modifiedPresentation.changeState == .modified)
        #expect(modifiedPresentation.modifiedDataIndexes == [1])
        #expect(insertedPresentation.changeState == .inserted)
        #expect(insertedPresentation.modifiedDataIndexes.isEmpty)
        #expect(deletedPresentation.changeState == .deleted)
        #expect(!deletedPresentation.isEditable(dataIndex: 0, isEnabled: true))
        #expect(unchangedPresentation.isEditable(dataIndex: 0, isEnabled: true))
        #expect(!unchangedPresentation.isEditable(dataIndex: 0, isEnabled: false))
    }

    @MainActor
    @Test
    func pendingCollectionDeletionBuildsCommandAndCanBeUndone() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .set,
            columns: ["value"],
            rows: [["admin"], ["viewer"]]
        ))
        let viewerID = editor.rows[1].id

        editor.removeRow(id: viewerID)

        #expect(editor.hasChanges)
        #expect(try editor.mutationPlan().commands.map(\.arguments) == [
            ["SREM", "querycraft:test", "viewer"],
        ])

        editor.removeRow(id: viewerID)

        #expect(!editor.hasChanges)
        #expect(try editor.mutationPlan().commands.isEmpty)
    }

    @MainActor
    @Test
    func readOnlyCollectionTypeDoesNotPublishChangesUntilTTLChanges() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .list,
            ttlMilliseconds: 5_000,
            columns: ["index", "value"],
            rows: [["0", "first"]]
        ))

        #expect(!editor.hasChanges)
        #expect(editor.validationError == nil)

        editor.expirationMode = .persistent
        #expect(editor.hasChanges)
        #expect(try editor.mutationPlan().commands.map(\.arguments) == [
            ["PERSIST", "querycraft:test"],
        ])
    }

    @MainActor
    @Test
    func commandDocumentAppendsResultToTranscriptAndClearsPrompt() async throws {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 10 },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .bulkString("QueryCraft"),
                    elapsedSeconds: 0.012
                )
            }
        )
        document.updateSource("GET user:1")

        let task = try #require(document.run())
        await task.value

        #expect(document.source.isEmpty)
        #expect(!document.isExecuting)
        let entry = try #require(document.transcriptEntries.first)
        #expect(entry.databaseIndex == 10)
        #expect(entry.command == "GET user:1")
        guard case let .success(reply, elapsedSeconds) = entry.outcome else {
            Issue.record("Expected a successful transcript entry")
            return
        }
        #expect(reply == .bulkString("QueryCraft"))
        #expect(elapsedSeconds == 0.012)
    }

    private func redisDetails(
        type: RedisKeyType,
        ttlMilliseconds: Int64? = nil,
        columns: [String],
        rows: [[String]]
    ) -> RedisKeyDetails {
        RedisKeyDetails(
            reference: RedisKeyReference(
                databaseIndex: 10,
                name: "querycraft:test",
                type: type
            ),
            ttlMilliseconds: ttlMilliseconds,
            memoryUsageBytes: 128,
            encoding: "test",
            value: RedisKeyValueSnapshot(columns: columns, rows: rows)
        )
    }

    @MainActor
    @Test
    func collectionBottomBarExposesSeparateValueLoadingActions() {
        let details = redisDetails(
            type: .list,
            columns: ["index", "value"],
            rows: []
        )
        let editor = RedisKeyEditorState()
        editor.load(details)
        editor.loadCollectionPage(
            RedisCollectionPage(
                entries: [
                    .list(index: 0, value: RedisBinaryValue(utf8: "first")),
                ],
                totalCount: 1_000,
                scannedCount: 500,
                matchingCount: nil,
                continuation: RedisCollectionContinuation(rawValue: "500:500:0")
            ),
            replacing: true
        )
        let controls = RedisCollectionValueLoadControls(
            isEnabled: true,
            loadMore: {},
            loadAll: {}
        )

        #expect(editor.canLoadMoreCollectionRows)
        #expect(controls.isEnabled)
        #expect(
            RedisCollectionValueLoadControls.loadMoreSystemImageName
                == "chevron.right"
        )
        #expect(
            RedisCollectionValueLoadControls.loadAllSystemImageName
                == "chevron.forward.2"
        )
        #expect(
            NSImage(
                systemSymbolName:
                    RedisCollectionValueLoadControls.loadMoreSystemImageName,
                accessibilityDescription: nil
            ) != nil
        )
        #expect(
            NSImage(
                systemSymbolName:
                    RedisCollectionValueLoadControls.loadAllSystemImageName,
                accessibilityDescription: nil
            ) != nil
        )
        #expect(
            RedisCollectionValueLoadControls.loadMoreTitle.contains("500")
        )
    }

    @MainActor
    @Test
    func redisKeyHeaderExposesEveryKeyActionWithoutAMoreMenu() {
        let systemImageNames = [
            RedisKeyHeaderActions.renameSystemImageName,
            RedisKeyHeaderActions.copySelectedSystemImageName,
            RedisKeyHeaderActions.copyWholeKeySystemImageName,
            RedisKeyHeaderActions.deleteSystemImageName,
        ]

        #expect(Set(systemImageNames).count == 4)
        #expect(
            systemImageNames.allSatisfy {
                NSImage(
                    systemSymbolName: $0,
                    accessibilityDescription: nil
                ) != nil
            }
        )
    }

    @MainActor
    @Test
    func commandDocumentNavigatesCommandHistoryAndRestoresDraft() async throws {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .simpleString("OK"),
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("PING")
        try await #require(document.run()).value
        document.updateSource("DBSIZE")
        try await #require(document.run()).value
        document.updateSource("GET draft")

        #expect(document.showPreviousCommand())
        #expect(document.source == "DBSIZE")
        #expect(document.showPreviousCommand())
        #expect(document.source == "PING")
        #expect(document.showNextCommand())
        #expect(document.source == "DBSIZE")
        #expect(document.showNextCommand())
        #expect(document.source == "GET draft")
    }

    @MainActor
    @Test
    func commandDocumentUsesCommandCompletionWithoutShowingEditorChips() {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("GE")

        #expect(document.completions.map(\.name) == ["GET"])
        #expect(document.acceptSelectedCandidate())
        #expect(document.source == "GET ")
        #expect(document.completions.isEmpty)
        #expect(document.activeArgument?.name == "key")
    }

    @MainActor
    @Test
    func commandCompletionInvalidatesAfterBeingDismissed() {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )
        document.updateSource("GE")
        #expect(document.dismissCandidates())

        let didInvalidate = Mutex(false)
        withObservationTracking {
            _ = document.completions
        } onChange: {
            didInvalidate.withLock { $0 = true }
        }

        document.updateSource("G")

        #expect(didInvalidate.withLock { $0 })
        #expect(document.completions.map(\.name) == ["GET"])
    }

    @MainActor
    @Test
    func commandDocumentSuggestsLoadedKeysWithPrefixMatchesFirst() {
        let loadedKeys = [
            "archive:user:1",
            "user:1",
            "user:2",
            "user:3",
            "user:4",
            "user:5",
            "user:6",
            "user:7",
            "user:8",
        ].map {
            RedisKeyReference(databaseIndex: 0, name: $0, type: .string)
        }
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            availableKeys: { loadedKeys },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("GET user")

        #expect(document.argumentSuggestions.count == 7)
        #expect(document.argumentSuggestions.first?.value == "user:1")
        #expect(!document.argumentSuggestions.map(\.value).contains("archive:user:1"))

        document.updateSource("GET ser:1")

        #expect(document.argumentSuggestions.map(\.value) == [
            "archive:user:1", "user:1",
        ])
    }

    @MainActor
    @Test
    func acceptingLoadedKeyQuotesSpacesAndAdvancesToNextArgument() {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            availableKeys: {
                [
                    RedisKeyReference(
                        databaseIndex: 0,
                        name: "team user",
                        type: .hash
                    ),
                ]
            },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )
        document.updateSource("HSET team")

        #expect(document.acceptSelectedCandidate())
        #expect(document.source == "HSET \"team user\" ")
        #expect(document.activeArgument?.name == "field")
    }

    @MainActor
    @Test
    func commandKeySuggestionsFilterResolvedTypesButKeepUnknownKeys() {
        let keys = [
            RedisKeyReference(databaseIndex: 0, name: "profile", type: .hash),
            RedisKeyReference(databaseIndex: 0, name: "queue", type: .list),
            RedisKeyReference(databaseIndex: 0, name: "legacy"),
        ]
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            availableKeys: { keys },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("HGET ")
        #expect(document.argumentSuggestions.map(\.value) == [
            "profile", "legacy",
        ])

        document.updateSource("LRANGE ")
        #expect(document.argumentSuggestions.map(\.value) == [
            "queue", "legacy",
        ])

        document.updateSource("DEL ")
        #expect(document.argumentSuggestions.map(\.value) == [
            "profile", "queue", "legacy",
        ])
    }

    @MainActor
    @Test
    func commandDocumentSuggestsCachedFieldsForTheSelectedHashKey() {
        let key = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:profile",
            type: .hash
        )
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 10 },
            availableKeys: { [key] },
            availableHashFields: { reference in
                reference == key ? ["name", "status", "displayName"] : []
            },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("HGET querycraft:profile ")
        #expect(document.argumentSuggestions.map(\.value) == [
            "name", "status", "displayName",
        ])

        document.updateSource("HGET querycraft:profile sta")
        #expect(document.argumentSuggestions.map(\.value) == ["status"])

        document.updateSource("HGET querycraft:missing ")
        #expect(document.argumentSuggestions.isEmpty)
    }

    @Test
    func commandSuggestionRequestsUseBoundedScansAndParseCandidates() throws {
        let hash = RedisCommandSuggestionRequest(
            databaseIndex: 10,
            key: "profile",
            domain: .hashField
        )
        let set = RedisCommandSuggestionRequest(
            databaseIndex: 10,
            key: "roles",
            domain: .setMember
        )
        let sortedSet = RedisCommandSuggestionRequest(
            databaseIndex: 10,
            key: "scores",
            domain: .sortedSetMember
        )

        #expect(hash.invocation.arguments == [
            "HSCAN", "profile", "0", "COUNT", "100",
        ])
        #expect(set.invocation.arguments == [
            "SSCAN", "roles", "0", "COUNT", "100",
        ])
        #expect(sortedSet.invocation.arguments == [
            "ZSCAN", "scores", "0", "COUNT", "100",
        ])
        #expect(try hash.candidates(from: .array([
            .bulkString("0"),
            .array([
                .bulkString("name"), .bulkString("Ada"),
                .bulkString("status"), .bulkString("active"),
            ]),
        ])) == ["name", "status"])
        #expect(try set.candidates(from: .array([
            .bulkString("0"),
            .array([.bulkString("admin"), .bulkString("editor")]),
        ])) == ["admin", "editor"])
        #expect(try sortedSet.candidates(from: .array([
            .bulkString("0"),
            .array([
                .bulkString("Ada"), .bulkString("12"),
                .bulkString("Grace"), .bulkString("10"),
            ]),
        ])) == ["Ada", "Grace"])
    }

    @Test
    func commandSuggestionRequestsFollowTheConcreteKeyAndArgument() {
        #expect(
            RedisCommandLineSnapshot(source: "HDEL profile ")
                .suggestionRequest(databaseIndex: 10)
                == RedisCommandSuggestionRequest(
                    databaseIndex: 10,
                    key: "profile",
                    domain: .hashField
                )
        )
        #expect(
            RedisCommandLineSnapshot(source: "SREM roles ")
                .suggestionRequest(databaseIndex: 10)?.domain == .setMember
        )
        #expect(
            RedisCommandLineSnapshot(source: "ZADD scores 12 ")
                .suggestionRequest(databaseIndex: 10)?.domain
                == .sortedSetMember
        )
        #expect(
            RedisCommandLineSnapshot(source: "ZADD scores ")
                .suggestionRequest(databaseIndex: 10) == nil
        )
        #expect(
            RedisCommandLineSnapshot(source: "XADD events * field ")
                .suggestionRequest(databaseIndex: 10) == nil
        )
    }

    @MainActor
    @Test
    func acceptingAKeyLoadsAndCachesSuggestionsWithoutTranscript() async {
        let requests = Mutex<[RedisCommandSuggestionRequest]>([])
        let key = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:profile",
            type: .hash
        )
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 10 },
            availableKeys: { [key] },
            isSafetyLockEnabled: { false },
            loadSuggestions: { request in
                requests.withLock { $0.append(request) }
                return ["name", "status", "displayName"]
            },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("HGET querycraft:pro")
        #expect(document.acceptSelectedCandidate())
        await document.waitForSuggestionLoading()

        #expect(document.source == "HGET querycraft:profile ")
        #expect(document.argumentSuggestions.map(\.value) == [
            "name", "status", "displayName",
        ])
        #expect(document.transcriptEntries.isEmpty)

        document.updateSource("HGET querycraft:profile sta")
        await document.waitForSuggestionLoading()
        #expect(document.argumentSuggestions.map(\.value) == ["status"])
        #expect(requests.withLock { $0.count } == 1)
    }

    @MainActor
    @Test
    func changingSuggestionKeyDiscardsTheStaleRequestResult() async {
        let probe = RedisCommandSuggestionProbe()
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 10 },
            isSafetyLockEnabled: { false },
            loadSuggestions: { request in
                await probe.load(request)
            },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )

        document.updateSource("HGET first ")
        await probe.waitForRequestCount(1)
        document.updateSource("HGET second ")
        await probe.waitForRequestCount(2)

        await probe.resolve(key: "first", candidates: ["stale"])
        await probe.resolve(key: "second", candidates: ["fresh"])
        await document.waitForSuggestionLoading()

        #expect(document.argumentSuggestions.map(\.value) == ["fresh"])
        #expect(await probe.requestedKeys == ["first", "second"])
    }

    @MainActor
    @Test
    func emptyOptionalKeywordDoesNotInterceptCommandExecution() {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            isSafetyLockEnabled: { false },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .null,
                    elapsedSeconds: 0
                )
            }
        )
        document.updateSource("SET user:1 Ada ")

        #expect(document.activeArgument?.name == "option")
        #expect(document.argumentSuggestions.isEmpty)
        #expect(!document.acceptSelectedCandidate())
    }

    @MainActor
    @Test
    func commandInputSynchronizesAndReadsTheActiveFieldEditor() {
        let textField = RedisCommandTestTextField()
        textField.stringValue = "GE"
        textField.testEditor.string = "GE"
        WorkspaceRedisCommandInputField.synchronize("", in: textField)

        #expect(textField.stringValue.isEmpty)
        #expect(textField.testEditor.string.isEmpty)

        var changedText: String?
        let input = WorkspaceRedisCommandInputField(
            text: "",
            isEditable: true,
            focusRequest: 0,
            textChanged: { changedText = $0 },
            submit: {},
            moveUp: { false },
            moveDown: { false },
            acceptCandidate: { false },
            selectPreviousCandidate: { false },
            cancel: { false }
        )
        let coordinator = input.makeCoordinator()
        textField.testEditor.string = "GET"

        coordinator.controlTextDidChange(
            Notification(
                name: NSControl.textDidChangeNotification,
                object: textField
            )
        )

        #expect(changedText == "GET")
    }

    @MainActor
    @Test
    func commandInputReturnAcceptsCompletionBeforeSubmitting() {
        var didSubmit = false
        var didAcceptCompletion = false
        let input = WorkspaceRedisCommandInputField(
            text: "GE",
            isEditable: true,
            focusRequest: 0,
            textChanged: { _ in },
            submit: { didSubmit = true },
            moveUp: { false },
            moveDown: { false },
            acceptCandidate: {
                didAcceptCompletion = true
                return true
            },
            selectPreviousCandidate: { false },
            cancel: { false }
        )
        let coordinator = input.makeCoordinator()

        let handled = coordinator.control(
            NSTextField(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        #expect(handled)
        #expect(didAcceptCompletion)
        #expect(!didSubmit)
    }

    @MainActor
    @Test
    func commandDocumentKeepsBlockedWriteInPrompt() {
        let document = WorkspaceRedisCommandDocumentModel(
            title: "Command 1",
            databaseIndex: { 0 },
            isSafetyLockEnabled: { true },
            executeCommand: { invocation, _ in
                RedisCommandResult(
                    invocation: invocation,
                    reply: .simpleString("OK"),
                    elapsedSeconds: 0
                )
            }
        )
        document.updateSource("SET user:1 Ada")

        #expect(document.run() == nil)
        #expect(document.source == "SET user:1 Ada")
        #expect(document.transcriptEntries.isEmpty)
    }

    @Test
    func redisHexCodecRoundTripsArbitraryBytesAndRejectsHalfBytes() throws {
        let bytes = Data([0x00, 0xff, 0x22, 0x5c, 0x0a])
        let formatted = RedisHexCodec.format(bytes)

        #expect(RedisHexCodec.parse(formatted) == bytes)
        #expect(RedisHexCodec.parse("0 ff") == nil)
        #expect(RedisHexCodec.parse("gg") == nil)
    }

    @Test
    func jsonFormattingPreservesNumbersEscapesAndStringContents() async throws {
        let source = #"{"large":900719925474099312345,"rate":1.20e+03,"text":"a  b\\n\\u4e2d"}"#
        let formatted = try #require(
            await RedisValueFormatter().formattedJSON(from: source)
        )

        #expect(formatted.contains("900719925474099312345"))
        #expect(formatted.contains("1.20e+03"))
        #expect(formatted.contains(#""a  b\\n\\u4e2d""#))
        #expect(!formatted.contains(#""large" :"#))
    }

    @Test
    func redisRenamePlanPreviewsTheSameRenameNXOperation() {
        let reference = RedisKeyReference(
            databaseIndex: 10,
            name: "querycraft:before",
            type: .string
        )
        let plan = RedisKeyRenamePlan(
            reference: reference,
            newName: "querycraft:after"
        )

        #expect(
            plan.command.source
                == "RENAMENX querycraft:before querycraft:after"
        )
        #expect(plan.command.arguments == [
            "RENAMENX", "querycraft:before", "querycraft:after",
        ])
    }

    @MainActor
    @Test
    func binaryStringCommandExportUsesRedisCLIHexEscapes() throws {
        let details = redisDetails(
            type: .string,
            ttlMilliseconds: 5_000,
            columns: ["value"],
            rows: [[""]]
        )
        let editor = RedisKeyEditorState()
        editor.load(details)
        editor.loadStringChunk(
            RedisStringChunk(
                value: RedisBinaryValue(data: Data([0x00, 0xff, 0x41])),
                offset: 0,
                totalByteCount: 3
            ),
            replacing: true
        )

        let command = try #require(
            RedisKeyCommandExporter.wholeKey(details: details, editor: editor)
        )
        #expect(command.contains(#""\x00\xffA""#))
        #expect(command.contains("PEXPIRE querycraft:test 5000"))
    }

    @MainActor
    @Test
    func binaryStringLoadsDirectlyIntoReadOnlyTextWithoutAFormatToggle() {
        let details = redisDetails(
            type: .string,
            columns: ["value"],
            rows: [[""]]
        )
        let editor = RedisKeyEditorState()
        editor.load(details)

        editor.loadStringChunk(
            RedisStringChunk(
                value: RedisBinaryValue(
                    data: Data([0xff, 0x00, 0x51, 0x75, 0x65, 0x72, 0x79])
                ),
                offset: 0,
                totalByteCount: 7
            ),
            replacing: true
        )

        #expect(editor.stringEditingFormat == .text)
        #expect(editor.stringDisplayValue == "�\\0Query")
        #expect(editor.stringData.losslessUTF8String == nil)
        #expect(!editor.supportsStringPresentationEditing)

        editor.applyStringPresentation("")
        editor.synchronizeStringPresentation()

        #expect(editor.stringEditingFormat == .text)
        #expect(editor.stringDisplayValue == "�\\0Query")

        editor.stringEditingFormat = .hex
        editor.synchronizeStringPresentation()

        #expect(editor.stringDisplayValue == "ff 00 51 75 65 72 79")
        #expect(editor.supportsStringPresentationEditing)
    }

    @MainActor
    @Test
    func binaryStringTextIsPresentAfterMountingTheNativeEditor() throws {
        let editor = RedisKeyEditorState()
        editor.load(redisDetails(
            type: .string,
            columns: ["value"],
            rows: [[""]]
        ))
        editor.loadStringChunk(
            RedisStringChunk(
                value: RedisBinaryValue(
                    data: Data([0x00, 0xff, 0xfe, 0x51, 0x75, 0x65, 0x72, 0x79])
                ),
                offset: 0,
                totalByteCount: 8
            ),
            replacing: true
        )
        let hostingView = NSHostingView(rootView: RedisEditableStringValueView(
            editor: editor,
            isEnabled: true
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let textView = try #require(firstSubview(of: NSTextView.self, in: hostingView))
        #expect(textView.string == "\\0��Query")
    }

    @MainActor
    @Test
    func binaryStringAppearsWhenBytesArriveAfterNativeEditorMounts() async throws {
        let editor = RedisKeyEditorState()
        let hostingView = NSHostingView(rootView: RedisEditableStringValueView(
            editor: editor,
            isEnabled: true
        ))
        hostingView.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        let initialTextView = try #require(redisStringTextView(in: hostingView))

        editor.load(redisDetails(
            type: .string,
            columns: ["value"],
            rows: [[""]]
        ))
        editor.loadStringChunk(
            RedisStringChunk(
                value: RedisBinaryValue(
                    data: Data([
                        0x00, 0xff, 0xfe, 0x51, 0x75, 0x65, 0x72, 0x79,
                        0x43, 0x72, 0x61, 0x66, 0x74, 0x00, 0x80, 0xc3,
                        0x28, 0x0a,
                    ])
                ),
                offset: 0,
                totalByteCount: 18
            ),
            replacing: true
        )
        await Task.yield()
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let textView = try #require(redisStringTextView(in: hostingView))
        #expect(textView === initialTextView)
        #expect(textView.string == "\\0��QueryCraft\\0��(\n")
        #expect(!textView.isEditable)
    }

    @MainActor
    @Test
    func completeHashCommandExportIncludesFieldAndKeyTTL() throws {
        let details = redisDetails(
            type: .hash,
            ttlMilliseconds: 60_000,
            columns: ["field", "value", "ttl"],
            rows: []
        )
        let editor = RedisKeyEditorState()
        editor.load(details)
        editor.loadCollectionPage(
            RedisCollectionPage(
                entries: [
                    .hash(
                        field: RedisBinaryValue(utf8: "name"),
                        value: RedisBinaryValue(utf8: "Ada"),
                        ttlMilliseconds: nil
                    ),
                    .hash(
                        field: RedisBinaryValue(utf8: "token"),
                        value: RedisBinaryValue(utf8: "abc"),
                        ttlMilliseconds: 2_000
                    ),
                ],
                totalCount: 2,
                scannedCount: 2,
                matchingCount: 2,
                continuation: nil,
                supportsHashFieldExpiration: true
            ),
            replacing: true
        )

        let command = try #require(
            RedisKeyCommandExporter.wholeKey(details: details, editor: editor)
        )
        #expect(command.contains("HSET querycraft:test name Ada token abc"))
        #expect(command.contains("HPEXPIRE querycraft:test 2000 FIELDS 1 token"))
        #expect(command.contains("PEXPIRE querycraft:test 60000"))
    }

    @Test
    func hashFieldTTLRejectsNonPositiveValues() throws {
        let details = redisDetails(
            type: .hash,
            columns: ["field", "value", "ttl"],
            rows: [["name", "Ada", ""]]
        )
        var row = RedisKeyEditableRow(
            isNew: false,
            firstValue: "name",
            secondValue: "Ada",
            thirdValue: ""
        )
        row.thirdValue = "0"

        #expect(throws: RedisKeyEditError.invalidTTL) {
            _ = try RedisKeyMutationPlan.make(
                details: details,
                stringValue: "",
                rows: [row],
                expirationMode: .persistent,
                ttlMillisecondsText: ""
            )
        }
    }

    @MainActor
    @Test
    func redisKeyRenameReplacesTabIdentityWithoutDuplicatingIt() throws {
        let tabs = WorkspaceContentTabsModel()
        let old = RedisKeyReference(
            databaseIndex: 0,
            name: "before",
            type: .hash
        )
        let renamed = RedisKeyReference(
            databaseIndex: 0,
            name: "after",
            type: .hash
        )
        tabs.open(old)

        tabs.replaceRedisKey(old, with: renamed)

        #expect(tabs.contentItems.map(\.id) == [.redisKey(renamed)])
        #expect(tabs.selectedContentID == .redisKey(renamed))
    }

    @MainActor
    @Test
    func listDeletionTargetsTheOriginalIndexWhenValuesRepeat() throws {
        let details = redisDetails(
            type: .list,
            columns: ["index", "value"],
            rows: []
        )
        let editor = RedisKeyEditorState()
        editor.load(details)
        editor.loadCollectionPage(
            RedisCollectionPage(
                entries: [
                    .list(index: 0, value: RedisBinaryValue(utf8: "same")),
                    .list(index: 1, value: RedisBinaryValue(utf8: "same")),
                    .list(index: 2, value: RedisBinaryValue(utf8: "tail")),
                ],
                totalCount: 3,
                scannedCount: 3,
                matchingCount: 3,
                continuation: nil
            ),
            replacing: true
        )
        editor.removeRow(id: editor.rows[1].id)

        let request = try #require(editor.mutationPlan().optimisticRequest)
        #expect(request.assertions.contains(
            .listElement(index: 1, value: RedisBinaryValue(utf8: "same"))
        ))
        #expect(request.operations.contains(
            .deleteListElement(
                index: 1,
                originalValue: RedisBinaryValue(utf8: "same")
            )
        ))
    }

    @MainActor
    private func redisCollectionEditor(
        in tableView: WorkspaceDirectDrawTableView
    ) -> RedisCollectionNativeTextField? {
        tableView.subviews.compactMap {
            $0 as? RedisCollectionNativeTextField
        }.first {
            $0.accessibilityIdentifier() == "redisCollectionCellInlineEditor"
        }
    }

    @MainActor
    private func firstSubview<ViewType: NSView>(
        of type: ViewType.Type,
        in rootView: NSView
    ) -> ViewType? {
        if let match = rootView as? ViewType { return match }
        for subview in rootView.subviews {
            if let match = firstSubview(of: type, in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func redisStringTextView(in rootView: NSView) -> NSTextView? {
        if let textView = rootView as? NSTextView,
           textView.accessibilityLabel() == AppCopy.current.text(
               "Redis String 值",
               "Redis string value"
           )
        {
            return textView
        }
        for subview in rootView.subviews {
            if let match = redisStringTextView(in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class RedisCommandTestTextField: NSTextField {
    let testEditor = NSTextView()

    override func currentEditor() -> NSText? {
        testEditor
    }
}

@MainActor
private final class RedisCollectionSelectionProbe {
    private var values: [IndexSet] = []
    private var waiters: [CheckedContinuation<IndexSet, Never>] = []

    func record(_ value: IndexSet) {
        if waiters.isEmpty {
            values.append(value)
        } else {
            waiters.removeFirst().resume(returning: value)
        }
    }

    func next() async -> IndexSet {
        if !values.isEmpty {
            return values.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor RedisCommandSuggestionProbe {
    private(set) var requestedKeys: [String] = []
    private var pending: [
        String: CheckedContinuation<[String], Never>
    ] = [:]
    private var requestCountWaiters: [
        Int: CheckedContinuation<Void, Never>
    ] = [:]

    func load(_ request: RedisCommandSuggestionRequest) async -> [String] {
        requestedKeys.append(request.key)
        let readyCounts = requestCountWaiters.keys.filter {
            requestedKeys.count >= $0
        }
        for count in readyCounts {
            requestCountWaiters.removeValue(forKey: count)?.resume()
        }
        return await withCheckedContinuation { continuation in
            pending[request.key] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requestedKeys.count < count else { return }
        await withCheckedContinuation { continuation in
            requestCountWaiters[count] = continuation
        }
    }

    func resolve(key: String, candidates: [String]) {
        pending.removeValue(forKey: key)?.resume(returning: candidates)
    }
}

private actor RedisKeyScanProbe {
    private let pages: [UInt64: RedisKeyScanPage]
    private let existingKeys: Set<String>
    private(set) var requestedCursors: [UInt64] = []
    private(set) var requestedPatterns: [String?] = []
    private(set) var requestedCounts: [Int] = []
    private(set) var exactLookups: [String] = []
    private(set) var progressCounts: [Int] = []

    init(
        pages: [UInt64: RedisKeyScanPage],
        existingKeys: Set<String> = []
    ) {
        self.pages = pages
        self.existingKeys = existingKeys
    }

    func fetchPage(
        cursor: UInt64,
        pattern: String?,
        count: Int
    ) throws -> RedisKeyScanPage {
        requestedCursors.append(cursor)
        requestedPatterns.append(pattern)
        requestedCounts.append(count)
        guard let page = pages[cursor] else {
            throw RedisWorkspaceError.invalidReply("SCAN")
        }
        return page
    }

    func exactLookup(_ key: String) -> Bool {
        exactLookups.append(key)
        return existingKeys.contains(key)
    }

    func record(_ progress: RedisKeyScanProgress) {
        progressCounts.append(progress.discoveredKeyCount)
    }
}
