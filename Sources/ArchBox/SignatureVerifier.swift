import CryptoKit
import Foundation
import Security

/// Verifies the detached OpenPGP signature (`.sig`) of the Arch Linux ARM rootfs
/// against the pinned "Arch Linux ARM Build System" key, without gpg.
///
/// Supports exactly what that key produces: a version 4 signature over binary data,
/// RSA, with SHA-256 or SHA-512. Anything else is rejected.
enum SignatureVerifier {
    /// Arch Linux ARM Build System <builder@archlinuxarm.org>
    /// Fingerprint 68B3537F39A313B3E574D06777193F152BDBE6A6 (RSA 4096).
    /// Checked on 2026-10-07: the copy on keyserver.ubuntu.com and the one in the
    /// tarball's archlinuxarm-keyring were identical, and gpg verified the
    /// 2026-08-05 tarball with it.
    static let issuerFingerprint = Data(hex: "68B3537F39A313B3E574D06777193F152BDBE6A6")
    /// Signatures made before the tarball verified on 2026-08-05 are rejected, so a
    /// mirror cannot hand out an older, validly signed rootfs (or another file the
    /// same key signed long ago).
    static let oldestAcceptedSignature = Date(timeIntervalSince1970: 1785888000)
    private static let publicKeyPKCS1 = """
        MIICCgKCAgEAzQdlwoSUKZUMGwHJfMJIbD2TqMxocVGDvgVRBebyo8XDc3kee3I49b3ksOGjJhL9NzJAR4vSsspNsClJBR7k\
        8eAwOWcZ07ftknBHsxBXJhKC7EWInXkN+bWFmhY6Y2Qy20eG6dBLpgovM78cEIV5dcuJkWbQQl/M+KLXYF5PHQVEiSbB4CbJ\
        kaG8zawQxhK+eZzW0/PAcVXBt/YnRG/1TjqktuK6IDSb5EFHUcJrvARm0liPyGiwdFnN3DBDGAn+U4xMEvR7Er1DpnVhOkVo\
        m6Z2kKffwgtjx4z9UJ128t29bQOJzZtyJD/B6sKXiK0i94V0hijJ96/A/0opdZH1NVOZ5ZdMpNYRaAH1SuAFhL3Fx6stwcA2\
        GtYsooqhsZjUcoiuvBGZXNtLhoxvxrDScfv7QKlkzlvLCSa6fmBk/9O7h9okT4r41gHrYIoesZZm25LJCpuIUCPrKM1hTm0M\
        z3vUdZTS353Bl8cTlpJLxpW3WVV2Jz0in+nRfh/pWS40r4Uc505c/ozPzrv/W5s39JLybenziOGkfGXrHlxCX8aQNAXW8Wq4\
        z1Kz4/V1S7u+WxVzM3kSBFt8y3fTohwJ8Xy5Zv1g8HNM2IySMlNFfylYWMeyqpjZQ+c6YOICIfp+dzqUmT7CwlscGv+cvMPB\
        yzhKWUQfzeqHJsyEkoqllJcCAwEAAQ==
        """

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ reason: String) { errorDescription = "İmza doğrulanamadı: \(reason)" }
    }

    /// Throws unless `signature` is a valid signature of the file at `file` by the pinned key.
    static func verify(file: URL, signature: Data) throws {
        let packet = try parseSignaturePacket(signature)

        // Signed data = file contents || hashed part of the packet || trailer.
        let digest: Data
        let algorithm: SecKeyAlgorithm
        switch packet.hashAlgorithm {
        case 8:
            digest = try hashFile(file, with: SHA256(), extra: packet.trailer)
            algorithm = .rsaSignatureDigestPKCS1v15SHA256
        case 10:
            digest = try hashFile(file, with: SHA512(), extra: packet.trailer)
            algorithm = .rsaSignatureDigestPKCS1v15SHA512
        default:
            throw Failure("desteklenmeyen özet algoritması \(packet.hashAlgorithm)")
        }
        guard digest.prefix(2) == packet.hashPrefix else {
            throw Failure("dosya imzayla eşleşmiyor")
        }

        guard let keyData = Data(base64Encoded: publicKeyPKCS1),
              let key = SecKeyCreateWithData(keyData as CFData, [
                  kSecAttrKeyType: kSecAttrKeyTypeRSA,
                  kSecAttrKeyClass: kSecAttrKeyClassPublic,
              ] as CFDictionary, nil) else {
            throw Failure("gömülü anahtar okunamadı")
        }
        // The MPI drops leading zero bytes; RSA verification wants the full modulus length.
        let modulusLength = SecKeyGetBlockSize(key)
        guard packet.signature.count <= modulusLength else { throw Failure("imza boyutu hatalı") }
        let paddedSignature = Data(repeating: 0, count: modulusLength - packet.signature.count) + packet.signature

        var error: Unmanaged<CFError>?
        guard SecKeyVerifySignature(key, algorithm, digest as CFData, paddedSignature as CFData, &error) else {
            throw Failure("imza geçersiz")
        }
    }

    // MARK: - Parsing

    private struct SignaturePacket {
        var hashAlgorithm: UInt8
        var hashPrefix: Data
        var trailer: Data
        var signature: Data
    }

    private static func parseSignaturePacket(_ data: Data) throws -> SignaturePacket {
        var reader = Reader(data)
        let header = try reader.byte()
        guard header & 0x80 != 0 else { throw Failure("OpenPGP paketi değil") }

        let tag: UInt8
        let length: Int
        if header & 0x40 != 0 {
            tag = header & 0x3f
            let first = Int(try reader.byte())
            switch first {
            case 0..<192: length = first
            case 192..<224: length = ((first - 192) << 8) + Int(try reader.byte()) + 192
            case 255: length = Int(try reader.uint(4))
            default: throw Failure("parçalı paket uzunluğu desteklenmiyor")
            }
        } else {
            tag = (header >> 2) & 0x0f
            switch header & 0x03 {
            case 0: length = Int(try reader.uint(1))
            case 1: length = Int(try reader.uint(2))
            case 2: length = Int(try reader.uint(4))
            default: throw Failure("belirsiz paket uzunluğu desteklenmiyor")
            }
        }
        guard tag == 2 else { throw Failure("imza paketi değil") }
        var body = Reader(try reader.bytes(length))

        let hashedStart = body.offset
        guard try body.byte() == 4 else { throw Failure("yalnız sürüm 4 imzalar destekleniyor") }
        guard try body.byte() == 0x00 else { throw Failure("ikili belge imzası değil") }
        guard try body.byte() == 1 else { throw Failure("RSA imzası değil") }
        let hashAlgorithm = try body.byte()
        let hashedLength = Int(try body.uint(2))
        let hashedSubpackets = try body.bytes(hashedLength)
        let hashedPart = body.data[hashedStart..<body.offset]

        let subpackets = try parseSubpackets(hashedSubpackets)
        // The issuer fingerprint must be the pinned key's, if the signature names one.
        if let issuer = subpackets[33], !(issuer.count == 21 && issuer.suffix(20) == issuerFingerprint) {
            throw Failure("imzalayan anahtar beklenen anahtar değil")
        }
        guard let created = subpackets[2], created.count == 4 else { throw Failure("imza tarihi yok") }
        let createdAt = Date(timeIntervalSince1970: TimeInterval(created.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
        guard createdAt >= oldestAcceptedSignature else { throw Failure("imza çok eski") }

        let unhashedLength = Int(try body.uint(2))
        _ = try body.bytes(unhashedLength)
        let hashPrefix = try body.bytes(2)
        let bits = Int(try body.uint(2))
        let signature = try body.bytes((bits + 7) / 8)

        var trailer = Data(hashedPart)
        trailer.append(contentsOf: [0x04, 0xff])
        trailer.append(contentsOf: withUnsafeBytes(of: UInt32(hashedPart.count).bigEndian, Array.init))
        return SignaturePacket(hashAlgorithm: hashAlgorithm, hashPrefix: hashPrefix,
                               trailer: trailer, signature: signature)
    }

    /// Hashed subpackets by type (2 = creation time, 33 = issuer version + fingerprint).
    private static func parseSubpackets(_ data: Data) throws -> [UInt8: Data] {
        var reader = Reader(data)
        var result: [UInt8: Data] = [:]
        while !reader.isAtEnd {
            let first = Int(try reader.byte())
            let length: Int
            switch first {
            case 0..<192: length = first
            case 192..<255: length = ((first - 192) << 8) + Int(try reader.byte()) + 192
            default: length = Int(try reader.uint(4))
            }
            guard length >= 1 else { throw Failure("bozuk alt paket") }
            let content = try reader.bytes(length)
            result[content[content.startIndex] & 0x7f] = content.dropFirst()
        }
        return result
    }

    private static func hashFile<H: HashFunction>(_ url: URL, with hasher: H, extra: Data) throws -> Data {
        var hasher = hasher
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        hasher.update(data: extra)
        return Data(hasher.finalize())
    }

    private struct Reader {
        let data: Data
        private(set) var offset: Data.Index

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw Failure("paket beklenenden kısa") }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }

        mutating func byte() throws -> UInt8 { try bytes(1)[0] }

        mutating func uint(_ size: Int) throws -> UInt32 {
            try bytes(size).reduce(0) { $0 << 8 | UInt32($1) }
        }
    }
}

private extension Data {
    init(hex: String) {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = data
    }
}
