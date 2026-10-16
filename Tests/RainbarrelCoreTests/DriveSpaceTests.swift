import Foundation
import Testing
@testable import RainbarrelCore

@Suite("Drive space and year map")
struct DriveSpaceTests {
    private let tb: Int64 = 1_000_000_000_000
    private let gb: Int64 = 1_000_000_000

    // MARK: Fit logic

    @Test func fullMirrorFitsWhenItIsSmallerThanTheFreeSpace() {
        let space = DriveSpace(volumeName: "Backup", totalBytes: 5 * tb, availableBytes: 4_200 * gb)
        let fit = space.fit(needBytes: 1_400 * gb)
        #expect(space.usedBytes == 800 * gb)
        #expect(fit.fits)
        #expect(fit.caption == "A full mirror needs 1.4 TB more. It fits.")
        let segments = fit.segments
        #expect(abs(segments.used - 0.16) < 1e-9)
        #expect(abs(segments.need - 0.28) < 1e-9)
        #expect(abs(segments.free - 0.56) < 1e-9)
        #expect(abs(segments.used + segments.need + segments.free - 1) < 1e-9)
    }

    @Test func fullMirrorThatDoesNotFitSaysHowMuchIsFree() {
        let space = DriveSpace(volumeName: "Backup", totalBytes: 5 * tb, availableBytes: 900 * gb)
        let fit = space.fit(needBytes: 1_400 * gb)
        #expect(!fit.fits)
        #expect(fit.caption == "A full mirror needs 1.4 TB more, but only 900 GB is free.")
        // The needed segment is cut off at the free space, so the bar ends exactly at the right edge.
        let segments = fit.segments
        #expect(abs(segments.need - 0.18) < 1e-9)
        #expect(segments.free < 1e-9)
        #expect(abs(segments.used + segments.need - 1) < 1e-9)
    }

    @Test func exactlyFullAndEmptyNeedsAreHandled() {
        let space = DriveSpace(volumeName: "Backup", totalBytes: 2 * tb, availableBytes: 1 * tb)
        #expect(space.fit(needBytes: 1 * tb).fits)
        #expect(!space.fit(needBytes: 1 * tb + 1).fits)
        let nothing = space.fit(needBytes: 0)
        #expect(nothing.caption == "The drive already holds a full mirror.")
        #expect(nothing.segments.need == 0)
        // A negative need is treated as zero.
        #expect(space.fit(needBytes: -5).needBytes == 0)
    }

    @Test func inconsistentCapacityNumbersStayInRange() {
        let more = DriveSpace(volumeName: "X", totalBytes: 100, availableBytes: 250)
        #expect(more.usedBytes == 0)
        #expect(more.fit(needBytes: 10).freeBytes == 100)
        let empty = DriveSpace(volumeName: "X", totalBytes: 0, availableBytes: 0)
        let segments = empty.fit(needBytes: 10).segments
        #expect(segments.used == 0 && segments.need == 0 && segments.free == 1)
    }

    @Test func volumeNameFromPathAlone() {
        #expect(DriveSpace.volumeName(forPath: "/Volumes/Backup Drive") == "Backup Drive")
        #expect(DriveSpace.volumeName(forPath: "/Volumes/Backup Drive/Photos/2019") == "Backup Drive")
        #expect(DriveSpace.volumeName(forPath: "/mnt/disk/photos") == "photos")
        #expect(DriveSpace.volumeName(forPath: "/") == "/")
    }

    @Test func readReturnsNilForAMissingFolder() throws {
        let dir = try TempDirectory()
        #expect(DriveSpace.read(at: dir.path("not-there")) == nil)
        #expect(DriveSpace.read(at: "") == nil)
    }

    #if os(macOS)
    @Test func readReportsTheVolumeOfAnExistingFolder() throws {
        let dir = try TempDirectory()
        let space = try #require(DriveSpace.read(at: dir.url.path))
        #expect(space.totalBytes > 0)
        #expect(space.availableBytes >= 0 && space.availableBytes <= space.totalBytes)
        #expect(!space.volumeName.isEmpty)
    }
    #endif

    // MARK: Formatting

    @Test func shortByteFormatDropsTrailingZeroDecimals() {
        #expect(DisplayFormat.bytesShort(0) == "0 B")
        #expect(DisplayFormat.bytesShort(999) == "999 B")
        #expect(DisplayFormat.bytesShort(1_000) == "1 KB")
        #expect(DisplayFormat.bytesShort(612_000_000) == "612 MB")
        #expect(DisplayFormat.bytesShort(1_400 * gb) == "1.4 TB")
        #expect(DisplayFormat.bytesShort(5 * tb) == "5 TB")
        #expect(DisplayFormat.bytesShort(4_200 * gb) == "4.2 TB")
        #expect(DisplayFormat.bytesShort(147_300_000_000) == "147.3 GB")
        // 999.96 GB rounds up into the next unit instead of printing "1000 GB".
        #expect(DisplayFormat.bytesShort(999_960_000_000) == "1 TB")
    }

    @Test func timeOrDateIsShortForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15 08:00 UTC
        #expect(DisplayFormat.timeOrDate(now.addingTimeInterval(-3600 * 2), now: now, calendar: calendar) == "06:00")
        #expect(DisplayFormat.timeOrDate(now.addingTimeInterval(-86_400), now: now, calendar: calendar) == "2027-01-14 08:00")
        #expect(DisplayFormat.timeOrDate(nil, now: now, calendar: calendar) == "never")
    }

    // MARK: Year map

    private func row(_ year: Int, cloud: Int, inSync: Int) -> YearRow {
        YearRow(year: year, cloudCount: cloud, inSync: inSync, onlineOnly: cloud - inSync, cloudBytes: Int64(cloud) * 10)
    }

    @Test func biggestGapsAreTheFiveYearsWithTheMostMissingPhotos() {
        let years = [
            row(2015, cloud: 100, inSync: 100),  // nothing missing: never listed
            row(2016, cloud: 100, inSync: 90),
            row(2017, cloud: 500, inSync: 100),
            row(2018, cloud: 300, inSync: 100),
            row(2019, cloud: 200, inSync: 0),    // ties with 2018 on 200 missing; the newer year comes first
            row(2020, cloud: 50, inSync: 49),
            row(2021, cloud: 120, inSync: 0),
            row(2022, cloud: 130, inSync: 10),
        ]
        let gaps = YearMap.biggestGaps(years)
        #expect(gaps.map(\.year) == [2017, 2019, 2018, 2022, 2021])
        #expect(YearMap.biggestGaps(years, limit: 2).map(\.year) == [2017, 2019])
        #expect(YearMap.biggestGaps([row(2015, cloud: 3, inSync: 3)]).isEmpty)
        #expect(YearMap.biggestGaps([]).isEmpty)

        let longest = gaps[0].onlineOnly
        #expect(YearMap.relativeLength(longest, maximum: longest) == 1)
        #expect(abs(YearMap.relativeLength(200, maximum: 400) - 0.5) < 1e-9)
        #expect(YearMap.relativeLength(5, maximum: 0) == 0)
    }

    @Test func gridStartsAtTheYearTwoThousandOldestFirstAndEarlierYearsAreSummarised() {
        let years = [
            row(2019, cloud: 10, inSync: 5), row(1969, cloud: 20, inSync: 20), row(2000, cloud: 4, inSync: 4),
            row(1980, cloud: 10, inSync: 9), row(1999, cloud: 1, inSync: 1),
        ]
        #expect(YearMap.gridYears(years).map(\.year) == [2000, 2019])
        #expect(YearMap.earlierSummary(years) == "1969 to 1999: 30 of 31 on the drive")
        #expect(YearMap.earlierSummary([row(1998, cloud: 3, inSync: 2)]) == "1998: 2 of 3 on the drive")
        #expect(YearMap.earlierSummary([row(2001, cloud: 3, inSync: 2)]) == nil)
    }

    @Test func cellChipsAndSpokenLabels() {
        let safe = row(2012, cloud: 40, inSync: 40)
        let few = row(2018, cloud: 1_000, inSync: 129)
        let many = row(2019, cloud: 17_826, inSync: 4_457)
        #expect(YearMap.missingChip(safe) == "all safe")
        #expect(YearMap.missingChip(few) == "871 missing")
        #expect(YearMap.missingChip(many) == "13k missing")
        #expect(YearMap.accessibilityLabel(many) == "2019: 25 percent on drive, 13,369 missing")
        #expect(YearMap.accessibilityLabel(safe) == "2012: 100 percent on drive, none missing")
    }

    @Test func percentNeverRoundsToTheExtremesWhileSomethingIsLeft() {
        #expect(YearMap.onDrivePercent(row(2020, cloud: 1_000, inSync: 999)) == 99)
        #expect(YearMap.onDrivePercent(row(2020, cloud: 1_000, inSync: 1)) == 1)
        #expect(YearMap.onDrivePercent(row(2020, cloud: 1_000, inSync: 0)) == 0)
        #expect(YearMap.onDrivePercent(row(2020, cloud: 1_000, inSync: 1_000)) == 100)
        #expect(YearMap.onDriveFraction(row(2020, cloud: 0, inSync: 0)) == 0)
    }
}
