import XCTest
import Foundation
import FolioRDMPrimitives
@testable import FolioCore

final class RDMCryptoTests: XCTestCase, @unchecked Sendable {
    private func hex(_ value: String) -> Data {
        var result = Data(), position = value.startIndex
        while position < value.endIndex { let end = value.index(position, offsetBy: 2); result.append(UInt8(value[position..<end], radix: 16)!); position = end }
        return result
    }
    func testAES256GCMKnownAnswerEmptyMessage() throws {
        let key = try RDMSecret(copying: Data(repeating: 0, count: 32)); defer { key.lock() }
        let result = try RDMCrypto.seal(Data(), key: key, aad: Data(), nonce: Data(repeating: 0, count: 12))
        XCTAssertTrue(result.ciphertext.isEmpty)
        XCTAssertEqual(result.tag, hex("530f8afbc74536b9a963b4f1c4cb738b"))
        XCTAssertEqual(try RDMCrypto.open(result, key: key, aad: Data()), Data())
    }
    func testAES256GCMKnownAnswerOneBlock() throws {
        let key = try RDMSecret(copying: Data(repeating: 0, count: 32)); defer { key.lock() }
        let plain = Data(repeating: 0, count: 16)
        let box = try RDMCrypto.seal(plain, key: key, aad: Data(), nonce: Data(repeating: 0, count: 12))
        XCTAssertEqual(box.ciphertext, hex("cea7403d4d606b6e074ec5d3baf39d18"))
        XCTAssertEqual(box.tag, hex("d0d1c8a799996bf0265b98b5d48ab919"))
        XCTAssertEqual(try RDMCrypto.open(box, key: key, aad: Data()), plain)
    }
    func testHKDFRFC5869Vector() throws {
        let input = try RDMSecret(copying: Data(repeating: 0x0b, count: 22)); defer { input.lock() }
        let output = try RDMCrypto.derive(input, salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"), count: 42)
        defer { output.lock() }
        XCTAssertEqual(try output.withBytes { Data($0) }, hex("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))
    }
    func testArgon2idRFC9106KnownAnswer() { XCTAssertEqual(folio_argon2id_rfc9106_selftest(), 1) }
    func testPortableArgonProfileMatchesIndependentWrapperFixture() async throws {
        let key = try await RDMPasswordKDF.shared.derive("correct horse battery staple", salt: Data(0..<16))
        defer { key.lock() }
        XCTAssertEqual(try key.withBytes { Data($0) }, hex("853b272a44db1421c02962669a55eb0994f3cab385ed1c4c79253eee19bab49e"))
    }
    func testAuthenticatedDataTagCiphertextAndWrongKeyFailClosed() throws {
        let key = try RDMSecret.random(), other = try RDMSecret.random(); defer { key.lock(); other.lock() }
        let aad = Data("project and object metadata".utf8)
        let box = try RDMCrypto.seal(Data("secret text".utf8), key: key, aad: aad)
        XCTAssertThrowsError(try RDMCrypto.open(box, key: key, aad: Data("wrong project".utf8)))
        XCTAssertThrowsError(try RDMCrypto.open(box, key: other, aad: aad))
        var corrupt = box.ciphertext
        corrupt.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in bytes[0] ^= 1 }
        XCTAssertThrowsError(try RDMCrypto.open(.init(nonce: box.nonce, ciphertext: corrupt, tag: box.tag), key: key, aad: aad))
        var tag = box.tag
        tag.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in bytes[0] ^= 1 }
        XCTAssertThrowsError(try RDMCrypto.open(.init(nonce: box.nonce, ciphertext: box.ciphertext, tag: tag), key: key, aad: aad))
    }
    func testErasedHandleCannotBeReusedAndLockIsIdempotent() throws {
        let key = try RDMSecret.random(); key.lock(); key.lock()
        XCTAssertTrue(key.isLocked)
        XCTAssertThrowsError(try RDMCrypto.seal(Data("text".utf8), key: key, aad: Data())) { XCTAssertEqual($0 as? RDMError, .locked) }
    }
    func testRandomNoncesAndRevisionMaterialAreNotDeterministic() throws {
        var values = Set<Data>()
        for _ in 0..<100 { values.insert(try RDMCrypto.random(32)) }
        XCTAssertEqual(values.count, 100)
    }
    func testDomainSeparatedKeysDiffer() throws {
        let key = try RDMSecret.random(); defer { key.lock() }
        let first = try RDMCrypto.derive(key, salt: Data([1]), info: Data("manifest".utf8))
        let second = try RDMCrypto.derive(key, salt: Data([1]), info: Data("note".utf8))
        defer { first.lock(); second.lock() }
        XCTAssertNotEqual(try first.withBytes { Data($0) }, try second.withBytes { Data($0) })
    }
    func testInvalidPrimitiveSizesAreRejected() throws {
        let key = try RDMSecret.random(); defer { key.lock() }
        XCTAssertThrowsError(try RDMCrypto.seal(Data(), key: key, aad: Data(), nonce: Data(count: 8)))
        XCTAssertThrowsError(try RDMCrypto.derive(key, salt: Data(), info: Data(), count: 100))
    }
}
