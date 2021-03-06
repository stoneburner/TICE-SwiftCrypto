import XCTest
import SwiftJWT
import CryptorECC
import DoubleRatchet
import X3DH
@testable import TICEModels
@testable import TICECrypto

final class CryptoTests: XCTestCase {

    let cryptoManager = CryptoManager(cryptoStore: TestCryptoStore(), encoder: JSONEncoder(), decoder: JSONDecoder())
    let groupId = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    let userId = UUID(uuidString: "F621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    lazy var user: TestUser = { TestUser(userId: userId) }()
    lazy var membership: Membership = { Membership(userId: self.userId, publicSigningKey: self.user.publicSigningKey, groupId: self.groupId, admin: true, serverSignedMembershipCertificate: "serverSignedCertificate") }()

    func testUserSignedMembershipCertificate() throws {
        let certificate = try cryptoManager.createUserSignedMembershipCertificate(userId: userId, groupId: groupId, admin: true, signerUserId: userId, signer: user)
        try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificate, membership: membership, issuer: user)
    }

    func testServerSignedMembershipCertificate() throws {
        let signingPrivateKey = try ECPrivateKey.make(for: .secp521r1)
        let signingPrivateKeyBytes = signingPrivateKey.pemString.bytes

        let signingPublicKey = try signingPrivateKey.extractPublicKey()
        let signingPublicKeyBytes = signingPublicKey.pemString.bytes

        let certificate = try cryptoManager.createServerSignedMembershipCertificate(userId: userId, groupId: groupId, admin: true, signingKey: Data(signingPrivateKeyBytes))

        try cryptoManager.validateServerSignedMembershipCertificate(certificate: certificate, membership: membership, publicKey: Data(signingPublicKeyBytes))
    }

    func testValidateMembershipCertificateInvalidMembership() throws {
        let fakeId = UUID(uuidString: "A621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

        let certificateInvalidGroupId = try cryptoManager.createUserSignedMembershipCertificate(userId: userId, groupId: fakeId, admin: true, signerUserId: userId, signer: user)
        let certificateInvalidUserId = try cryptoManager.createUserSignedMembershipCertificate(userId: fakeId, groupId: groupId, admin: true, signerUserId: fakeId, signer: user)
        let certificateInvalidAdminFlag = try cryptoManager.createUserSignedMembershipCertificate(userId: userId, groupId: groupId, admin: false, signerUserId: userId, signer: user)

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificateInvalidGroupId, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.invalidMembership = certificateValidationError else {
                XCTFail("Invalid error type (expected invalid membership): \(error.localizedDescription)")
                return
            }
        }

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificateInvalidUserId, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.invalidMembership = certificateValidationError else {
                    XCTFail("Invalid error type (expected invalid membership): \(error.localizedDescription)")
                    return
            }
        }

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificateInvalidAdminFlag, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.invalidMembership = certificateValidationError else {
                    XCTFail("Invalid error type (expected invalid membership): \(error.localizedDescription)")
                    return
            }
        }
    }

    func testValidateExpiredCertificate() throws {
        let claims = MembershipClaims(jti: JWTId(), iss: .user(userId), sub: userId, iat: Date().addingTimeInterval(-20), exp: Date().addingTimeInterval(-10), groupId: groupId, admin: true)
        var jwt = JWT(claims: claims)

        let privateKeyData = Data(user.privateSigningKey)
        let jwtSigner = JWTSigner.es512(privateKey: privateKeyData, signatureType: .asn1)
        let certificate = try jwt.sign(using: jwtSigner)

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificate, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.expired(let validateClaimsResult) = certificateValidationError,
                validateClaimsResult == .expired else {
                    XCTFail("Invalid error type (expected invalid claims): \(error.localizedDescription)")
                    return
            }
        }
    }

    func testValidateCertificateIssuedInFuture() throws {
        let claims = MembershipClaims(jti: JWTId(), iss: .user(userId), sub: userId, iat: Date().addingTimeInterval(60), exp: Date().addingTimeInterval(3600), groupId: groupId, admin: true)
        var jwt = JWT(claims: claims)

        let privateKeyData = Data(user.privateSigningKey)
        let jwtSigner = JWTSigner.es512(privateKey: privateKeyData, signatureType: .asn1)
        let certificate = try jwt.sign(using: jwtSigner)

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificate, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.expired(let validateClaimsResult) = certificateValidationError,
                validateClaimsResult == .issuedAt else {
                    XCTFail("Invalid error type (expected invalid claims): \(error.localizedDescription)")
                    return
            }
        }
    }

    func testValidateCertificateInvalidSignature() throws {
        let claims = MembershipClaims(jti: JWTId(), iss: .user(userId), sub: userId, iat: Date().addingTimeInterval(60), exp: Date().addingTimeInterval(3600), groupId: groupId, admin: true)
        var jwt = JWT(claims: claims)

        guard let privateKeyData = try ECPrivateKey.make(for: .secp521r1).pemString.data(using: .utf8) else {
            XCTFail("Could not create private key")
            return
        }

        let jwtSigner = JWTSigner.es512(privateKey: privateKeyData, signatureType: .asn1)
        let certificate = try jwt.sign(using: jwtSigner)

        do {
            try cryptoManager.validateUserSignedMembershipCertificate(certificate: certificate, membership: membership, issuer: user)
            XCTFail("Validation should not have succeeded.")
        } catch {
            guard case CryptoManagerError.certificateValidationFailed(let certificateValidationError) = error,
                case CertificateValidationError.invalidSignature = certificateValidationError else {
                XCTFail("Invalid error type (expected invalid signature): \(error.localizedDescription)")
                return
            }
        }
    }

    func testValidateCertificateDeprecatedIssuerFormat() throws {
        struct DeprecatedMembershipClaims: Claims {
            public let jti: JWTId
            public let iss: DeprecatedIssuer
            public let sub: UserId
            public let iat: Date?
            public let exp: Date?
            public let groupId: GroupId
            public let admin: Bool

            public enum DeprecatedIssuer: Codable {
                case server
                case user(UserId)

                public enum CodingKeys: String, CodingKey {
                    case server
                    case user
                }

                public init(from decoder: Decoder) throws {
                    XCTFail("Should not have been called")
                    throw NSError()
                }

                public func encode(to encoder: Encoder) throws {
                    var container = encoder.container(keyedBy: CodingKeys.self)
                    switch self {
                    case .server:
                        try container.encode("server", forKey: .server)
                    case .user(let userId):
                        try container.encode(userId, forKey: .user)
                    }
                }
            }
        }

        let signingPrivateKey = try ECPrivateKey.make(for: .secp521r1)
        let signingPrivateKeyBytes = signingPrivateKey.pemString.bytes

        let signingPublicKey = try signingPrivateKey.extractPublicKey()
        let signingPublicKeyBytes = signingPublicKey.pemString.bytes

        let privateKeyData = Data(signingPrivateKeyBytes)
        let jwtSigner = JWTSigner.es512(privateKey: privateKeyData, signatureType: .asn1)

        let serverClaims = DeprecatedMembershipClaims(jti: JWTId(), iss: DeprecatedMembershipClaims.DeprecatedIssuer.server, sub: userId, iat: Date().addingTimeInterval(-10), exp: Date().addingTimeInterval(10), groupId: groupId, admin: true)
        var serverJwt = JWT(claims: serverClaims)
        let serverCertificate = try serverJwt.sign(using: jwtSigner)

        try cryptoManager.validateServerSignedMembershipCertificate(certificate: serverCertificate, membership: membership, publicKey: Data(signingPublicKeyBytes))

        let userClaims = DeprecatedMembershipClaims(jti: JWTId(), iss: DeprecatedMembershipClaims.DeprecatedIssuer.user(userId), sub: userId, iat: Date().addingTimeInterval(-10), exp: Date().addingTimeInterval(10), groupId: groupId, admin: true)
        var userJwt = JWT(claims: userClaims)
        let userCertificate = try userJwt.sign(using: jwtSigner)

        let user = User(userId: userId, publicSigningKey: Data(signingPublicKeyBytes), publicName: nil)
        try cryptoManager.validateUserSignedMembershipCertificate(certificate: userCertificate, membership: membership, issuer: user)
    }

    func testInitializeConversation() throws {
        let publicKeyMaterial = try cryptoManager.generateHandshakeKeyMaterial(signer: user)

        // Publish public key material...

        let bob = TestUser(userId: UserId())
        let bobsCryptoManager = CryptoManager(cryptoStore: TestCryptoStore(), encoder: JSONEncoder(), decoder: JSONDecoder())
        _ = try bobsCryptoManager.generateHandshakeKeyMaterial(signer: bob)

        // Bob gets prekey bundle and remote verification key from server

        let conversationId = ConversationId()
        let invitation = try bobsCryptoManager.initConversation(with: userId, conversationId: conversationId, remoteIdentityKey: publicKeyMaterial.identityKey, remoteSignedPrekey: publicKeyMaterial.signedPrekey, remotePrekeySignature: publicKeyMaterial.prekeySignature, remoteOneTimePrekey: publicKeyMaterial.oneTimePrekeys.first!, remoteSigningKey: user.publicSigningKey)

        // Invitation is transmitted...

        try cryptoManager.processConversationInvitation(invitation, from: bob.userId, conversationId: conversationId)

        let firstMessagePayload = "Hello!".data(using: .utf8)!
        let firstMessage = try bobsCryptoManager.encrypt(firstMessagePayload, for: userId, conversationId: conversationId)

        let plaintextData = try cryptoManager.decrypt(encryptedMessage: firstMessage, from: bob.userId, conversationId: conversationId)

        XCTAssertEqual(firstMessagePayload, plaintextData, "Invalid decrypted plaintext")
    }

    func testMaxSkipExceeded() throws {
        let bob = TestUser(userId: UserId())
        let bobsCryptoManager = CryptoManager(cryptoStore: TestCryptoStore(), encoder: JSONEncoder(), decoder: JSONDecoder())
        _ = try bobsCryptoManager.generateHandshakeKeyMaterial(signer: bob)

        let handshakeInfo = try cryptoManager.generateHandshakeKeyMaterial(signer: user)
        let conversationId = ConversationId()
        let invitation = try bobsCryptoManager.initConversation(with: user.userId, conversationId: conversationId, remoteIdentityKey: handshakeInfo.identityKey, remoteSignedPrekey: handshakeInfo.signedPrekey, remotePrekeySignature: handshakeInfo.prekeySignature, remoteOneTimePrekey: handshakeInfo.oneTimePrekeys.last!, remoteSigningKey: user.publicSigningKey)

        try cryptoManager.processConversationInvitation(invitation, from: bob.userId, conversationId: conversationId)

        // Produce maxSkip messages that will get lost
        for _ in 0...100 {
            _ = try bobsCryptoManager.encrypt(Data(), for: userId, conversationId: conversationId)
        }

        // Produce another message that is going to be delivered successfully
        var encryptedMessage = try bobsCryptoManager.encrypt(Data(), for: userId, conversationId: conversationId)

        let exp1 = expectation(description: "maxSkipExceeded error raised")
        do {
            _ = try cryptoManager.decrypt(encryptedMessage: encryptedMessage, from: bob.userId, conversationId: conversationId)
        } catch CryptoManagerError.maxSkipExceeded {
            exp1.fulfill()
        }

        wait(for: [exp1], timeout: 1.0)

        //
        // BEGIN: Show that ratchet step isn't going to resolve the problem
        //
        let exp2 = expectation(description: "maxSkipExceeded error raised second time")
        encryptedMessage = try cryptoManager.encrypt(Data(), for: bob.userId, conversationId: conversationId)
        _ = try bobsCryptoManager.decrypt(encryptedMessage: encryptedMessage, from: user.userId, conversationId: conversationId)

        encryptedMessage = try bobsCryptoManager.encrypt(Data(), for: userId, conversationId: conversationId)
        do {
            _ = try cryptoManager.decrypt(encryptedMessage: encryptedMessage, from: bob.userId, conversationId: conversationId)
        } catch CryptoManagerError.maxSkipExceeded {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 1.0)
        //
        // END
        //

        // Recover by reinitializing conversation
        let newHandshakeInfo = try bobsCryptoManager.generateHandshakeKeyMaterial(signer: bob)
        let newInvitation = try cryptoManager.initConversation(with: bob.userId, conversationId: conversationId, remoteIdentityKey: newHandshakeInfo.identityKey, remoteSignedPrekey: newHandshakeInfo.signedPrekey, remotePrekeySignature: newHandshakeInfo.prekeySignature, remoteOneTimePrekey: newHandshakeInfo.oneTimePrekeys.last!, remoteSigningKey: bob.publicSigningKey)

        try bobsCryptoManager.processConversationInvitation(newInvitation, from: user.userId, conversationId: conversationId)
        encryptedMessage = try cryptoManager.encrypt(Data(), for: bob.userId, conversationId: conversationId)
        _ = try bobsCryptoManager.decrypt(encryptedMessage: encryptedMessage, from: user.userId, conversationId: conversationId)

        encryptedMessage = try bobsCryptoManager.encrypt(Data(), for: user.userId, conversationId: conversationId)
        _ = try cryptoManager.decrypt(encryptedMessage: encryptedMessage, from: bob.userId, conversationId: conversationId)
    }

    static var allTests = [
        ("testUserSignedMembershipCertificate", testUserSignedMembershipCertificate),
        ("testServerSignedMembershipCertificate", testServerSignedMembershipCertificate),
        ("testValidateMembershipCertificateInvalidMembership", testValidateMembershipCertificateInvalidMembership),
        ("testValidateExpiredCertificate", testValidateExpiredCertificate),
        ("testValidateCertificateIssuedInFuture", testValidateCertificateIssuedInFuture),
        ("testValidateCertificateInvalidSignature", testValidateCertificateInvalidSignature),
        ("testInitializeConversation", testInitializeConversation),
        ("testMaxSkipExceeded", testMaxSkipExceeded),
    ]
}

class TestUser: User, Signer {
    let privateSigningKey: PrivateKey

    init(userId: UserId) {
        let signingKey = try! ECPrivateKey.make(for: .secp521r1)
        self.privateSigningKey = Data(signingKey.pemString.bytes)

        let publicSigningKey = try! signingKey.extractPublicKey().pemString.bytes
        super.init(userId: userId, publicSigningKey: Data(publicSigningKey), publicName: nil)
    }

    required init(from decoder: Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }
}

enum TestCryptoStoreError: Error {
    case noKeys
}

class TestCryptoStore: CryptoStore {
    var identityKeyPair: TICEModels.KeyPair?
    var prekeyPair: TICEModels.KeyPair?
    var prekeySignature: Signature?
    var oneTimePrekeyPairs: [TICEModels.PublicKey: TICEModels.KeyPair] = [:]

    func saveIdentityKeyPair(_ keyPair: TICEModels.KeyPair) throws {
        identityKeyPair = keyPair
    }

    func savePrekeyPair(_ keyPair: TICEModels.KeyPair, signature: Signature) throws {
        prekeyPair = keyPair
        prekeySignature = signature
    }

    func saveOneTimePrekeyPairs(_ keyPairs: [TICEModels.KeyPair]) throws {
        for keyPair in keyPairs {
            oneTimePrekeyPairs[keyPair.publicKey] = keyPair
        }
    }

    func loadIdentityKeyPair() throws -> TICEModels.KeyPair {
        guard let identityKeyPair = identityKeyPair else {
            throw TestCryptoStoreError.noKeys
        }
        return identityKeyPair
    }

    func loadPrekeyPair() throws -> TICEModels.KeyPair {
        guard let prekeyPair = prekeyPair else {
            throw TestCryptoStoreError.noKeys
        }
        return prekeyPair
    }

    func loadPrekeySignature() throws -> Signature {
        guard let signature = prekeySignature else {
            throw TestCryptoStoreError.noKeys
        }
        return signature
    }

    func loadPrivateOneTimePrekey(publicKey: TICEModels.PublicKey) throws -> PrivateKey {
        guard let keyPair = oneTimePrekeyPairs[publicKey] else {
            throw TestCryptoStoreError.noKeys
        }
        return keyPair.privateKey
    }

    func deleteOneTimePrekeyPair(publicKey: TICEModels.PublicKey) throws {
        oneTimePrekeyPairs.removeValue(forKey: publicKey)
    }

    func save(_ conversationState: ConversationState) throws {
    }

    func loadConversationState(userId: UserId, conversationId: ConversationId) throws -> ConversationState? {
        nil
    }

    func loadConversationStates() throws -> [ConversationState] {
        []
    }
}
