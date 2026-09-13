//
//  ContentPadding.swift
//  RelayCore
//

import Foundation
import RelayKit
import Security

public enum ContentPadding {
    private static let buckets = [256, 512, 1024, 4096]
    /// Messages larger than the largest fixed bucket are rounded up to the next
    /// multiple of this block, so no message — regardless of size — is ever sent
    /// at its exact plaintext length.
    private static let largeBlock = 4096

    /// Smallest bucket strictly greater than `size`. For sizes at or above the
    /// largest fixed bucket, rounds up to the next `largeBlock` boundary.
    static func targetSize(for size: Int) -> Int {
        if let bucket = buckets.first(where: { $0 > size }) { return bucket }
        return ((size / largeBlock) + 1) * largeBlock
    }

    public static func pad(_ serializedContent: Data) throws -> Data {
        var content = try Relay_Content_Content(serializedBytes: serializedContent)
        let baseSize = serializedContent.count
        let target = targetSize(for: baseSize)

        // Protobuf length prefixes add one or more bytes. Iterate until the final
        // serialized size lands at or under the target bucket.
        var paddingSize = max(0, target - baseSize - 2)
        while paddingSize > 0 {
            content.padding = try randomBytes(count: paddingSize)
            let padded = try content.serializedData()
            if padded.count <= target {
                return padded
            }
            paddingSize -= padded.count - target
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
