import XCTest
@testable import ServerPad

final class ServerPadTests: XCTestCase {
    func testParsesRequestWithBody() {
        let raw = Data("POST /files/upload?name=a.txt HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let request = HTTPRequest.parse(raw)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/files/upload")
        XCTAssertEqual(request?.query["name"], "a.txt")
        XCTAssertEqual(String(data: request?.body ?? Data(), encoding: .utf8), "hello")
    }
}

