import XCTest
@testable import PiWork

final class AuthAccessModeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AuthAccessModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testFreshInstallStartsOnOnboarding() {
        let store = AuthAccessModeStore(defaults: defaults)

        XCTAssertEqual(store.load(), .signedOut)
        XCTAssertFalse(store.load().canUseApp)
    }

    func testLegacySignedInFlagMigratesToSignedIn() {
        defaults.set(true, forKey: AuthAccessModeStore.legacyIsSignedInKey)

        XCTAssertEqual(AuthAccessModeStore(defaults: defaults).load(), .signedIn)
    }

    func testStoredModeWinsOverTheLegacyFlag() {
        defaults.set(true, forKey: AuthAccessModeStore.legacyIsSignedInKey)
        defaults.set(AuthAccessMode.local.rawValue, forKey: AuthAccessModeStore.accessModeKey)

        XCTAssertEqual(AuthAccessModeStore(defaults: defaults).load(), .local)
    }

    func testSavingWritesBothKeysSoADowngradeStillReadsTheTruth() {
        let store = AuthAccessModeStore(defaults: defaults)

        store.save(.local)

        XCTAssertEqual(defaults.string(forKey: AuthAccessModeStore.accessModeKey), "local")
        XCTAssertFalse(defaults.bool(forKey: AuthAccessModeStore.legacyIsSignedInKey))

        store.save(.signedIn)

        XCTAssertTrue(defaults.bool(forKey: AuthAccessModeStore.legacyIsSignedInKey))
        XCTAssertEqual(AuthAccessModeStore(defaults: defaults).load(), .signedIn)
    }

    func testOnlySignedOutBlocksTheApp() {
        XCTAssertTrue(AuthAccessMode.signedIn.canUseApp)
        XCTAssertTrue(AuthAccessMode.local.canUseApp)
        XCTAssertFalse(AuthAccessMode.signedOut.canUseApp)
    }
}
