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

/// A JSON parser that builds a `PropertyListItem` directly from UTF-8 bytes.
///
/// `JSONSerialization` builds Foundation objects that then have to be bridged to Swift values one by one. On
/// non-Darwin platforms that bridging dominates, and loading a large PIF spends most of its time there.
///
/// Mapping, matching `PropertyList.fromJSONData` on Darwin: objects become `.plDict` (the last duplicate key
/// wins), arrays `.plArray`, strings `.plString`, `true`/`false` `.plBool`, integers that fit in `Int`
/// `.plInt`, and other numbers `.plDouble`. The top-level value must be an object or an array, as with
/// `JSONSerialization` without `.fragmentsAllowed`. `null` has no property list representation and is rejected.
/// Invalid UTF-8 inside strings is replaced with U+FFFD rather than rejected.
struct JSONPropertyListParser: ~Copyable {
    private let bytes: UnsafeBufferPointer<UInt8>
    private var index: Int = 0

    private init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) throws -> PropertyListItem {
        var parser = JSONPropertyListParser(bytes)
        parser.skipByteOrderMark()
        parser.skipWhitespace()
        guard parser.index < bytes.count, bytes[parser.index] == UInt8(ascii: "{") || bytes[parser.index] == UInt8(ascii: "[") else {
            throw PropertyListConversionError.invalidStream
        }
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == bytes.count else {
            throw PropertyListConversionError.invalidStream
        }
        return value
    }

    // Deep enough for any real PIF; bounds recursion on hostile input.
    private static let maximumDepth = 512

    private mutating func skipByteOrderMark() {
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            index = 3
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                index += 1
            default:
                return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> PropertyListItem {
        guard depth < Self.maximumDepth, index < bytes.count else {
            throw PropertyListConversionError.invalidStream
        }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth + 1)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth + 1)
        case UInt8(ascii: "\""):
            return .plString(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .plBool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .plBool(false)
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw PropertyListConversionError.invalidStream
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard bytes.count - index >= count else {
            throw PropertyListConversionError.invalidStream
        }
        let start = literal.utf8Start
        for offset in 0..<count where bytes[index + offset] != start[offset] {
            throw PropertyListConversionError.invalidStream
        }
        index += count
    }

    private mutating func parseObject(depth: Int) throws -> PropertyListItem {
        index += 1 // {
        var result: [String: PropertyListItem] = [:]
        skipWhitespace()
        if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .plDict(result)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw PropertyListConversionError.invalidStream
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw PropertyListConversionError.invalidStream
            }
            index += 1
            skipWhitespace()
            result[key] = try parseValue(depth: depth)
            skipWhitespace()
            guard index < bytes.count else {
                throw PropertyListConversionError.invalidStream
            }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .plDict(result)
            } else {
                throw PropertyListConversionError.invalidStream
            }
        }
    }

    private mutating func parseArray(depth: Int) throws -> PropertyListItem {
        index += 1 // [
        var result: [PropertyListItem] = []
        skipWhitespace()
        if index < bytes.count && bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .plArray(result)
        }
        while true {
            skipWhitespace()
            result.append(try parseValue(depth: depth))
            skipWhitespace()
            guard index < bytes.count else {
                throw PropertyListConversionError.invalidStream
            }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .plArray(result)
            } else {
                throw PropertyListConversionError.invalidStream
            }
        }
    }

    private mutating func parseString() throws -> String {
        index += 1 // opening quote
        let start = index
        // Fast path: no escapes, so the bytes between the quotes are the string.
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let string = try Self.makeString(UnsafeBufferPointer(rebasing: bytes[start..<index]))
                index += 1
                return string
            }
            if byte == UInt8(ascii: "\\") {
                break
            }
            if byte < 0x20 {
                throw PropertyListConversionError.invalidStream
            }
            index += 1
        }
        var scalars: [UInt8] = Array(bytes[start..<index])
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return try scalars.withUnsafeBufferPointer { try Self.makeString($0) }
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else {
                    throw PropertyListConversionError.invalidStream
                }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): scalars.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): scalars.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): scalars.append(0x08)
                case UInt8(ascii: "f"): scalars.append(0x0C)
                case UInt8(ascii: "n"): scalars.append(0x0A)
                case UInt8(ascii: "r"): scalars.append(0x0D)
                case UInt8(ascii: "t"): scalars.append(0x09)
                case UInt8(ascii: "u"):
                    let codeUnit = try parseHex4()
                    var scalar: Unicode.Scalar?
                    if UTF16.isLeadSurrogate(codeUnit) {
                        guard bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw PropertyListConversionError.invalidStream
                        }
                        index += 2
                        let trail = try parseHex4()
                        guard UTF16.isTrailSurrogate(trail) else {
                            throw PropertyListConversionError.invalidStream
                        }
                        scalar = Unicode.Scalar(0x10000 + ((UInt32(codeUnit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
                    } else if UTF16.isTrailSurrogate(codeUnit) {
                        throw PropertyListConversionError.invalidStream
                    } else {
                        scalar = Unicode.Scalar(codeUnit)
                    }
                    guard let scalar else {
                        throw PropertyListConversionError.invalidStream
                    }
                    scalars.append(contentsOf: UTF8.encode(scalar)!)
                default:
                    throw PropertyListConversionError.invalidStream
                }
            default:
                if byte < 0x20 {
                    throw PropertyListConversionError.invalidStream
                }
                scalars.append(byte)
                index += 1
            }
        }
        throw PropertyListConversionError.invalidStream
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard bytes.count - index >= 4 else {
            throw PropertyListConversionError.invalidStream
        }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw PropertyListConversionError.invalidStream
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    private static func makeString(_ utf8: UnsafeBufferPointer<UInt8>) throws -> String {
        return String(decoding: utf8, as: UTF8.self)
    }

    private mutating func parseNumber() throws -> PropertyListItem {
        let start = index
        var isInteger = true
        if bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        // JSON grammar: int = "0" / [1-9] *DIGIT
        guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
            throw PropertyListConversionError.invalidStream
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            guard index > digits else {
                throw PropertyListConversionError.invalidStream
            }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            let digits = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            guard index > digits else {
                throw PropertyListConversionError.invalidStream
            }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
        if isInteger, let value = Int(text) {
            return .plInt(value)
        }
        guard let value = Double(text) else {
            throw PropertyListConversionError.invalidStream
        }
        return .plDouble(value)
    }
}
