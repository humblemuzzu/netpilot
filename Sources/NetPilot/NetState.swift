import Foundation
import SystemConfiguration

struct NetSnapshot: Equatable {
    var serviceID = ""
    var serviceName = ""
    var interface = ""
    var router = ""
    var address = ""
    var networkKey = ""
    var dhcpDNS: [String] = []
    var manualDNS: [String] = []
    var domain = ""
    var portalAPI: String?

    var online: Bool { !serviceID.isEmpty && !router.isEmpty }
    var isPhoneHotspot: Bool { router == "172.20.10.1" || router.hasPrefix("192.0.0.") }
}

/// Reads network state from configd and reports changes, so nothing has to be polled.
final class NetWatcher {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private var pending: DispatchWorkItem?
    var onChange: (() -> Void)?

    func start() {
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        guard let store = SCDynamicStoreCreate(nil, "local.netpilot" as CFString, callback, &context) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        let patterns = [
            "State:/Network/Service/[^/]+/(DHCP|DNS|IPv4)",
            "Setup:/Network/Service/[^/]+/DNS",
            "State:/Network/Interface/[^/]+/Link",
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.store = store
        self.source = source
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func snapshot() -> NetSnapshot {
        Self.read(store)
    }

    nonisolated static func read(_ existing: SCDynamicStore? = nil) -> NetSnapshot {
        var snap = NetSnapshot()
        guard let store = existing ?? SCDynamicStoreCreate(nil, "local.netpilot.read" as CFString, nil, nil) else { return snap }
        guard let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let serviceID = global["PrimaryService"] as? String
        else { return snap }

        snap.serviceID = serviceID
        snap.interface = global["PrimaryInterface"] as? String ?? ""
        snap.router = global["Router"] as? String ?? ""

        if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/IPv4" as CFString) as? [String: Any],
           let addresses = ipv4["Addresses"] as? [String] {
            snap.address = addresses.first ?? ""
        }
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any] {
            snap.dhcpDNS = dns["ServerAddresses"] as? [String] ?? []
        }
        if let manual = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/DNS" as CFString) as? [String: Any] {
            snap.manualDNS = manual["ServerAddresses"] as? [String] ?? []
        }

        var dhcpServerID = ""
        if let dhcp = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(serviceID)/DHCP" as CFString) as? [String: Any] {
            if let data = dhcp["Option_6"] as? Data, snap.dhcpDNS.isEmpty, data.count >= 4 {
                snap.dhcpDNS = stride(from: 0, to: data.count - 3, by: 4).map { i in
                    "\(data[i]).\(data[i + 1]).\(data[i + 2]).\(data[i + 3])"
                }
            }
            if let data = dhcp["Option_15"] as? Data {
                snap.domain = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0 ."))
            }
            if let data = dhcp["Option_54"] as? Data, data.count == 4 {
                dhcpServerID = data.map(String.init).joined(separator: ".")
            }
            if let data = dhcp["Option_114"] as? Data,
               let uri = String(data: data, encoding: .utf8), uri.hasPrefix("https://") {
                snap.portalAPI = uri
            }
        }

        let prefs = SCPreferencesCreate(nil, "local.netpilot" as CFString, nil)
        if let prefs, let service = SCNetworkServiceCopy(prefs, serviceID as CFString) {
            snap.serviceName = SCNetworkServiceGetName(service) as String? ?? ""
        }

        var profile = ""
        if !snap.interface.isEmpty,
           let airport = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(snap.interface)/AirPort" as CFString) as? [String: Any] {
            profile = airport["ProfileID"] as? String ?? ""
        }
        if !profile.isEmpty {
            snap.networkKey = "wifi:" + profile
        } else {
            let subnet = snap.address.split(separator: ".").dropLast().joined(separator: ".")
            snap.networkKey = "net:\(snap.interface)|\(snap.router)|\(dhcpServerID)|\(subnet)"
        }
        return snap
    }
}
