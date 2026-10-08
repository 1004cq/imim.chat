import CryptoKit
import Foundation

@main struct EncryptedMediaRegression {
    static func main() throws {
        for kind in ["voice", "image", "video", "file"] {
            let original = Data((0..<4096).map { UInt8($0 % 251) })
            let key = SymmetricKey(size: .bits256)
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(original, using: key, nonce: nonce)
            let metadata = EncryptedMediaMetadata(version: 1, originalType: kind,
                fileName: "fixture.\(kind == "voice" ? "m4a" : kind == "video" ? "mp4" : "png")",
                mimeType: "application/test", byteSize: original.count,
                mediaKey: key.withUnsafeBytes { Data($0).base64EncodedString() },
                mediaIV: nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                mediaTag: sealed.tag.base64EncodedString(), duration: 2, waveform: [0.2, 0.6])
            let decoded = try JSONDecoder().decode(EncryptedMediaMetadata.self, from: JSONEncoder().encode(metadata))
            let ciphertext = sealed.ciphertext + sealed.tag
            let plaintext = try decoded.decrypt(ciphertext)
            precondition(plaintext == original)
            var corrupt = ciphertext; corrupt[corrupt.startIndex] ^= 1
            do { _ = try decoded.decrypt(corrupt); fatalError("tampering accepted") } catch {}
            do { _ = try decoded.decrypt(Data(ciphertext.dropLast())); fatalError("truncation accepted") } catch {}
        }
        let origin = URL(string: "https://app.imim.chat")!
        let resolved = try EncryptedMediaStore.sourceURL("/api/media/fixture", origin: origin)
        precondition(resolved.absoluteString == "https://app.imim.chat/api/media/fixture")
        for url in ["http://app.imim.chat/api/media/x", "https://evil.test/api/media/x", "file:///tmp/x", "https://u:p@app.imim.chat/api/media/x", "https://app.imim.chat/api/avatar/x"] {
            do { _ = try EncryptedMediaStore.sourceURL(url, origin: origin); fatalError("unsafe URL accepted") } catch {}
        }
        print("Encrypted media regression passed: four attachment types, authenticated decryption, tamper/truncation rejection, safe URLs")
    }
}
