import XCTest
import DailyPlannerApplication
import DailyPlannerDomain

final class EmailBodySanitizerTests: XCTestCase {
    private let sanitizer = StrictEmailBodySanitizer()

    func testHTMLSanitizerRemovesActiveAndRemoteContent() throws {
        let result = try sanitizer.sanitize(
            kind: .html,
            decodedBody: "<script>x()</script><form></form><img src='https://remote.test/x'><a href='https://example.test'>open</a><p>Hello</p>"
        )

        XCTAssertEqual(result.kind, .html)
        XCTAssertFalse(result.value.contains("script"))
        XCTAssertFalse(result.value.contains("x()"))
        XCTAssertFalse(result.value.contains("form"))
        XCTAssertFalse(result.value.contains("https://"))
        XCTAssertEqual(result.value, "open<p>Hello</p>")
    }

    func testHTMLSanitizerAllowsOnlyStructuralTagsWithZeroAttributes() throws {
        let html = "<p class=x onclick='run()'>Hi<br><div id=x><span><strong>bold</strong><em>em</em></span><ul><li>one</li></ul><ol><li>two</li></ol><blockquote cite=x>quote</blockquote><pre style=x><code>let x</code></pre></div></p>"
        let result = try sanitizer.sanitize(kind: .html, decodedBody: html)

        XCTAssertEqual(
            result.value,
            "<p>Hi<br><div><span><strong>bold</strong><em>em</em></span><ul><li>one</li></ul><ol><li>two</li></ol><blockquote>quote</blockquote><pre><code>let x</code></pre></div></p>"
        )
        XCTAssertFalse(result.value.contains("onclick"))
        XCTAssertFalse(result.value.contains("class="))
        XCTAssertFalse(result.value.contains("style="))
    }

    func testHTMLSanitizerSuppressesActiveContainerContentsAndDangerousElements() throws {
        let html = """
        before<script>secret-script</script><style>@import url(https://remote.test); secret-style</style>
        <template>secret-template</template><noscript>secret-noscript</noscript>
        <iframe src=data:text/html,x>secret-frame</iframe><svg><a href=file:///tmp/x>secret-svg</a></svg>
        <meta http-equiv=refresh content='0;url=https://remote.test'><base href='https://remote.test'>
        <object data='data:text/html,x'>secret-object</object><form action='https://remote.test'>kept text</form>after
        """
        let result = try sanitizer.sanitize(kind: .html, decodedBody: html)

        for forbidden in [
            "secret-script", "secret-style", "secret-template", "secret-noscript",
            "secret-frame", "secret-svg", "secret-object", "https://", "data:", "file:",
            "@import", "meta", "base", "object", "iframe", "svg",
        ] {
            XCTAssertFalse(result.value.lowercased().contains(forbidden), forbidden)
        }
        XCTAssertTrue(result.value.contains("before"))
        XCTAssertTrue(result.value.contains("kept text"))
        XCTAssertTrue(result.value.contains("after"))
    }

    func testHTMLSanitizerEscapesTextAndDoesNotReconstituteEntityMarkup() throws {
        let result = try sanitizer.sanitize(
            kind: .html,
            decodedBody: "<p>1 < 2 & 3 > 2 &lt;script&gt;alert(1)&lt;/script&gt;</p>"
        )

        XCTAssertEqual(
            result.value,
            "<p>1 &lt; 2 &amp; 3 &gt; 2 &amp;lt;script&amp;gt;alert(1)&amp;lt;/script&amp;gt;</p>"
        )
    }

    func testHTMLSanitizerHandlesMalformedMarkupWithoutProducingActiveMarkup() throws {
        let inputs = [
            "<p onclick='x' unclosed",
            "text<!-- unterminated <script>alert(1)</script>",
            "<script>never closed <p>hidden",
            "<scr<script>ipt>alert(1)</scr<script>ipt>",
        ]

        for input in inputs {
            let result = try sanitizer.sanitize(kind: .html, decodedBody: input)
            XCTAssertFalse(result.value.lowercased().contains("<script"), input)
            XCTAssertFalse(result.value.lowercased().contains("onclick="), input)
        }
    }

    func testPlainTextRemainsPlainTextAndIsNotInterpretedAsHTML() throws {
        let input = "<script>alert(1)</script> & text"
        let result = try sanitizer.sanitize(kind: .plainText, decodedBody: input)

        XCTAssertEqual(result, SanitizedEmailBody(kind: .plainText, value: input))
    }

    func testSanitizerRejectsUnsupportedKindFinitely() {
        XCTAssertThrowsError(try sanitizer.sanitize(kind: .unsupported, decodedBody: "body")) { error in
            XCTAssertEqual(error as? EmailBodySanitizerError, .unsupported)
        }
    }

    func testSanitizerEnforcesInputAndOutputUTF8Bounds() throws {
        let limit = GoogleSyncLimits.decodedBodyBytes
        XCTAssertNoThrow(try sanitizer.sanitize(kind: .plainText, decodedBody: String(repeating: "a", count: limit)))
        XCTAssertThrowsError(try sanitizer.sanitize(kind: .plainText, decodedBody: String(repeating: "a", count: limit + 1))) { error in
            XCTAssertEqual(error as? EmailBodySanitizerError, .bodyTooLarge)
        }

        let expandingHTML = String(repeating: "&", count: (limit / 5) + 1)
        XCTAssertThrowsError(try sanitizer.sanitize(kind: .html, decodedBody: expandingHTML)) { error in
            XCTAssertEqual(error as? EmailBodySanitizerError, .bodyTooLarge)
        }
    }

    func testSanitizerHandlesNearLimitAdversarialNestingInBoundedTimeAndSpace() throws {
        let depth = 8_000
        let opens = String(repeating: "<span>", count: depth)
        let unmatchedCloses = String(repeating: "</div>", count: depth)
        let paddingCount = GoogleSyncLimits.decodedBodyBytes
            - opens.utf8.count - unmatchedCloses.utf8.count
        let html = opens + unmatchedCloses + String(repeating: "x", count: paddingCount)
        XCTAssertEqual(html.utf8.count, GoogleSyncLimits.decodedBodyBytes)

        let start = ContinuousClock.now
        let result = try sanitizer.sanitize(kind: .html, decodedBody: html)
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertLessThanOrEqual(result.value.utf8.count, GoogleSyncLimits.decodedBodyBytes)
        XCTAssertTrue(result.value.hasSuffix("</span>"))
    }
}
