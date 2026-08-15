//
//  HyundaiCanadaParsingTests.swift
//  BetterBlueKit
//
//  Regression coverage for Hyundai Canada status parsing. Payload shapes are
//  taken from a real Palisade debug export (BetterBlue#98).
//

import Foundation
import Testing
@testable import BetterBlueKit

@Suite("Hyundai Canada Parsing")
struct HyundaiCanadaParsingTests {

    @MainActor
    private func makeClient() -> HyundaiCanadaAPIClient {
        let config = APIClientConfiguration(
            region: .canada,
            brand: .hyundai,
            username: "test@example.com",
            password: "password123",
            pin: "1234",
            accountId: UUID()
        )
        return HyundaiCanadaAPIClient(configuration: config)
    }

    /// Build the dictionary the way production does — through
    /// `JSONSerialization`, so numbers arrive as `NSNumber` and booleans as
    /// `__NSCFBoolean`. Swift literal dictionaries don't bridge the same way
    /// and would exercise a code path the app never takes.
    private func json(_ raw: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func makeVehicle(fuelType: FuelType) -> Vehicle {
        Vehicle(
            vin: "TESTVIN0000000000",
            regId: "reg",
            model: "PALISADE",
            accountId: UUID(),
            fuelType: fuelType,
            generation: 2,
            odometer: Distance(length: 0, units: .kilometers)
        )
    }

    // MARK: - Fuel type detection

    /// A Canadian gas vehicle exposes its powertrain only as `fuelKindCode`.
    /// Before #98 this fell through to the `.electric` default, which hid the
    /// fuel range and gave a Palisade a phantom CCS1 charge port.
    @Test("fuelKindCode G is detected as gas, not electric")
    @MainActor func testGasVehicleDetectedFromFuelKindCode() throws {
        let vehicleData = try json(
            #"{"fuelKindCode": "G", "genType": "G1", "mainBatteryType": false, "modelName": "PALISADE"}"#
        )
        #expect(makeClient().detectFuelType(from: vehicleData) == .gas)
    }

    @Test("fuelKindCode E and P map to electric and phev")
    @MainActor func testElectricAndPhevFromFuelKindCode() throws {
        let client = makeClient()
        #expect(client.detectFuelType(from: try json(#"{"fuelKindCode": "E"}"#)) == .electric)
        #expect(client.detectFuelType(from: try json(#"{"fuelKindCode": "P"}"#)) == .phev)
    }

    /// `evStatus` is the older, more specific signal and must keep winning.
    @Test("evStatus still takes precedence over fuelKindCode")
    @MainActor func testEvStatusWinsOverFuelKindCode() throws {
        let vehicleData = try json(#"{"evStatus": "E", "fuelKindCode": "G"}"#)
        #expect(makeClient().detectFuelType(from: vehicleData) == .electric)
    }

    // MARK: - Gas range (DTE)

    /// Canada sends `dte`, not `distanceToEmpty`, and reports the unit as a
    /// JSON boolean. Reading the wrong key meant gas vehicles showed no range
    /// at all even though the value was present (#98).
    @Test("Gas range parses Canada's dte block with a boolean unit")
    @MainActor func testGasRangeFromDte() throws {
        let statusData = try json(#"{"fuelLevel": 59, "dte": {"unit": true, "value": 314}}"#)

        let range = try #require(
            makeClient().parseCanadaGasRange(from: statusData, vehicle: makeVehicle(fuelType: .gas))
        )
        #expect(range.range.length == 314)
        #expect(range.range.units == .kilometers) // unit: true == km in this region
        #expect(range.percentage == 59)
    }

    @Test("Gas range still accepts the distanceToEmpty spelling")
    @MainActor func testGasRangeFallbackKey() throws {
        let statusData = try json(#"{"fuelLevel": 40, "distanceToEmpty": {"unit": 1, "value": 210}}"#)

        let range = try #require(
            makeClient().parseCanadaGasRange(from: statusData, vehicle: makeVehicle(fuelType: .gas))
        )
        #expect(range.range.length == 210)
        #expect(range.range.units == .kilometers)
    }

    @Test("Gas range is nil for an electric vehicle")
    @MainActor func testGasRangeSkippedForEV() throws {
        let statusData = try json(#"{"fuelLevel": 59, "dte": {"unit": true, "value": 314}}"#)
        #expect(makeClient().parseCanadaGasRange(from: statusData, vehicle: makeVehicle(fuelType: .electric)) == nil)
    }
}
