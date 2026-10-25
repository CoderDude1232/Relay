//
//  PhoneNumbers.swift
//  Relay
//
//  Turns phone numbers as people type or store them ("0412 345 678",
//  "+61 412 345 678", "0061…") into E.164 ("+61412345678"), the form the
//  relay texts and discovery hashes. Not a full numbering-plan library: it
//  handles international numbers and national numbers for the countries
//  below, which covers address-book entries in practice.
//

import Foundation

enum PhoneNumbers {
    struct Country: Identifiable, Hashable {
        let region: String   // ISO 3166 code
        let name: String
        let callingCode: String
        /// Dialled before national numbers ("0" in most countries, none in
        /// North America).
        let trunkPrefix: String
        var id: String { region }
        var flag: String {
            region.unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }
                .map(String.init).joined()
        }
    }

    static let countries: [Country] = [
        Country(region: "AU", name: "Australia", callingCode: "61", trunkPrefix: "0"),
        Country(region: "NZ", name: "New Zealand", callingCode: "64", trunkPrefix: "0"),
        Country(region: "US", name: "United States", callingCode: "1", trunkPrefix: ""),
        Country(region: "CA", name: "Canada", callingCode: "1", trunkPrefix: ""),
        Country(region: "GB", name: "United Kingdom", callingCode: "44", trunkPrefix: "0"),
        Country(region: "IE", name: "Ireland", callingCode: "353", trunkPrefix: "0"),
        Country(region: "DE", name: "Germany", callingCode: "49", trunkPrefix: "0"),
        Country(region: "FR", name: "France", callingCode: "33", trunkPrefix: "0"),
        Country(region: "NL", name: "Netherlands", callingCode: "31", trunkPrefix: "0"),
        Country(region: "ES", name: "Spain", callingCode: "34", trunkPrefix: ""),
        Country(region: "IT", name: "Italy", callingCode: "39", trunkPrefix: ""),
        Country(region: "SE", name: "Sweden", callingCode: "46", trunkPrefix: "0"),
        Country(region: "SG", name: "Singapore", callingCode: "65", trunkPrefix: ""),
        Country(region: "IN", name: "India", callingCode: "91", trunkPrefix: "0"),
        Country(region: "JP", name: "Japan", callingCode: "81", trunkPrefix: "0"),
        Country(region: "ZA", name: "South Africa", callingCode: "27", trunkPrefix: "0"),
    ]

    /// The device's country, or Australia.
    static var defaultCountry: Country {
        let region = Locale.current.region?.identifier ?? "AU"
        return countries.first { $0.region == region } ?? countries[0]
    }

    /// E.164 for `raw`, read as a number from `country` unless it's already
    /// international. Nil when it can't be a phone number.
    static func e164(_ raw: String, country: Country = defaultCountry) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        let result: String
        if trimmed.hasPrefix("+") {
            result = "+" + digits
        } else if digits.hasPrefix("00") {
            result = "+" + digits.dropFirst(2)
        } else if country.callingCode == "1", digits.count == 11, digits.hasPrefix("1") {
            result = "+" + digits
        } else {
            var national = Substring(digits)
            if !country.trunkPrefix.isEmpty, national.hasPrefix(country.trunkPrefix) {
                national = national.dropFirst(country.trunkPrefix.count)
            }
            result = "+" + country.callingCode + national
        }
        // E.164: a country code that doesn't start with 0, 8 to 15 digits in all.
        let count = result.count - 1
        guard count >= 8, count <= 15, result.dropFirst().first != "0" else { return nil }
        return result
    }

    /// "+61 412 345 678"-style spacing for showing a number back to its owner.
    static func display(_ e164: String) -> String {
        guard e164.hasPrefix("+"),
              let country = countries.first(where: { e164.dropFirst().hasPrefix($0.callingCode) })
        else { return e164 }
        let national = String(e164.dropFirst(1 + country.callingCode.count))
        var groups: [String] = []
        var rest = Substring(national)
        // Threes, with the last four kept together ("415 555 0100").
        while rest.count > 4 {
            groups.append(String(rest.prefix(3)))
            rest = rest.dropFirst(3)
        }
        if !rest.isEmpty { groups.append(String(rest)) }
        return "+\(country.callingCode) " + groups.joined(separator: " ")
    }
}
