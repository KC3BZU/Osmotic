import CoreWLAN
import Foundation

/// Runs in its own bounded child, so scans, Keychain prompts and association cannot hang recovery.
nonisolated func rejoinHome(_ directory: URL) -> Int32 {
    guard let data = try? Data(contentsOf: directory.appendingPathComponent("lease.json")),
        let lease = try? JSONDecoder().decode(RecoveryLease.self, from: data),
        let interface = CWWiFiClient.shared().interface(withName: lease.interface)
    else { return 2 }
    func stage(_ message: String) {
        try? Data(message.utf8).write(to: directory.appendingPathComponent("rejoin.stage"), options: .atomic)
    }
    stage("scanning return network")
    guard let networks = try? interface.scanForNetworks(withName: lease.homeSSID),
        let network = networks.first(where: { $0.ssid == lease.homeSSID })
    else { stage("return network unavailable in scan"); return 3 }
    stage("reading saved credential for return network")
    var password: NSString?
    var status = CWKeychainFindWiFiPassword(.system, Data(lease.homeSSID.utf8), &password)
    if status != 0 { status = CWKeychainFindWiFiPassword(.user, Data(lease.homeSSID.utf8), &password) }
    guard status == 0, let password else { stage("saved credential unavailable"); return 4 }
    stage("associating with saved return network")
    do { try interface.associate(to: network, password: password as String) } catch {
        stage("CoreWLAN return association failed"); return 5
    }
    stage("return network associated")
    return 0
}
