//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Foundation
import Testing
@testable import SWBUtil

@Suite fileprivate struct JSONPropertyListParserTests {
    private func parse(_ json: String) throws -> PropertyListItem {
        try PropertyList.fromJSONData(Array(json.utf8))
    }

    @Test
    func scalarsAndContainers() throws {
        #expect(try parse(#"{"a": 1, "b": -12, "c": "x", "d": [], "e": {}, "f": [1, "2", [3]]}"#) == .plDict([
            "a": .plInt(1),
            "b": .plInt(-12),
            "c": .plString("x"),
            "d": .plArray([]),
            "e": .plDict([:]),
            "f": .plArray([.plInt(1), .plString("2"), .plArray([.plInt(3)])]),
        ]))
        #expect(try parse("[true, false]") == .plArray([.plBool(true), .plBool(false)]))
        #expect(try parse("[1.5, -0.25, 1e3, 2E-2, 9223372036854775808]") == .plArray([
            .plDouble(1.5), .plDouble(-0.25), .plDouble(1000), .plDouble(0.02), .plDouble(9223372036854775808),
        ]))
        #expect(try parse(" \n\t[ ]\r\n") == .plArray([]))
        #expect(try parse("\u{FEFF}[]") == .plArray([]))
    }

    @Test
    func strings() throws {
        #expect(try parse(#"["a\"b\\c\/d\b\f\n\r\t"]"#) == .plArray([.plString("a\"b\\c/d\u{8}\u{C}\n\r\t")]))
        #expect(try parse(#"["\u0041\u00e9\u4e2d", "\ud83d\ude00", "é中😀"]"#) == .plArray([
            .plString("Aé中"), .plString("😀"), .plString("é中😀"),
        ]))
        #expect(try parse(#"{"k\u0031": "v", "k1": "w"}"#) == .plDict(["k1": .plString("w")]))
    }

    @Test
    func invalidInput() {
        for json in ["", "1", "\"s\"", "null", "[null]", "[1,]", "{\"a\" 1}", "{\"a\": 1,}", "[01]", "[1.]", "[-]",
                     "[1e]", "[\"a]", "[\"\\x\"]", "[\"\\ud83d\"]", "[\"\\ude00\"]", "[\"a\u{1}\"]", "[] []", "[tru]", "{1: 2}"] {
            #expect(throws: PropertyListConversionError.invalidStream, "\(json)") {
                try parse(json)
            }
        }
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: PropertyListConversionError.invalidStream) {
            try parse(deep)
        }
    }

    /// Without booleans and floating point numbers (whose Foundation bridging differs between platforms), the
    /// result matches the JSONSerialization-based conversion exactly.
    @Test
    func matchesJSONSerialization() throws {
        var projects: [Any] = []
        for p in 0..<40 {
            var targets: [Any] = []
            for t in 0..<25 {
                targets.append([
                    "guid": "PACKAGE-TARGET:\(p)-\(t)",
                    "name": "Target \(t) \u{e9}\u{4e2d}\u{1F600} \"quoted\" back\\slash/ tab\t",
                    "buildSettings": ["OTHER_SWIFT_FLAGS": ["$(inherited)", "-DFOO=\(t)"], "SWIFT_VERSION": "5"],
                    "dependencies": (0..<t).map { ["guid": "PACKAGE-TARGET:\(p)-\($0)", "platformFilters": [] as [Any]] },
                    "count": t * 1000 - 500,
                ])
            }
            projects.append(["guid": "PROJECT:\(p)", "targets": targets, "empty": [:] as [String: Any]])
        }
        for options: JSONSerialization.WritingOptions in [[], [.prettyPrinted, .sortedKeys], [.withoutEscapingSlashes]] {
            let data = try JSONSerialization.data(withJSONObject: projects, options: options)
            #expect(try PropertyList.fromJSONData(data) == PropertyList.fromJSONDataUsingJSONSerialization(data))
        }
    }

    /// Parity on a real document: `SWB_JSON_PARITY_FILE=<path to a PIF or other JSON file> swift test ...`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWB_JSON_PARITY_FILE"] != nil))
    func matchesJSONSerializationOnFile() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWB_JSON_PARITY_FILE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(try PropertyList.fromJSONData(data) == PropertyList.fromJSONDataUsingJSONSerialization(data))
    }
}
