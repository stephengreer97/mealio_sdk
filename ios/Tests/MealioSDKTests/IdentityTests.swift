// Round 7: which hosts the native network block runs on. Runs the vectors of
// protocol/shared-identity-hosts.json (copied into Resources), and checks that
// SharedIdentity.hosts and the copy match the source file.

import Foundation
import XCTest
@testable import MealioSDK

final class IdentityTests: XCTestCase {

    private func file() throws -> [String: JSONValue] {
        try XCTUnwrap(JSONValue.parse(try Fixtures.data("shared-identity-hosts", "json"))?.objectValue)
    }

    func testTheListIsTheProtocolFilesList() throws {
        let hosts = try XCTUnwrap(file()["hosts"]?.arrayValue).compactMap { $0.stringValue }
        XCTAssertEqual(SharedIdentity.hosts, hosts)
    }

    /// The bundled copy is byte for byte protocol/shared-identity-hosts.json,
    /// when the checkout is there to read (CI runs from the repository).
    func testTheBundledCopyIsInSyncWithProtocol() throws {
        let here = URL(fileURLWithPath: String(describing: #filePath))
        let source = here.deletingLastPathComponent()      // MealioSDKTests
            .deletingLastPathComponent()                    // Tests
            .deletingLastPathComponent()                    // ios
            .deletingLastPathComponent()                    // repository
            .appendingPathComponent("protocol/shared-identity-hosts.json")
        guard let want = try? Data(contentsOf: source) else {
            throw XCTSkip("protocol/ not readable from here: \(source.path)")
        }
        XCTAssertEqual(try Fixtures.data("shared-identity-hosts", "json"), want,
                       "copy protocol/shared-identity-hosts.json to ios/Tests/MealioSDKTests/Resources/")
    }

    func testExcludedVectors() throws {
        let cases = try XCTUnwrap(file()["vectors"]?["excluded"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        let allowlist = Allowlist()
        for c in cases {
            let store = try XCTUnwrap(c["store"]?.stringValue)
            let host = try XCTUnwrap(c["host"]?.stringValue)
            let want = try XCTUnwrap(c["excluded"]?.boolValue)
            let hosts = try XCTUnwrap(allowlist.hostsFor(store), store)
            XCTAssertEqual(SharedIdentity.isShared(host, store: hosts), want, "\(store) \(host)")
        }
    }

    func testBlockHostsVectors() throws {
        let cases = try XCTUnwrap(file()["vectors"]?["blockHosts"]?.arrayValue)
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let store = try XCTUnwrap(c["store"]?.stringValue)
            let want = try XCTUnwrap(c["blockHosts"]?.arrayValue).compactMap { $0.stringValue }
            let allowlist = Allowlist()
            if let widen = c["widen"] {
                let patch = AllowlistPayload.StorePatch(
                    hosts: widen["hosts"]?.arrayValue?.compactMap { $0.stringValue },
                    authHosts: widen["authHosts"]?.arrayValue?.compactMap { $0.stringValue })
                allowlist.widen(AllowlistPayload(stores: [store: patch]))
            }
            let hosts = try XCTUnwrap(allowlist.hostsFor(store), store)
            XCTAssertEqual(SharedIdentity.nativeBlockHosts(hosts), want, store)
        }
    }

    /// The rule spelled out, beyond the vectors.
    func testTheRule() {
        let safeway = StoreHosts(hosts: ["safeway.com"], authHosts: ["albertsons.com", "albertsons.okta.com"])
        XCTAssertEqual(SharedIdentity.storeNames(safeway), ["safeway", "albertsons"])
        // A shared entry itself, or any of its subdomains, is shared...
        XCTAssertTrue(SharedIdentity.isShared("okta.com", store: safeway))
        XCTAssertTrue(SharedIdentity.isShared("login.okta.com", store: safeway))
        XCTAssertTrue(SharedIdentity.isShared("accounts.google.com", store: safeway))
        // ...unless the label just left of the entry names the store.
        XCTAssertFalse(SharedIdentity.isShared("albertsons.okta.com", store: safeway))
        XCTAssertFalse(SharedIdentity.isShared("safeway.okta.com", store: safeway))
        XCTAssertFalse(SharedIdentity.isShared("sso.albertsons.okta.com", store: safeway))
        // Only that label: a name deeper in does not count.
        XCTAssertTrue(SharedIdentity.isShared("albertsons.login.okta.com", store: safeway))
        // Whole labels: these are under no entry.
        XCTAssertFalse(SharedIdentity.isShared("notokta.com", store: safeway))
        XCTAssertFalse(SharedIdentity.isShared("okta.com.evil.io", store: safeway))
        // Case and one trailing dot do not matter.
        XCTAssertTrue(SharedIdentity.isShared("LOGIN.OKTA.COM.", store: safeway))
        // Order kept, repeats and shared hosts left out.
        let kroger = StoreHosts(hosts: [], authHosts: ["api.kroger.com", "login.kroger.com", "kroger.com", "accounts.google.com", "Kroger.com"])
        XCTAssertEqual(SharedIdentity.nativeBlockHosts(kroger), ["api.kroger.com", "login.kroger.com", "kroger.com"])
    }

    /// Every bundled store blocks on at least one host (the Kroger family on
    /// kroger.com, in the sign-in sheet), and none on a shared provider.
    func testEveryBundledStoreHasBlockingHostsAndNoneIsShared() {
        for (id, hosts) in Allowlist.bundledStores {
            let block = SharedIdentity.nativeBlockHosts(hosts)
            XCTAssertFalse(block.isEmpty, id)
            for h in block {
                let under = SharedIdentity.hosts.first { h == $0 || h.hasSuffix("." + $0) }
                if let e = under {
                    XCTAssertNotEqual(h, e, "\(id) blocks the shared provider \(e)")
                }
            }
        }
        let ralphs = SharedIdentity.nativeBlockHosts(Allowlist.bundledStores["ralphs"] ?? StoreHosts(hosts: [], authHosts: []))
        XCTAssertTrue(ralphs.contains("kroger.com"))
    }
}
