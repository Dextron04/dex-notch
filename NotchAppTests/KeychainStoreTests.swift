import XCTest

final class KeychainStoreTests: XCTestCase {
    func testBuildsTheAddCommand() {
        XCTAssertEqual(KeychainStore.addCommand(service: "ai.example.com", account: "notchapp", token: "abc123"),
                       #"add-generic-password -U -s "ai.example.com" -a "notchapp" -w "abc123""#)
    }
    func testQuotesAndBackslashesInTheTokenAreEscaped() {
        XCTAssertEqual(KeychainStore.addCommand(service: "s", account: "a", token: #"a"b\c"#), #"add-generic-password -U -s "s" -a "a" -w "a\"b\\c""#)
    }
    func testServiceAndAccountAreEscapedToo() {
        XCTAssertEqual(KeychainStore.addCommand(service: #"my "gw""#, account: "a", token: "t"), #"add-generic-password -U -s "my \"gw\"" -a "a" -w "t""#)
    }
    func testANewlineCannotSmuggleInASecondCommand() {
        XCTAssertNil(KeychainStore.addCommand(service: "s", account: "a", token: "abc\ndelete-generic-password -s x"))
        XCTAssertNil(KeychainStore.addCommand(service: "s\nquit", account: "a", token: "t"))
        XCTAssertNil(KeychainStore.addCommand(service: "s", account: "a\r", token: "t"))
    }
    func testControlCharactersAndNonASCIIAreRefused() {      // security prints non-ASCII secrets as hex, so they could never read back
        for bad in ["tab\there", "nul\u{0}x", "caf\u{e9}", "tick\u{2713}", "bell\u{7}"] { XCTAssertNil(KeychainStore.addCommand(service: "s", account: "a", token: bad), bad.debugDescription) }
    }
    func testEmptyValuesAreRefused() {
        XCTAssertNil(KeychainStore.addCommand(service: "s", account: "a", token: ""))
        XCTAssertNil(KeychainStore.addCommand(service: "", account: "a", token: "t"))
        XCTAssertNil(KeychainStore.addCommand(service: "s", account: "", token: "t"))
    }
    func testSpacesAndShellCharactersAreHarmlessInsideTheQuotes() {
        XCTAssertEqual(KeychainStore.addCommand(service: "s", account: "a", token: "a b $HOME `x` ; #"), #"add-generic-password -U -s "s" -a "a" -w "a b $HOME `x` ; #""#)
    }
}
