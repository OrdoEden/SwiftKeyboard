import XCTest
@testable import PinyinEngine

final class PinyinInputEngineTests: XCTestCase {
    private static let engine = PinyinInputEngine()
    private var engine: PinyinInputEngine { Self.engine }

    func testDisplaySpellingSplitsSyllables() {
        XCTAssertEqual(engine.displaySpelling(for: "nihao"), "ni hao")
        XCTAssertEqual(engine.displaySpelling(for: "haha"), "ha ha")
        XCTAssertEqual(engine.displaySpelling(for: "nver"), "nv er")
        XCTAssertEqual(engine.displaySpelling(for: "ttkaix"), "t t kai x")
        XCTAssertEqual(engine.displaySpelling(for: "zhon"), "zhon")
        XCTAssertEqual(engine.displaySpelling(for: "xi'an"), "xi'an")
    }

    func testWholeWordComesFirst() {
        let first = engine.candidates(for: "nihao").first
        XCTAssertEqual(first, .init(text: "你好", consumedPinyinCount: 5))
    }

    func testSentenceIsComposedWhenNoWholeWordExists() {
        let first = engine.candidates(for: "woaibeijingtiananmen").first
        XCTAssertEqual(first?.text, "我爱北京天安门")
        XCTAssertEqual(first?.consumedPinyinCount, 20)
    }

    func testPrefixCandidatesConsumePartOfInput() {
        let candidates = engine.candidates(for: "keyboard")
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy { $0.consumedPinyinCount == 2 })
        XCTAssertEqual(candidates.first?.text, "可")
    }

    func testApostropheSeparatesSyllables() {
        XCTAssertTrue(engine.candidates(for: "xi'an").contains { $0.text == "西安" })
        XCTAssertFalse(engine.candidates(for: "xi'an").contains { $0.text == "先" && $0.consumedPinyinCount == 5 })
    }

    func testVAliasForUmlaut() {
        XCTAssertTrue(engine.candidates(for: "nver").contains { $0.text == "女儿" })
        XCTAssertTrue(engine.candidates(for: "zhanlve").contains { $0.text == "战略" })
    }

    func testRejectsNonPinyinInput() {
        XCTAssertTrue(engine.candidates(for: "").isEmpty)
        XCTAssertTrue(engine.candidates(for: "abc1").isEmpty)
    }

    func testCustomDictionaryURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-\(UUID()).tsv")
        try "测试\tce shi\t10\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let tiny = PinyinInputEngine(dictionaryURL: url)
        XCTAssertEqual(tiny.candidates(for: "ceshi").first?.text, "测试")
        XCTAssertTrue(tiny.candidates(for: "nihao").isEmpty)
    }
}
