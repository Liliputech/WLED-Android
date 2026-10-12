//
//  DeviceFirstContactService.swift
//  WLED
//
//  Created by Christophe Gagnier on 2025-12-16.
//

import Foundation
import Shared
import OSLog

/// Service responsible for handling the first contact with a device.
/// It fetches device info and handles the creation or update of the Device record in the repository.
actor DeviceFirstContactService {

    private let repository: DeviceRepository
    private let deviceApiClient: DeviceApiClient
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ca.cgagnier.wled-native",
        category: "DeviceFirstContactService"
    )

    /// Failures of the first contact. Descriptions are meant for logs only; callers show their own
    /// user-facing message.
    enum ServiceError: Error, CustomStringConvertible {
        case missingMacAddress
        case httpError(statusCode: Int)
        /// The request could not complete or its response could not be decoded.
        case requestFailed(any Error)

        var description: String {
            switch self {
            case .missingMacAddress: "Device did not report a MAC address"
            case .httpError(let statusCode): "Device responded with HTTP \(statusCode)"
            case .requestFailed(let error): "Request failed: \(error)"
            }
        }
    }

    /// - Parameters:
    ///   - repository: The Room device repository.
    ///   - deviceApiClient: Creates the shared Kotlin `DeviceApi` for a device address.
    init(
        repository: DeviceRepository = AppDatabase.shared.deviceRepository,
        deviceApiClient: DeviceApiClient = .shared
    ) {
        self.repository = repository
        self.deviceApiClient = deviceApiClient
    }

    // MARK: - Public API

    /// Fetches device information using its address, then ensures a corresponding
    /// device record exists in the database (creating or updating its address
    /// as necessary).
    ///
    /// - Parameter rawAddress: The network address input (e.g., "http://192.168.1.1/" or "wled.local").
    /// - Returns: The Device that was created or updated.
    func fetchAndUpsertDevice(rawAddress: String) async throws -> Device {
        let cleanAddress = sanitize(address: rawAddress)

        logger.debug("Initiating contact with: \(cleanAddress)")
        let info = try await fetchDeviceInfo(address: cleanAddress)

        guard let macAddress = info.macAddress, !macAddress.isEmpty else {
            logger.error("Could not retrieve MAC address for device at \(cleanAddress)")
            throw ServiceError.missingMacAddress
        }

        return try await upsertDevice(macAddress: macAddress, hostname: cleanAddress, name: info.name)
    }

    /// Attempts to identify and update a device using only the MAC address from mDNS/Discovery.
    /// This avoids a network call to the device if we already know who it is.
    ///
    /// - Parameters:
    ///   - macAddress: The MAC address found via mDNS (can be null/empty).
    ///   - address: The new IP address.
    /// - Returns: true if the device was found and processed (updated or skipped), false otherwise.
    func tryUpdateAddress(macAddress: String?, address: String) async -> Bool {
        guard let macAddress, !macAddress.isEmpty else { return false }

        // Ensure the address provided by mDNS is clean before saving
        let cleanAddress = sanitize(address: address)
        guard let existingDevice = try? await repository.findDeviceByMacAddress(address: macAddress) else {
            return false
        }

        if existingDevice.address != cleanAddress {
            logger.info("Fast update: IP changed for \(existingDevice.originalName) (\(macAddress))")
            do {
                try await repository.updateAddress(macAddress: existingDevice.macAddress, address: cleanAddress)
            } catch {
                logger.error("Failed to save fast update: \(error.localizedDescription)")
            }
        }
        return true
    }

    // MARK: - Private Helpers

    /// Removes schemes (http/https) and trailing slashes to ensure we store a clean hostname/IP.
    private func sanitize(address: String) -> String {
        var result = address

        // Remove scheme if present
        if let range = result.range(of: "://") {
            result = String(result[range.upperBound...])
        }

        // Remove trailing slashes
        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }

    /// Fetches device information from the specified address through the shared Kotlin `DeviceApi`.
    ///
    /// `Shared.Info` is spelled out because the app still has its own Swift `Info` model for websockets.
    private func fetchDeviceInfo(address: String) async throws -> Shared.Info {
        let response: ApiResponse<Shared.Info>
        do {
            response = try await deviceApiClient.create(address: address).getInfo()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw ServiceError.requestFailed(error)
        }

        guard response.isSuccessful, let info = response.body else {
            logger.error("Device at \(address) responded with HTTP \(response.code)")
            throw ServiceError.httpError(statusCode: Int(response.code))
        }
        return info
    }

    /// Handles the repository logic to find, update, or create the device.
    private func upsertDevice(macAddress: String, hostname: String, name: String?) async throws -> Device {
        guard let existingDevice = try await repository.findDeviceByMacAddress(address: macAddress) else {
            logger.info("Creating new device: \(macAddress)")
            let newDevice = Device(
                macAddress: macAddress,
                address: hostname,
                originalName: name ?? "",
                lastSeen: 0
            )
            try await repository.insert(device: newDevice)
            return newDevice
        }

        let deviceName = name ?? existingDevice.originalName
        // Check if updates are actually needed to minimize database writes
        if existingDevice.address == hostname && existingDevice.originalName == deviceName {
            logger.debug("Device exists and is up to date: \(macAddress)")
            return existingDevice
        }

        logger.debug("Updating existing device: \(macAddress)")
        let storedMac = existingDevice.macAddress
        if existingDevice.address != hostname {
            try await repository.updateAddress(macAddress: storedMac, address: hostname)
        }
        if existingDevice.originalName != deviceName {
            try await repository.updateOriginalName(macAddress: storedMac, originalName: deviceName)
        }
        return existingDevice.copy(address: hostname, originalName: deviceName)
    }
}
