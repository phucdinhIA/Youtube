//
//  TransDuckCaptionParserTests.swift
//  YatteeTests
//
//  Checks timed Vietnamese caption conversion used by native dubbing.
//

import Foundation
import Testing
@testable import Yattee

@Suite("TransDuck caption parsing")
struct TransDuckCaptionParserTests {
    @Test("WebVTT cues retain timing and decode styled text")
    func parsesWebVTT() throws {
        let source = """
        WEBVTT

        first
        00:00:01.200 --> 00:00:03.450 align:start
        <v Speaker>Hello &amp; welcome</v>

        00:04.000 --> 00:05.500
        A second line
        with more words

        """
        let cues = try TransDuckCaptionParser.parseWebVTT(Data(source.utf8))
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello & welcome")
        #expect(cues[0].start == 1.2)
        #expect(cues[0].end == 3.45)
        #expect(cues[1].text == "A second line with more words")
    }

    @Test("Translated SRT includes Vietnamese text and millisecond timing")
    func writesSRT() throws {
        let cue = TransDuckCue(index: 0, text: "Hello", start: 1.2, end: 3.45)
        let url = try TransDuckCaptionParser.makeSRT([
            TransDuckTranslation(cue: cue, text: "Xin chào", usedAI: true)
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try String(contentsOf: url, encoding: .utf8)
        #expect(output.contains("00:00:01,200 --> 00:00:03,450"))
        #expect(output.contains("Xin chào"))
    }
}
