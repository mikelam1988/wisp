// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Network
import Security
import WispCommon
import WispDirectTLS

/// A private, provisioned configuration shared by one host and its viewer. Read from any queue.
/// The random key stays out of UserDefaults, arguments, and logs.
struct DirectTransport: Decodable {
    let share: Bool
    let addresses: [String]
    let key: Data

    static func load() throws -> Self? {
        let url = Brand.supportDirectory.appendingPathComponent("direct-connection.json")
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return nil }
        let attrs = try files.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw HostError("Set direct-connection.json to mode 600, owned by the current user.")
        }
        let config: Self
        do { config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { throw HostError("Could not read direct-connection.json. Check the connection configuration.") }
        guard config.key.count == 32, config.share || !config.addresses.isEmpty else {
            throw HostError("Direct connections require a random 32-byte key and, for viewers, a host address.")
        }
        return config
    }

    static func viewer(for host: String) -> Self? {
        do {
            guard let config = try load(), !config.share,
                  config.addresses.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) else { return nil }
            return config
        } catch {
            Log.warning(.access, error.localizedDescription)
            return nil
        }
    }

    func tcp(_ options: NWProtocolTCP.Options) -> NWParameters {
        NWParameters(tls: securityOptions(datagram: false), tcp: options)
    }

    func udp() -> NWParameters {
        NWParameters(dtls: securityOptions(datagram: true), udp: NWProtocolUDP.Options())
    }

    private func securityOptions(datagram: Bool) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let version: tls_protocol_version_t = datagram ? .DTLSv12 : .TLSv12
        sec_protocol_options_set_min_tls_protocol_version(options, version)
        sec_protocol_options_set_max_tls_protocol_version(options, version)
        let label = Data((datagram ? "wisp direct video v1" : "wisp direct control v1").utf8)
        let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: label, outputByteCount: 32)
        secret.withUnsafeBytes { wisp_set_direct_key(options, $0.baseAddress, $0.count) }
        return tls
    }
}
