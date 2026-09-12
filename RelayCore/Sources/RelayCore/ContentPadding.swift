//
//  ContentPadding.swift
//  RelayCore
//

import Foundation
import RelayKit
import Security

public enum ContentPadding {
    private static let buckets = [256, 512, 1024, 4096]
    private static let maxPaddingBytes = 4096

    public static func pad(_ serializedContent: Data) throws -> Data {
        var content = try Relay_Content_Content(serializedBytes: serializedContent)
        let baseSize = serializedContent.count
        guard let bucket = buckets.first(where: { $0 > baseSize }) else {
            return serializedContent
        }

        // Protobuf length prefixes add one or more bytes. Iterate once or twice
        // so the final serialized size lands at or under the target bucket.
        var paddingSize = max(0, min(maxPaddingBytes, bucket - baseSize - 2))
        while paddingSize > 0 {
            content.padding = try randomBytes(count: paddingSize)
            let padded = try content.serializedData()
            if padded.count <= bucket {
                return padded
            }
            paddingSize -= padded.count - bucket
        }
        return serializedContent
    }

	private static func randomBytes(count: Int) throws -> Data {
		guard count > 0 else { return Data() }
		var data = Data(count: count)
		let status = data.withUnsafeMutableBytes { bytes in
			guard let baseAddress = bytes.baseAddress else {
				return errSecParam
			}
			return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
		}
		guard status == errSecSuccess else {
			throw ContentPaddingError.randomFailed(status)
        }
        return data
    }
}

public enum ContentPaddingError: Error {
    case randomFailed(OSStatus)
}
