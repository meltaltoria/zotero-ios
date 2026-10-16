//
//  PDFTranslationService.swift
//  Zotero
//
//  PDF translation services for the iOS reader.
//  The Google token implementation is adapted from windingwind/zotero-pdf-translate (AGPLv3).
//

import Foundation
import Security

enum PDFTranslationSettingsStore {
    private static let service = "org.zotero.ios.Zotero.pdf-translation"
    private static let account = "api-key"


    static var provider: String {
        get {
            UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.provider") ?? "google"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ZoteroPDFTranslate.provider")
        }
    }

    static var endpoint: String {
        get {
            UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.endpoint")
                ?? "https://api.openai.com/v1"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ZoteroPDFTranslate.endpoint")
        }
    }

    static var model: String {
        get {
            UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.model")
                ?? "gpt-4o-mini"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ZoteroPDFTranslate.model")
        }
    }

    static var targetLanguage: String {
        get {
            UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.targetLanguage")
                ?? "Chinese"
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ZoteroPDFTranslate.targetLanguage")
        }
    }

    static var prompt: String {
        get {
            UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.prompt")
                ?? """
                You are an academic translator. Translate the supplied scientific paper excerpt into {{targetLanguage}}.
                Preserve equations, symbols, chemical formulas, material names, abbreviations, citations, and technical terminology.
                For battery and materials-science terminology, prefer established Chinese academic terminology.
                Do not add explanations or omit information. Return only the translation.
                """
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ZoteroPDFTranslate.prompt")
        }
    }

    static var apiKey: String {
        if let value = readKeychain(), !value.isEmpty {
            return value
        }

        // One-time migration from the first MVP, which stored the key in UserDefaults.
        if let legacy = UserDefaults.standard.string(forKey: "ZoteroPDFTranslate.apiKey"),
           !legacy.isEmpty {
            try? setAPIKey(legacy)
            UserDefaults.standard.removeObject(forKey: "ZoteroPDFTranslate.apiKey")
            return legacy
        }

        return ""
    }

    static func setAPIKey(_ value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let lookup: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw NSError(
                    domain: "ZoteroPDFTranslate.Keychain",
                    code: Int(updateStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Unable to update the translation API key."]
                )
            }
        } else if status != errSecSuccess {
            throw NSError(
                domain: "ZoteroPDFTranslate.Keychain",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to store the translation API key securely."]
            )
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "ZoteroPDFTranslate.apiKey")
    }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum PDFTranslationService {
    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }

    static func translate(
        text: String,
        provider: String,
        endpoint: String,
        model: String,
        targetLanguage: String,
        apiKey: String
    ) async throws -> String {
        if provider == "google" {
            return try await translateWithGoogle(text: text, targetLanguage: targetLanguage)
        }
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let urlString = base.hasSuffix("/chat/completions") ? base : "\(base)/chat/completions"
        guard let url = URL(string: urlString) else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid translation endpoint."]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let systemPrompt = PDFTranslationSettingsStore.prompt.replacingOccurrences(
            of: "{{targetLanguage}}",
            with: targetLanguage
        )

        let body = Request(
            model: model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text)
            ],
            temperature: 0
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The translation service returned an invalid response."]
            )
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Translation API error: \(serverMessage)"]
            )
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The translation service returned no text."]
            )
        }
        return content
    }

    // Google Translate web endpoint implementation adapted from windingwind/zotero-pdf-translate (AGPLv3).
    static func googleToken(_ input: String) -> String {
        func rotate(_ a: UInt32, _ pattern: String) -> UInt32 {
            let chars = Array(pattern)
            var value = a
            var index = 0

            while index + 2 < chars.count {
                let c0 = chars[index]
                let c1 = chars[index + 1]
                let c2 = chars[index + 2]

                let shift: UInt32
                if c2 >= Character("a") {
                    shift = UInt32(c2.asciiValue ?? 0) - 87
                } else {
                    shift = UInt32(String(c2)) ?? 0
                }

                let shifted = c1 == "+" ? value >> shift : value << shift
                value = c0 == "+" ? value &+ shifted : value ^ shifted
                index += 3
            }

            return value
        }

                var bytes: [UInt32] = []
                bytes.reserveCapacity(input.utf8.count)
    
                for scalar in input.unicodeScalars {
                    let value = scalar.value
                    if value < 128 {
                        bytes.append(value)
                    } else if value < 2048 {
                        bytes.append((value >> 6) | 192)
                        bytes.append((value & 63) | 128)
                    } else if value < 65536 {
                        bytes.append((value >> 12) | 224)
                        bytes.append(((value >> 6) & 63) | 128)
                        bytes.append((value & 63) | 128)
                    } else {
                        bytes.append((value >> 18) | 240)
                        bytes.append(((value >> 12) & 63) | 128)
                        bytes.append(((value >> 6) & 63) | 128)
                        bytes.append((value & 63) | 128)
                    }
                }
    
                var value: UInt32 = 406644
                for byte in bytes {
                    value = value &+ byte
                    value = rotate(value, "+-a^+6")
                }
                value = rotate(value, "+-3^+b+-f")
                value ^= 3293161072
    
                let first = value % 1_000_000
                return "\(first).\(first ^ 406644)"
            }

    private static func translateWithGoogle(text: String, targetLanguage: String) async throws -> String {

        func googleLanguageCode(_ language: String) -> String {
            switch language.lowercased() {
            case "chinese", "zh", "zh-cn", "zh-hans":
                return "zh-CN"
            case "traditional chinese", "zh-tw", "zh-hant":
                return "zh-TW"
            case "english", "en":
                return "en"
            case "japanese", "ja":
                return "ja"
            case "korean", "ko":
                return "ko"
            case "german", "de":
                return "de"
            case "french", "fr":
                return "fr"
            case "spanish", "es":
                return "es"
            default:
                return language
            }
        }

        var components = URLComponents(string: "https://translate.google.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: googleLanguageCode(targetLanguage)),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "tk", value: googleToken(text)),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components?.url else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Unable to build Google Translate URL."]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Google Translate request failed."]
            )
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let outer = object as? [Any],
              let segments = outer.first as? [Any] else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Google Translate returned an unexpected response."]
            )
        }

        let result = segments.compactMap { segment -> String? in
            guard let pair = segment as? [Any],
                  let translated = pair.first as? String else { return nil }
            return translated
        }.joined()

        guard !result.isEmpty else {
            throw NSError(
                domain: "ZoteroPDFTranslate",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Google Translate returned no translation."]
            )
        }
        return result
    }

}
