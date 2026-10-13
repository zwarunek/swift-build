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

import SWBUtil
public import SWBProtocol

public typealias FileTextEncoding = SWBProtocol.FileTextEncoding

public import struct Foundation.Data
public import class Foundation.NSNumber
public import class Foundation.NSString

#if canImport(Darwin)
import class CoreFoundation.CFString
import var CoreFoundation.kCFStringEncodingInvalidId
import func CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import func CoreFoundation.CFStringConvertEncodingToIANACharSetName
import func CoreFoundation.CFStringConvertIANACharSetNameToEncoding
import func CoreFoundation.CFStringConvertNSStringEncodingToEncoding
#endif

#if canImport(Darwin)
import struct CoreFoundation.ObjCBool
public import struct Foundation.StringEncodingDetectionOptionsKey
#endif

// The naming convention in Foundation is rather unfortunate.
// The explicit-endian encodings do NOT add any BOM, and the non-explicit endian
// encodings (except UTF-8) DO add a BOM based on the host byte order. Be aware.
public extension FileTextEncoding {
    init?(stringEncoding: String.Encoding) {
        #if canImport(Darwin)
        let cfencoding = CFStringConvertNSStringEncodingToEncoding(stringEncoding.rawValue)
        if cfencoding != kCFStringEncodingInvalidId, let name = CFStringConvertEncodingToIANACharSetName(cfencoding).map(String.init) {
            self.init(name)
            return
        }
        #else
        if let encoding = Self.portableEncodings.first(where: { $0.stringEncoding == stringEncoding }) {
            self = encoding.textEncoding
            return
        }
        #endif
        return nil
    }

    /// Convert the given encoding to an `NSStringEncoding`.
    var stringEncoding: String.Encoding? {
        #if canImport(Darwin)
        let cfencoding = CFStringConvertIANACharSetNameToEncoding(rawValue.asCFString)
        if cfencoding != kCFStringEncodingInvalidId {
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfencoding))
        }
        #else
        // Without CoreFoundation, accept IANA names case-insensitively (like CFString does) and numeric NSStringEncoding values.
        let name = rawValue.lowercased()
        if let encoding = Self.portableEncodings.first(where: { $0.names.contains(name) }) {
            return encoding.stringEncoding
        }
        if let value = UInt(rawValue), let encoding = Self.portableEncodings.first(where: { $0.stringEncoding.rawValue == value }) {
            return encoding.stringEncoding
        }
        #endif
        return nil
    }

    /// Returns a localized, human-readable name of the encoding.
    var localizedName: String? {
        if let stringEncoding {
            return String.localizedName(of: stringEncoding)
        }
        return nil
    }

    /// Initializes a string from the given byte sequence.
    static func string(from bytes: [UInt8], encoding: FileTextEncoding?) -> (string: String, originalEncoding: FileTextEncoding)? {
        if let encoding {
            guard let string = String(bytes, encoding: encoding) else { return nil }
            return (string, encoding)
        }

        #if canImport(Darwin)
        var convertedString: NSString?
        var usedLossyConversion: ObjCBool = true
        let stringEncoding = String.Encoding(rawValue: NSString.stringEncoding(for: Data(bytes), encodingOptions: [.allowLossyKey: NSNumber(value: false)], convertedString: &convertedString, usedLossyConversion: &usedLossyConversion))
        if let convertedString = convertedString as String?, let discoveredEncoding = FileTextEncoding(stringEncoding: stringEncoding), !usedLossyConversion.boolValue {
            // Always detect ASCII as UTF-8, because we want to prefer Unicode encodings
            return (convertedString, stringEncoding == .ascii ? FileTextEncoding.utf8 : discoveredEncoding)
        }
        #else
        if let detected = detectUnicodeEncoding(bytes) {
            return detected
        }
        #endif

        return nil
    }

    /// Detects a Unicode encoding without CoreFoundation: a byte-order mark first, then valid UTF-8,
    /// then BOM-less UTF-16 recognized by NUL bytes in every other position (ASCII-range text).
    ///
    /// Mirrors what `NSString.stringEncoding(for:)` reports on Darwin for the encodings Xcode accepts in
    /// `.strings` files: UTF-8 (with any BOM kept in the string), and UTF-16/UTF-32 with a BOM reported
    /// as the BOM-carrying `utf-16`/`utf-32` encodings.
    internal static func detectUnicodeEncoding(_ bytes: [UInt8]) -> (string: String, originalEncoding: FileTextEncoding)? {
        // UTF-32 BOMs must be checked before UTF-16, since FF FE 00 00 starts with the UTF-16LE BOM.
        if bytes.starts(with: FileTextEncoding.utf32le.byteOrderMark) || bytes.starts(with: FileTextEncoding.utf32be.byteOrderMark) {
            if let string = String(bytes, encoding: .utf32) { return (string, .utf32) }
        }
        if bytes.starts(with: FileTextEncoding.utf16le.byteOrderMark) || bytes.starts(with: FileTextEncoding.utf16be.byteOrderMark) {
            if let string = String(bytes, encoding: .utf16) { return (string, .utf16) }
        }
        if let string = String(validatingUTF8Bytes: bytes) {
            return (string, .utf8)
        }
        if bytes.count >= 2 && bytes.count % 2 == 0 {
            let evens = stride(from: 0, to: bytes.count, by: 2).map { bytes[$0] }
            let odds = stride(from: 1, to: bytes.count, by: 2).map { bytes[$0] }
            let nulInOdd = odds.contains(0), nulInEven = evens.contains(0)
            if nulInOdd && !nulInEven, let string = String(bytes, encoding: .utf16le) {
                return (string, .utf16le)
            }
            if nulInEven && !nulInOdd, let string = String(bytes, encoding: .utf16be) {
                return (string, .utf16be)
            }
        }
        return nil
    }
}

#if !canImport(Darwin)
extension FileTextEncoding {
    /// Encodings Foundation can convert on every platform, with the IANA names CFString accepts for them.
    fileprivate struct PortableEncoding {
        let textEncoding: FileTextEncoding
        let names: Set<String>
        let stringEncoding: String.Encoding
    }

    fileprivate static let portableEncodings: [PortableEncoding] = [
        PortableEncoding(textEncoding: .utf8, names: ["utf-8", "utf8"], stringEncoding: .utf8),
        PortableEncoding(textEncoding: .utf16, names: ["utf-16", "utf16", "unicode"], stringEncoding: .utf16),
        PortableEncoding(textEncoding: .utf16be, names: ["utf-16be"], stringEncoding: .utf16BigEndian),
        PortableEncoding(textEncoding: .utf16le, names: ["utf-16le"], stringEncoding: .utf16LittleEndian),
        PortableEncoding(textEncoding: .utf32, names: ["utf-32", "utf32"], stringEncoding: .utf32),
        PortableEncoding(textEncoding: .utf32be, names: ["utf-32be"], stringEncoding: .utf32BigEndian),
        PortableEncoding(textEncoding: .utf32le, names: ["utf-32le"], stringEncoding: .utf32LittleEndian),
        PortableEncoding(textEncoding: FileTextEncoding("us-ascii"), names: ["us-ascii", "ascii"], stringEncoding: .ascii),
        PortableEncoding(textEncoding: FileTextEncoding("iso-8859-1"), names: ["iso-8859-1", "latin1"], stringEncoding: .isoLatin1),
        PortableEncoding(textEncoding: FileTextEncoding("macintosh"), names: ["macintosh", "x-mac-roman"], stringEncoding: .macOSRoman),
    ]
}
#endif

fileprivate extension String {
    /// Returns nil unless `bytes` is entirely valid UTF-8.
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        var iterator = bytes.makeIterator()
        var decoder = Unicode.UTF8()
        var scalars = String.UnicodeScalarView()
        decode: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break decode
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}

fileprivate extension String {
    init?<C: RandomAccessCollection>(_ bytes: C, encoding: FileTextEncoding) where C.Index : SignedInteger, C.Element == UInt8 {
        switch encoding {
        case .utf8:
            self.init(decodingBytes: bytes, as: Unicode.UTF8.self)
        case .utf16:
            guard let encoding = [FileTextEncoding]([.utf16be, .utf16le]).first(where: { bytes.starts(with: $0.byteOrderMark) }) else { return nil }
            self.init(bytes.dropFirst(encoding.byteOrderMark.count), encoding: encoding)
        case .utf16be:
            self.init(decodingBytes: bytes, as: Unicode.UTF16.self)
        case .utf16le:
            self.init(decodingBytes: bytes, as: Unicode.UTF16.self, byteSwap: true)
        case .utf32:
            guard let encoding = [FileTextEncoding]([.utf32be, .utf32le]).first(where: { bytes.starts(with: $0.byteOrderMark) }) else { return nil }
            self.init(bytes.dropFirst(encoding.byteOrderMark.count), encoding: encoding)
        case .utf32be:
            self.init(decodingBytes: bytes, as: Unicode.UTF32.self)
        case .utf32le:
            self.init(decodingBytes: bytes, as: Unicode.UTF32.self, byteSwap: true)
        default:
            return nil
        }
    }
}
