import Foundation

public enum LogRedactor {
    private static let fallbackRegex = try! NSRegularExpression(pattern: "$^")
    private static let emailRegex = Self.makeRegex(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                                                   options: [.caseInsensitive])
    private static let cookieHeaderRegex = Self.makeRegex(#"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authorizationRegex = Self.makeRegex(#"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let bearerRegex = Self.makeRegex(#"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)
    private static let openAIKeyRegex = Self.makeRegex(#"(?i)sk-[a-z0-9_\-]{16,}"#)
    private static let tokenFieldRegex = Self.makeRegex(
        #"(?i)("(?:access_token|refresh_token|id_token|accessToken|refreshToken|idToken)"\s*:\s*")[^"]+(")"#)
    private static let sensitiveQueryRegex = Self.makeRegex(
        #"(?i)([?&](?:code|device_code|user_code|access_token|refresh_token|id_token|state)=)[^&\s]+"#)

    public static func redact(_ text: String) -> String {
        var output = text
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        output = self.replace(self.openAIKeyRegex, in: output, with: "<redacted-openai-key>")
        output = self.replace(self.tokenFieldRegex, in: output, with: "$1<redacted>$2")
        output = self.replace(self.sensitiveQueryRegex, in: output, with: "$1<redacted>")
        return output
    }

    public static func excerpt(_ text: String, maxLength: Int = 2_000) -> String {
        let singleLine = self.redact(text).replacingOccurrences(of: "\n", with: "\\n")
        guard singleLine.count > maxLength else { return singleLine }
        let end = singleLine.index(singleLine.startIndex, offsetBy: maxLength)
        return "\(singleLine[..<end])...<truncated>"
    }

    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = [])
        -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
