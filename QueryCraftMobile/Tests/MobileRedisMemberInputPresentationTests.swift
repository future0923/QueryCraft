import XCTest
import SwiftUI
import UIKit
import QueryCraftMobileCore
@testable import QueryCraftMobileProof

@MainActor final class MobileRedisMemberInputPresentationTests: XCTestCase {
    func testPhysicalHashInputCreateUpdateAndCleanup() async throws {
        let context = try physicalContext()
        let (profile, password, database, client, owner, key) = context
        try await client.connect()
        do {
            let existed = try await client.execute(["EXISTS", key], databaseIndex: database).integerValue
            guard existed == 0 else { throw RedisWorkspaceError.mutationConflict(key) }
            let action = MobileRedisKeyAction(mode: .create(.hash), database: database, service: MobileRedisKeyActionService(profile: profile, password: password))
            action.name = key; action.addRow()
            action.rows[0].firstValue = "__qc_test_owner__"; action.rows[0].secondValue = owner
            action.addRow()
            let host = UIHostingController(rootView: MobileRedisKeyActionView(action: action, close: {}).mobileAppearance())
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
            try await settle(host)
            try await enterHashMember(field: "输入字段", value: "真机输入内容 雪", host: host)
            XCTAssertEqual(action.rows.count, 2)
            window.endEditing(true); action.safetyLock.disable(); action.prepare()
            XCTAssertNotNil(action.preview, action.message ?? "No create preview")
            await action.submit()?.value
            XCTAssertTrue(action.succeeded, action.message ?? "Create failed")
            let created = try await client.execute(["HGET", key, "输入字段"], databaseIndex: database).stringValue
            XCTAssertEqual(created, "真机输入内容 雪")

            let editor = MobileRedisEditor(key: key, database: database, service: MobileRedisMutationService(profile: profile, password: password))
            await editor.reload()?.value; editor.addRow()
            let editHost = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}).mobileAppearance())
            window.rootViewController = editHost; try await settle(editHost)
            try await enterHashMember(field: "新增字段", value: "真机编辑内容", host: editHost)
            window.endEditing(true); editor.safetyLock.disable(); await editor.prepare()?.value
            XCTAssertNotNil(editor.preview, editor.message ?? "No edit preview")
            await editor.submit()?.value
            XCTAssertFalse(editor.needsVerification, editor.message ?? "Edit outcome unknown")
            let updated = try await client.execute(["HGET", key, "新增字段"], databaseIndex: database).stringValue
            XCTAssertEqual(updated, "真机编辑内容")
            let row = try XCTUnwrap(editor.rows.first { $0.firstValue == "新增字段" })
            editor.removeRow(row.id); await editor.prepare()?.value; await editor.submit()?.value
            let removed = try await client.execute(["HEXISTS", key, "新增字段"], databaseIndex: database).integerValue
            XCTAssertEqual(removed, 0)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "physical-hash-input-and-write"; attachment.lifetime = .keepAlways; add(attachment)
            try await cleanupPhysical(client, database: database, key: key, owner: owner)
            let cleanup = XCTAttachment(string: "Owned Hash acceptance key removed and EXISTS=0: " + key)
            cleanup.name = "physical-redis-cleanup"; cleanup.lifetime = .keepAlways; add(cleanup)
            await client.close()
        } catch {
            do { try await cleanupPhysical(client, database: database, key: key, owner: owner) }
            catch { XCTFail("Owned test key cleanup failed; rerun the explicit cleanup case: \(error.localizedDescription)") }
            await client.close(); throw error
        }
    }

    // Also callable separately after an interrupted run, with the same owner env.
    func testPhysicalRedisCleanup() async throws {
        let (_, _, database, client, owner, key) = try physicalContext()
        try await client.connect()
        do { try await cleanupPhysical(client, database: database, key: key, owner: owner); await client.close() }
        catch { await client.close(); throw error }
    }

    private func physicalContext() throws -> (MobileConnectionProfile, String?, Int, RedisClient, String, String) {
        let env = ProcessInfo.processInfo.environment
        guard env["QUERYCRAFT_PHYSICAL_REDIS_ACCEPTANCE"] == "1", let owner = env["QUERYCRAFT_PHYSICAL_REDIS_OWNER"], UUID(uuidString: owner) != nil else {
            throw XCTSkip("Physical Redis writes require explicit user-authorized acceptance env")
        }
        let profiles = try MobileLibraryRepository().load().profiles.filter { $0.driver == .redis }
        let preferred = profiles.filter { $0.name == "测试" }
        let profile = try XCTUnwrap(preferred.count == 1 ? preferred.first : profiles.count == 1 ? profiles.first : nil, "Select the intended saved Redis profile before physical acceptance")
        let password = try MobileKeychainStore().password(for: profile.id)
        guard !profile.requiresPassword || password != nil else { throw MobileQueryError.invalidConnection }
        let database = try XCTUnwrap(RedisConnectionConfiguration.databaseIndex(from: profile.database))
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: profile.username, password: password, databaseIndex: database))
        return (profile, password, database, client, owner, "__querycraft_ios_acceptance__:" + owner)
    }
    private func cleanupPhysical(_ client: RedisClient, database: Int, key: String, owner: String) async throws {
        // Delete only our UUID key whose Hash ownership marker still matches.
        let script = "if redis.call('EXISTS',KEYS[1]) == 0 then return 0 end; if redis.call('HGET',KEYS[1],'__qc_test_owner__') == ARGV[1] then return redis.call('DEL',KEYS[1]) end; return 0"
        let reply = try await client.execute(["EVAL", script, "1", key, owner], databaseIndex: database)
        if case .error(let message) = reply { throw RedisClientError(message: message) }
        let remaining = try await client.execute(["EXISTS", key], databaseIndex: database).integerValue
        guard remaining == 0 else { throw RedisWorkspaceError.mutationConflict(key) }
    }
    private func enterHashMember(field: String, value: String, host: UIViewController) async throws {
        var input = descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "字段" && ($0.text ?? "").isEmpty }
        if input == nil, let list = descendants(host.view).compactMap({ $0 as? UICollectionView }).first {
            search: for section in 0..<list.numberOfSections {
                for item in 0..<list.numberOfItems(inSection: section) {
                    list.scrollToItem(at: .init(item: item, section: section), at: .centeredVertically, animated: false)
                    try await settle(host)
                    input = descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "字段" && ($0.text ?? "").isEmpty }
                    if input != nil { break search }
                }
            }
        }
        let first = try XCTUnwrap(input)
        try performFormPrimaryAction(containing: first)
        enter(field, into: first); try await settle(host)
        var node: UIView? = first
        while node != nil, !(node is UICollectionViewCell) { node = node?.superview }
        let cell = try XCTUnwrap(node)
        let second: UIView
        if let value = descendants(cell).compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == "值" }) { second = value }
        else { second = try XCTUnwrap(descendants(cell).compactMap { $0 as? UITextView }.first { ($0.text ?? "").isEmpty }) }
        try performFormPrimaryAction(containing: second)
        enter(value, into: second); try await settle(host)
    }

    func testTypingIntoCreationRowsDoesNotPerformFormRowDelete() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKey() }
        for type in [RedisKeyType.hash, .list, .set, .sortedSet] {
            let action = MobileRedisKeyAction(mode: .create(type), database: 0, service: InputOnlyKeyService())
            action.name = "draft"; action.addRow()
            let id = try XCTUnwrap(action.rows.first?.id)
            var firstInput: UIView?
            let host = UIHostingController(rootView: MobileRedisKeyActionView(action: action, close: {}).mobileAppearance())
            window.rootViewController = host; window.makeKeyAndVisible()
            try await settle(host)
            if type != .list {
                let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == (type == .hash ? "字段" : "成员") })
                firstInput = field
                try performFormPrimaryAction(containing: field)
                XCTAssertEqual(action.rows.map(\.id), [id], "Tapping a text field must not invoke Delete Member")
                enter("字段 雪", into: field)
                try await settle(host)
                XCTAssertEqual(action.rows.first?.firstValue, "字段 雪")
            }
            if type != .set {
                let title = type == .sortedSet ? "分数" : "值"
                let input: UIView
                if let field = descendants(host.view).compactMap({ $0 as? UITextField }).first(where: { $0.placeholder == title }) { input = field }
                else { input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextView }.first { ($0.text ?? "").isEmpty || $0.text == "0" }) }
                try performFormPrimaryAction(containing: input)
                XCTAssertEqual(action.rows.map(\.id), [id])
                enter(type == .sortedSet ? "1.5" : "输入内容 你好", into: input)
                try await settle(host)
                XCTAssertEqual(action.rows.first?.secondValue, type == .sortedSet ? "1.5" : "输入内容 你好")
                if let firstInput {
                    let left = firstInput.convert(firstInput.bounds, to: host.view), right = input.convert(input.bounds, to: host.view)
                    XCTAssertGreaterThanOrEqual(right.minX, left.maxX, "Member key must be left of its value")
                    XCTAssertEqual(left.minY, right.minY, accuracy: 12, "Key/value inputs must share a horizontal row")
                }
            }
            if let output = ProcessInfo.processInfo.environment["PROOF_DRIVER_PREVIEW_OUTPUT"] {
                window.endEditing(true); try await settle(host)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: URL(fileURLWithPath: output).appending(path: "redis-member-create-" + type.rawValue + "-" + (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone") + ".png"))
            }
            window.endEditing(true)
            action.safetyLock.disable(); action.prepare()
            XCTAssertNotNil(action.preview, action.message ?? type.rawValue)
            action.removeRow(id)
            try await settle(host)
            XCTAssertTrue(action.rows.isEmpty)
        }
    }

    func testTypingAndDeletingFocusedHashEditorMemberKeepsOtherRows() async throws {
        guard ProcessInfo.processInfo.environment["PROOF_REDIS_PORT"] != nil else { throw XCTSkip("Requires owned Redis fixture") }
        let profile = try MobileRedisMutationTests.profile(), key = "querycraft:hash-input:" + UUID().uuidString
        let client = RedisClient(configuration: .init(host: profile.host, port: profile.port, username: "", password: nil, databaseIndex: 0))
        try await client.connect(); _ = try await client.execute(["HSET", key, "existing", "keep"])
        do {
            let editor = MobileRedisEditor(key: key, database: 0, service: MobileRedisMutationService(profile: profile, password: nil))
            await editor.reload()?.value; editor.addRow()
            let newID = try XCTUnwrap(editor.rows.last?.id)
            let host = UIHostingController(rootView: MobileRedisEditorView(editor: editor, close: {}).mobileAppearance())
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.endEditing(true); window.isHidden = true; previous?.makeKey(); editor.close() }
            try await settle(host)
            let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first { $0.placeholder == "字段" && ($0.text ?? "").isEmpty })
            try performFormPrimaryAction(containing: field)
            XCTAssertEqual(editor.rows.count, 2); XCTAssertTrue(editor.selectedRowIDs.isEmpty)
            enter("new-field", into: field); try await settle(host)
            XCTAssertEqual(editor.rows.last?.firstValue, "new-field")
            editor.removeRow(newID)
            // A queued keyboard callback after removal must neither trap nor edit another row.
            enter("late", into: field); try await settle(host)
            XCTAssertEqual(editor.rows.count, 1); XCTAssertEqual(editor.rows[0].firstValue, "existing")
            XCTAssertFalse(editor.rows[0].isDeleted); XCTAssertFalse(editor.hasChanges)
            _ = try await client.execute(["DEL", key]); await client.close()
        } catch { _ = try? await client.execute(["DEL", key]); await client.close(); throw error }
    }

    private func performFormPrimaryAction(containing input: UIView) throws {
        var node: UIView? = input
        while node != nil, !(node is UICollectionViewCell) { node = node?.superview }
        let cell = try XCTUnwrap(node as? UICollectionViewCell)
        while node != nil, !(node is UICollectionView) { node = node?.superview }
        let list = try XCTUnwrap(node as? UICollectionView), path = try XCTUnwrap(list.indexPath(for: cell))
        XCTAssertTrue(list.delegate?.responds(to: #selector(UICollectionViewDelegate.collectionView(_:performPrimaryActionForItemAt:))) == true)
        // Same public UICollectionView delegate entry seen in the physical crash.
        // No desktop mouse movement or keyboard event injection is involved.
        list.delegate?.collectionView?(list, performPrimaryActionForItemAt: path)
    }
    private func enter(_ text: String, into view: UIView) {
        if let field = view as? UITextField {
            field.becomeFirstResponder(); field.selectAll(nil); field.insertText(text); field.sendActions(for: .editingChanged)
        } else if let input = view as? UITextView {
            input.becomeFirstResponder(); input.selectAll(nil); input.insertText(text)
        }
    }
    private func settle(_ host: UIViewController) async throws {
        try await Task.sleep(for: .milliseconds(180)); host.view.layoutIfNeeded()
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}

private struct InputOnlyKeyService: MobileRedisKeyActing {
    func perform(_ operation: MobileRedisKeyOperation) async throws { throw RedisWorkspaceError.unavailable }
    func inspect(_ references: [RedisKeyReference]) async throws -> [MobileRedisKeyStatus] { throw RedisWorkspaceError.unavailable }
}
