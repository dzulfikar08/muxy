import Foundation
import Testing
@testable import MuxyDaemon

@Suite("DaemonAuthenticator")
struct DaemonAuthenticatorTests {

    @Test("unix socket auto-authenticates matching UID")
    func unixSocketUIDAutoAuth() {
        let authenticator = DaemonAuthenticator()
        #expect(authenticator.authenticateUnixSocket(uid: getuid()))
    }

    @Test("unix socket rejects different UID")
    func unixSocketDifferentUIDRejected() {
        let authenticator = DaemonAuthenticator()
        #expect(!authenticator.authenticateUnixSocket(uid: 99999))
    }

    @Test("unknown device is rejected over TCP")
    func unknownDeviceRejected() {
        let authenticator = DaemonAuthenticator()
        let result = authenticator.authenticateTCP(
            deviceID: UUID(),
            token: Data("fake-token".utf8),
            sourceIP: "10.0.0.1"
        )
        #expect(result == .denied)
    }

    @Test("IP is banned after three failed attempts")
    func banAfterThreeFailures() {
        let authenticator = DaemonAuthenticator()
        let ip = "10.0.0.5"

        for _ in 0..<3 {
            let result = authenticator.authenticateTCP(
                deviceID: UUID(),
                token: Data("bad".utf8),
                sourceIP: ip
            )
            #expect(result == .denied)
        }

        #expect(authenticator.isBanned(ip: ip))
    }

    @Test("IP is not banned before three failed attempts")
    func notBannedBeforeThreeFailures() {
        let authenticator = DaemonAuthenticator()
        let ip = "10.0.0.6"

        _ = authenticator.authenticateTCP(
            deviceID: UUID(),
            token: Data("bad".utf8),
            sourceIP: ip
        )

        #expect(!authenticator.isBanned(ip: ip))
    }
}
