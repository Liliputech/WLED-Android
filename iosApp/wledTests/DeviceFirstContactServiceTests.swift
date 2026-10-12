import Testing
import Foundation
import Shared
@testable import WLED

/// Exercises `DeviceFirstContactService` end-to-end through the shared Kotlin `DeviceApi`
/// and the Ktor Darwin engine, with HTTP responses served by `StubURLProtocol`.
struct DeviceFirstContactServiceTests {

    private static let client = DeviceApiClient(
        factory: DeviceApiFactory.companion.create { configuration in
            configuration.protocolClasses = [StubURLProtocol.self]
        }
    )

    /// Unique per test so stubs never collide when tests run in parallel.
    let host = "wled-\(UUID().uuidString.lowercased()).test"
    let database = AppDatabase(inMemory: true)
    var repository: DeviceRepository { database.deviceRepository }

    private func makeService() -> DeviceFirstContactService {
        DeviceFirstContactService(repository: repository, deviceApiClient: Self.client)
    }

    private func stubInfo(name: String = "WLED Office", mac: String? = "aabbccddeeff") {
        let macField = mac.map { #""mac": "\#($0)","# } ?? ""
        let body = #"{ \#(macField) "name": "\#(name)", "ver": "0.15.0", "leds": {}, "wifi": {}, "extra": 1 }"#
        StubURLProtocol.register(.http(statusCode: 200, body: body), for: host)
    }

    private func insertDevice(mac: String = "aabbccddeeff", address: String, name: String = "WLED Office") async throws {
        try await repository.insert(device: Device(macAddress: mac, address: address, originalName: name, lastSeen: 0))
    }

    /// Runs `fetchAndUpsertDevice` against the stubbed host and returns the `ServiceError` it threw.
    private func fetchError() async -> DeviceFirstContactService.ServiceError? {
        await #expect(throws: DeviceFirstContactService.ServiceError.self) {
            try await makeService().fetchAndUpsertDevice(rawAddress: host)
        }
    }

    // MARK: - fetchAndUpsertDevice

    @Test func fetchAndUpsertRequestsJsonInfoOverHttp() async throws {
        stubInfo()

        _ = try await makeService().fetchAndUpsertDevice(rawAddress: host)

        #expect(StubURLProtocol.requests(for: host).map(\.url?.absoluteString) == ["http://\(host)/json/info"])
    }

    @Test func fetchAndUpsertCreatesNewDevice() async throws {
        stubInfo(name: "Kitchen", mac: "001122334455")

        let device = try await makeService().fetchAndUpsertDevice(rawAddress: host)

        let stored = try await repository.findDeviceByMacAddress(address: "001122334455")
        #expect(stored?.address == host)
        #expect(stored?.originalName == "Kitchen")
        #expect(device.macAddress == "001122334455")
    }

    @Test func fetchAndUpsertStripsSchemeAndTrailingSlashes() async throws {
        stubInfo()

        let device = try await makeService().fetchAndUpsertDevice(rawAddress: "http://\(host)//")

        #expect(device.address == host)
    }

    @Test func fetchAndUpsertReturnsExistingDeviceWhenUnchanged() async throws {
        try await insertDevice(address: host)
        stubInfo()

        let device = try await makeService().fetchAndUpsertDevice(rawAddress: host)

        #expect(device.address == host)
        #expect(device.originalName == "WLED Office")
    }

    @Test func fetchAndUpsertUpdatesAddressOfKnownDevice() async throws {
        try await insertDevice(address: "10.0.0.1")
        stubInfo()

        _ = try await makeService().fetchAndUpsertDevice(rawAddress: host)

        let stored = try await repository.findDeviceByMacAddress(address: "aabbccddeeff")
        #expect(stored?.address == host)
    }

    @Test func fetchAndUpsertUpdatesNameOfKnownDevice() async throws {
        try await insertDevice(address: host, name: "Old Name")
        stubInfo(name: "New Name")

        _ = try await makeService().fetchAndUpsertDevice(rawAddress: host)

        let stored = try await repository.findDeviceByMacAddress(address: "aabbccddeeff")
        #expect(stored?.originalName == "New Name")
    }

    @Test func fetchAndUpsertThrowsWhenMacAddressIsMissing() async {
        stubInfo(mac: nil)

        #expect(await fetchError()?.kind == .missingMacAddress)
    }

    @Test func fetchAndUpsertThrowsWhenMacAddressIsEmpty() async {
        stubInfo(mac: "")

        #expect(await fetchError()?.kind == .missingMacAddress)
    }

    @Test func fetchAndUpsertThrowsHttpErrorOnNonSuccessStatus() async {
        StubURLProtocol.register(.http(statusCode: 500, body: "Oops", contentType: "text/plain"), for: host)

        #expect(await fetchError()?.kind == .httpError(500))
    }

    /// Verifies Kotlin exceptions surface as Swift errors instead of crashing (`@Throws` on `DeviceApi`).
    @Test func fetchAndUpsertThrowsRequestFailedWhenDeviceIsUnreachable() async {
        StubURLProtocol.register(.failure(.cannotConnectToHost), for: host)

        #expect(await fetchError()?.kind == .requestFailed)
    }

    @Test func fetchAndUpsertThrowsRequestFailedOnMalformedJson() async {
        StubURLProtocol.register(.http(statusCode: 200, body: "{ not json"), for: host)

        #expect(await fetchError()?.kind == .requestFailed)
    }

    /// Verifies Swift task cancellation reaches the Kotlin coroutine and comes back as `CancellationError`.
    @Test func fetchAndUpsertPropagatesCancellation() async {
        StubURLProtocol.register(.never, for: host)
        let service = makeService()
        let host = host

        let task = Task { try await service.fetchAndUpsertDevice(rawAddress: host) }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func fetchAndUpsertDoesNotStoreDeviceOnFailure() async throws {
        StubURLProtocol.register(.failure(.timedOut), for: host)

        _ = try? await makeService().fetchAndUpsertDevice(rawAddress: host)

        let stored = try await repository.findDeviceByMacAddress(address: "aabbccddeeff")
        #expect(stored == nil)
    }

    // MARK: - tryUpdateAddress

    @Test func tryUpdateAddressReturnsFalseForNilMac() async {
        #expect(await makeService().tryUpdateAddress(macAddress: nil, address: host) == false)
    }

    @Test func tryUpdateAddressReturnsFalseForEmptyMac() async {
        #expect(await makeService().tryUpdateAddress(macAddress: "", address: host) == false)
    }

    @Test func tryUpdateAddressReturnsFalseForUnknownDevice() async {
        #expect(await makeService().tryUpdateAddress(macAddress: "aabbccddeeff", address: host) == false)
    }

    @Test func tryUpdateAddressUpdatesAddressOfKnownDevice() async throws {
        try await insertDevice(address: "10.0.0.1")

        let handled = await makeService().tryUpdateAddress(macAddress: "aabbccddeeff", address: "http://10.0.0.2/")

        let stored = try await repository.findDeviceByMacAddress(address: "aabbccddeeff")
        #expect(handled)
        #expect(stored?.address == "10.0.0.2")
    }

    @Test func tryUpdateAddressDoesNotContactDevice() async throws {
        try await insertDevice(address: "10.0.0.1")

        _ = await makeService().tryUpdateAddress(macAddress: "aabbccddeeff", address: host)

        #expect(StubURLProtocol.requests(for: host).isEmpty)
    }
}

/// Case of a `ServiceError` without its associated `Error`, so tests can compare errors with `==`.
private extension DeviceFirstContactService.ServiceError {
    enum Kind: Equatable {
        case missingMacAddress
        case httpError(Int)
        case requestFailed
    }

    var kind: Kind {
        switch self {
        case .missingMacAddress: .missingMacAddress
        case .httpError(let statusCode): .httpError(statusCode)
        case .requestFailed: .requestFailed
        }
    }
}
