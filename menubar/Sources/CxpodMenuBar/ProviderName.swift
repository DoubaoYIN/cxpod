import Foundation

func isValidProviderName(_ name: String) -> Bool {
    let pattern = "^[A-Za-z0-9._-]+$"
    guard name.range(of: pattern, options: .regularExpression) != nil else { return false }
    return name != "." && name != ".."
}

func isValidEnvKeyName(_ name: String) -> Bool {
    let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
    return name.range(of: pattern, options: .regularExpression) != nil
}

func defaultEnvKeyName(for providerName: String, fallback: String = "RELAY") -> String {
    let raw = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = raw.isEmpty ? fallback : raw
    var normalized = ""

    for scalar in source.uppercased().unicodeScalars {
        let value = scalar.value
        let isUppercaseLetter = value >= 65 && value <= 90
        let isDigit = value >= 48 && value <= 57
        if isUppercaseLetter || isDigit {
            normalized.unicodeScalars.append(scalar)
        } else if !normalized.hasSuffix("_") {
            normalized.append("_")
        }
    }

    normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if normalized.isEmpty {
        normalized = fallback
    }
    if let first = normalized.unicodeScalars.first, first.value >= 48 && first.value <= 57 {
        normalized = "PROVIDER_\(normalized)"
    }

    return "\(normalized)_API_KEY"
}
