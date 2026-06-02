import Foundation

func isValidProviderName(_ name: String) -> Bool {
    let pattern = "^[A-Za-z0-9._-]+$"
    guard name.range(of: pattern, options: .regularExpression) != nil else { return false }
    return name != "." && name != ".."
}
