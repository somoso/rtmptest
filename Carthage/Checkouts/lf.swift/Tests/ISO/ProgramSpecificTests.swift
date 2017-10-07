import Foundation
import XCTest

@testable import lf

final class ProgramSpecificTests: XCTestCase {

    static let dataForPAT:[UInt8] = [0, 0, 176, 13, 0, 1, 193, 0, 0, 0, 1, 240, 0, 42, 177, 4, 178]
    static let dataForPMT:[UInt8] = [0, 2, 176, 29, 0, 1, 193, 0, 0, 225, 0, 240, 0, 27, 225, 0, 240, 0, 15, 225, 1, 240, 6, 10, 4, 117, 110, 100, 0, 8, 125, 232, 119]

    func testPAT() {
        let pat:ProgramAssociationSpecific = ProgramAssociationSpecific(bytes: ProgramSpecificTests.dataForPAT)!
        XCTAssertEqual(pat.programs, [1:4096])
        XCTAssertEqual(pat.bytes, ProgramSpecificTests.dataForPAT)
    }

    func testPMT() {
        let pmt:ProgramMapSpecific = ProgramMapSpecific(bytes: ProgramSpecificTests.dataForPMT)!
        XCTAssertEqual(pmt.bytes, ProgramSpecificTests.dataForPMT)
    }
}
