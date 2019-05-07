//
//  Copyright © 2019 Anbion. All rights reserved.
//

import Foundation
import LetsMeetModels
import SwiftJWT

public struct MembershipClaims: Claims {
    public let iss: Issuer
    public let sub: UserId
    public let iat: Date?
    public let exp: Date?
    public let groupId: GroupId
    public let admin: Bool

    public enum Issuer: Codable {
        case server
        case user(UserId)

        public enum CodingKeys: String, CodingKey {
            case server
            case user
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let userId = try container.decodeIfPresent(UUID.self, forKey: .user) {
                self = .user(userId)
            } else {
                let server = try container.decode(String.self, forKey: .server)
                guard server == "server" else {
                    throw CertificateValidationError.invalidClaims
                }

                self = .server
            }
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