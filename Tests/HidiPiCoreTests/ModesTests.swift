import Testing
@testable import HidiPiCore

@Test func modeMatchesHzTolerance() {
    let base = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    #expect(Modes.modeMatches(base, ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3840, pixelHeight: 2160, hz: 60.59)))
    #expect(!Modes.modeMatches(base, ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3840, pixelHeight: 2160, hz: 60.61)))
    #expect(!Modes.modeMatches(nil, base))
    #expect(!Modes.modeMatches(base, ModeInfo(width: 1920, height: 1080,
        pixelWidth: 1920, pixelHeight: 1080, hz: 60)))  // pixel mismatch
}

@Test func isHiDPIBoundaries() {
    #expect(Modes.isHiDPI(ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3840, pixelHeight: 2160, hz: 60)))
    #expect(!Modes.isHiDPI(ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3839, pixelHeight: 2160, hz: 60)))  // 1 pixel short
    #expect(!Modes.isHiDPI(nil))
}

@Test func chooseModeFiltersAndPrefers() throws {
    let current = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, hz: 60)
    let hidpi60 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    let hidpi50 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 50)
    let lodpi = ModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, hz: 144)
    let unusable = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                            hz: 120, usable: false)
    // Same refresh rate preferred over higher refresh rate
    let chosen = try Modes.chooseMode([hidpi50, lodpi, hidpi60], size: (1920, 1080), current: current)
    #expect(chosen.hz == 60)
    // Falls back to the highest rate when none matches
    let fallback = try Modes.chooseMode([hidpi50], size: (1920, 1080), current: current)
    #expect(fallback.hz == 50)
    // Refresh filter; unusable and LoDPI never qualify; size mismatch
    #expect(throws: HiDPIError.self) {
        try Modes.chooseMode([hidpi50, hidpi60], size: (1920, 1080), current: current, refresh: 144)
    }
    #expect(throws: HiDPIError.self) {
        try Modes.chooseMode([lodpi, unusable], size: (1920, 1080), current: current)
    }
    #expect(throws: HiDPIError.self) {
        try Modes.chooseMode([hidpi60], size: (1280, 720), current: current)
    }
}

@Test func modeMatchesLenientSkipsUnknownRate() {
    let expected = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    let noRate = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 0)
    // Either side with unknown hz (0) → refresh comparison skipped
    #expect(Modes.modeMatchesLenient(noRate, expected))
    #expect(Modes.modeMatchesLenient(expected, noRate))
    // Both known → back to the 0.6 Hz tolerance
    let off = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 100)
    #expect(!Modes.modeMatchesLenient(off, expected))
    #expect(!Modes.modeMatchesLenient(nil, expected))
}

@Test func hidpiChoicesDedupsPerSize() {
    let current = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, hz: 60)
    let hi60 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    let hi100 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 100)
    let hi50 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 50)
    let qhd = ModeInfo(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, hz: 60)
    let lodpi = ModeInfo(width: 1280, height: 720, pixelWidth: 1280, pixelHeight: 720, hz: 60)
    let unusable = ModeInfo(width: 3840, height: 2160, pixelWidth: 7680, pixelHeight: 4320,
                            hz: 60, usable: false)
    // Same size: the mode matching the current refresh rate wins over higher rates
    // (regardless of input order)
    #expect(Modes.hidpiChoices([hi100, hi60], current: current).map(\.hz) == [60])
    #expect(Modes.hidpiChoices([hi60, hi100], current: current).map(\.hz) == [60])
    // Same size, neither close to the current rate: highest wins
    #expect(Modes.hidpiChoices([hi50, hi100], current: current).map(\.hz) == [100])
    // Unusable and LoDPI filtered out; results sorted by size ascending
    #expect(Modes.hidpiChoices([qhd, hi60, lodpi, unusable], current: current)
        .map { "\($0.width)x\($0.height)" } == ["1920x1080", "2560x1440"])
}

@Test func parseSize() throws {
    #expect(try Modes.parseSize("1920x1080").0 == 1920)
    #expect(try Modes.parseSize("1920×1080").1 == 1080)
    #expect(throws: HiDPIError.self) { try Modes.parseSize("639x1080") }
    #expect(throws: HiDPIError.self) { try Modes.parseSize("7690x4320") }
    #expect(throws: HiDPIError.self) { try Modes.parseSize("1920") }
    #expect(throws: HiDPIError.self) { try Modes.parseSize("1920x480x1") }
}

@Test func describe() {
    let hidpi = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 59.94)
    #expect(Modes.describe(hidpi) == "1920×1080, rendered 3840×2160, 59.94 Hz, HiDPI")
    #expect(Modes.describe(ModeInfo(width: 1920, height: 1080, pixelWidth: 1920,
                                    pixelHeight: 1080, hz: 60))
        == "1920×1080, rendered 1920×1080, 60 Hz, standard DPI")
    #expect(Modes.describe(nil) == "Mode unavailable")
    #expect(Modes.formatG(60.0) == "60")
    #expect(Modes.formatG(59.94) == "59.94")
}
