//
//  LogRedactor.swift
//  Scrubs the pairing token out of even-terminal's console output before the
//  app keeps or shows it. even-terminal prints "Full token: <token>", a pairing
//  URL with ?token=<token>, and a terminal QR code that encodes that URL.
//

import Foundation

enum LogRedactor {
    static let mask = "[REDACTED]"

    /// The token from even-terminal's config, used only for exact-match redaction.
    static func tokenFromConfig(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["token"] as? String, !t.isEmpty else { return nil }
        return t
    }

    private static let patterns: [NSRegularExpression] = [
        // "token: abc", "Full token: abc", "\"token\":\"abc\""
        #"(?i)(token["']?\s*[:=]\s*["']?)[^\s"'&,]+"#,
        // ?token=abc / &token=abc in URLs
        #"(?i)([?&]token=)[^\s&#"']+"#,
        // Bearer headers
        #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
        // Any long hex or base64/base64url run, wherever it appears
        #"()\b[A-Fa-f0-9]{24,}\b"#,
        #"()[A-Za-z0-9+_-]{32,}={0,2}"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func redact(_ text: String, knownToken: String?) -> String {
        var out = text
        if let t = knownToken, t.count >= 4 {
            out = out.replacingOccurrences(of: t, with: mask)
        }
        for re in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "$1" + mask)
        }
        // Drop QR-code art (block characters) entirely: it encodes the token.
        let qrChars = CharacterSet(charactersIn: "█▀▄▌▐░▒▓■")
        out = out.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in line.unicodeScalars.filter { qrChars.contains($0) }.count < 4 }
            .joined(separator: "\n")
        return out
    }
}
