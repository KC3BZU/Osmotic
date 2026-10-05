import Foundation

/// A stable identity prevents every retry from consuming another approval slot on the device.
public enum PairingIdentity {
    public static func load(from defaults: UserDefaults) -> String {
        let key = "pairingIdentifier"
        if let saved = defaults.string(forKey: key), saved.utf8.count == 32,
            saved.allSatisfy({ "0123456789abcdef".contains($0) })
        {
            return saved
        }
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(identifier, forKey: key)
        return identifier
    }
}
