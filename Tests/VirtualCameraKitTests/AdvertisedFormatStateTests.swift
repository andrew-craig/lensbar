import Foundation
import Testing
import VirtualCameraKit

@Suite("Advertised format policy")
struct AdvertisedFormatStateTests {
    let f720 = VirtualCameraFormat(width: 1280, height: 720, fpsNumerator: 25)
    let f1080 = VirtualCameraFormat(width: 1920, height: 1080, fpsNumerator: 25)
    let f720at30 = VirtualCameraFormat(width: 1280, height: 720, fpsNumerator: 30)

    @Test("Same format is a no-op")
    func sameFormat() {
        var s = AdvertisedFormatState(advertised: f720)
        #expect(s.request(f720, clients: 0) == .none)
        #expect(s.request(f720, clients: 2) == .none)
        #expect(s.pending == nil)
    }

    @Test("Zero clients: replace the device straight away")
    func immediate() {
        var s = AdvertisedFormatState(advertised: f720)
        #expect(s.request(f1080, clients: 0) == .replaceDevice(f1080))
        #expect(s.advertised == f1080)
        #expect(s.pending == nil)
    }

    @Test("Streaming: defer, never replace while clients > 0")
    func deferred() {
        var s = AdvertisedFormatState(advertised: f720)
        #expect(s.request(f1080, clients: 1) == .none)
        #expect(s.advertised == f720)
        #expect(s.pending == f1080)
        #expect(s.clientsChanged(to: 2) == .none)
        #expect(s.clientsChanged(to: 1) == .none)
        #expect(s.settled(clients: 1) == .none)
        #expect(s.advertised == f720)
    }

    @Test("Deferred change applies after count reaches zero and settles")
    func appliesAtZero() {
        var s = AdvertisedFormatState(advertised: f720)
        _ = s.request(f1080, clients: 1)
        #expect(s.clientsChanged(to: 0) == .applyAfterSettling)
        #expect(s.advertised == f720)
        #expect(s.settled(clients: 0) == .replaceDevice(f1080))
        #expect(s.advertised == f1080)
        #expect(s.pending == nil)
        #expect(s.settled(clients: 0) == .none)
    }

    @Test("Client returning during the settle delay keeps the format (Zoom video toggle)")
    func clientReturns() {
        var s = AdvertisedFormatState(advertised: f720)
        _ = s.request(f1080, clients: 1)
        #expect(s.clientsChanged(to: 0) == .applyAfterSettling)
        #expect(s.clientsChanged(to: 1) == .none)
        #expect(s.settled(clients: 1) == .none)
        #expect(s.advertised == f720)
        #expect(s.pending == f1080)
    }

    @Test("Latest request wins while deferred")
    func latestWins() {
        var s = AdvertisedFormatState(advertised: f720)
        _ = s.request(f1080, clients: 1)
        _ = s.request(f720at30, clients: 1)
        #expect(s.pending == f720at30)
        _ = s.clientsChanged(to: 0)
        #expect(s.settled(clients: 0) == .replaceDevice(f720at30))
    }

    @Test("Requesting the advertised format again cancels a pending change")
    func revertCancels() {
        var s = AdvertisedFormatState(advertised: f720)
        _ = s.request(f1080, clients: 1)
        #expect(s.request(f720, clients: 1) == .none)
        #expect(s.pending == nil)
        #expect(s.clientsChanged(to: 0) == .none)
        #expect(s.settled(clients: 0) == .none)
    }

    @Test("Count reaching zero with nothing pending does nothing")
    func nothingPending() {
        var s = AdvertisedFormatState(advertised: f720)
        #expect(s.clientsChanged(to: 0) == .none)
        #expect(s.settled(clients: 0) == .none)
    }
}

@Suite("Format store")
struct FormatStoreTests {
    private func freshDefaults() -> UserDefaults {
        let name = "VirtualCameraKitTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("Empty store falls back to the default format")
    func empty() {
        let store = FormatStore(defaults: freshDefaults())
        #expect(store.load() == nil)
        #expect(store.loadOrDefault() == .default)
    }

    @Test("Saves and loads")
    func roundTrip() {
        let store = FormatStore(defaults: freshDefaults())
        let f = VirtualCameraFormat(width: 1920, height: 1080, fpsNumerator: 30000, fpsDenominator: 1001)
        store.save(f)
        #expect(store.load() == f)
    }

    @Test("Garbage falls back to the default format")
    func garbage() {
        let d = freshDefaults()
        d.set("not a format", forKey: FormatStore.key)
        #expect(FormatStore(defaults: d).loadOrDefault() == .default)
    }
}
