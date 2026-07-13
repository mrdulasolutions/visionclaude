import XCTest
@testable import ClaudeVision

/// UK number-plate validation, OCR-confusion correction, and extraction from
/// spoken text — the on-device half of Vehicle mode.
final class PlateReaderTests: XCTestCase {

    // MARK: - VRN format validation (AA00AAA)

    func testValidCurrentFormatVRN() {
        XCTAssertTrue(PlateReader.isValidVRN("AB12CDE"))
        XCTAssertTrue(PlateReader.isValidVRN("XX99XXX"))
    }

    func testInvalidVRNsAreRejected() {
        XCTAssertFalse(PlateReader.isValidVRN("ab12cde"), "lowercase is not a valid plate read")
        XCTAssertFalse(PlateReader.isValidVRN("AB12CD"))    // too short
        XCTAssertFalse(PlateReader.isValidVRN("AB12CDEF"))  // too long
        XCTAssertFalse(PlateReader.isValidVRN("A112CDE"))   // digit where a letter belongs
        XCTAssertFalse(PlateReader.isValidVRN("ABX2CDE"))   // letter where a digit belongs
        XCTAssertFalse(PlateReader.isValidVRN("AB12CD3"))
    }

    // MARK: - OCR normalisation

    func testNormalizeUppercasesAndStripsSeparators() {
        XCTAssertEqual(PlateReader.normalizeVRN("ab12 cde"), "AB12CDE")
        XCTAssertEqual(PlateReader.normalizeVRN("AB12-CDE"), "AB12CDE")
    }

    func testOCRConfusionsAreCorrectedPositionally() {
        // Digit read where the format demands a letter
        XCTAssertEqual(PlateReader.normalizeVRN("A812CDE"), "AB12CDE", "8→B in letter position")
        XCTAssertEqual(PlateReader.normalizeVRN("0B12CDE"), "OB12CDE", "0→O in letter position")
        XCTAssertEqual(PlateReader.normalizeVRN("AB12CD5"), "AB12CDS", "5→S in letter position")
        // Letter read where the format demands a digit
        XCTAssertEqual(PlateReader.normalizeVRN("ABI2CDE"), "AB12CDE", "I→1 in digit position")
        XCTAssertEqual(PlateReader.normalizeVRN("ABIZCDE"), "AB12CDE", "I→1 and Z→2 in digit positions")
    }

    func testCorrectPositionsAreLeftAlone() {
        // The confusion map must never fire where the character already fits the format
        XCTAssertEqual(PlateReader.normalizeVRN("OI12SBZ"), "OI12SBZ")
        XCTAssertEqual(PlateReader.normalizeVRN("AB05CDE"), "AB05CDE")
    }

    func testUncorrectableReadsReturnNil() {
        XCTAssertNil(PlateReader.normalizeVRN("1234567"), "digits 3,4,6 have no letter mapping")
        XCTAssertNil(PlateReader.normalizeVRN("AB12CD"), "wrong length")
        XCTAssertNil(PlateReader.normalizeVRN(""), "empty")
    }

    // MARK: - Extraction from spoken/typed text

    func testExtractsVRNFromSpokenPhrase() {
        XCTAssertEqual(PlateReader.extractVRN(fromText: "check plate AB12 CDE"), "AB12CDE")
        XCTAssertEqual(PlateReader.extractVRN(fromText: "is ab12cde taxed"), "AB12CDE")
        XCTAssertEqual(PlateReader.extractVRN(fromText: "AB 12 CDE"), "AB12CDE")
    }

    func testNoVRNInTextReturnsNil() {
        XCTAssertNil(PlateReader.extractVRN(fromText: "is this car taxed"))
        XCTAssertNil(PlateReader.extractVRN(fromText: "short"))
        XCTAssertNil(PlateReader.extractVRN(fromText: ""))
    }

    // MARK: - Privacy masking

    func testMaskedShowsOnlyAreaCode() {
        XCTAssertEqual(PlateReader.masked("AB12CDE"), "AB•••••")
        XCTAssertEqual(PlateReader.masked("AB"), "•••")
    }
}
