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
        pixelWidth: 1920, pixelHeight: 1080, hz: 60)))  // 像素不一致
}

@Test func isHiDPIBoundaries() {
    #expect(Modes.isHiDPI(ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3840, pixelHeight: 2160, hz: 60)))
    #expect(!Modes.isHiDPI(ModeInfo(width: 1920, height: 1080,
        pixelWidth: 3839, pixelHeight: 2160, hz: 60)))  // 差 1 像素
    #expect(!Modes.isHiDPI(nil))
}

@Test func chooseModeFiltersAndPrefers() throws {
    let current = ModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, hz: 60)
    let hidpi60 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 60)
    let hidpi50 = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, hz: 50)
    let lodpi = ModeInfo(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, hz: 144)
    let unusable = ModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160,
                            hz: 120, usable: false)
    // 同刷新率优先于更高刷新率
    let chosen = try Modes.chooseMode([hidpi50, lodpi, hidpi60], size: (1920, 1080), current: current)
    #expect(chosen.hz == 60)
    // 无同刷新率时取最高
    let fallback = try Modes.chooseMode([hidpi50], size: (1920, 1080), current: current)
    #expect(fallback.hz == 50)
    // 指定刷新率过滤；不可用与 LoDPI 均不入选；尺寸不符
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
    // 任一方 hz 未知（0）→ 跳过刷新率比较
    #expect(Modes.modeMatchesLenient(noRate, expected))
    #expect(Modes.modeMatchesLenient(expected, noRate))
    // 双方已知 → 回到 0.6 Hz 容差
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
    // 同尺寸：与当前刷新率一致者优先于更高刷新率（与传入顺序无关）
    #expect(Modes.hidpiChoices([hi100, hi60], current: current).map(\.hz) == [60])
    #expect(Modes.hidpiChoices([hi60, hi100], current: current).map(\.hz) == [60])
    // 同尺寸都不接近当前刷新率：取最高
    #expect(Modes.hidpiChoices([hi50, hi100], current: current).map(\.hz) == [100])
    // 不可用与 LoDPI 过滤；结果按尺寸升序
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
    #expect(Modes.describe(hidpi) == "1920×1080，渲染 3840×2160，59.94 Hz，HiDPI")
    #expect(Modes.describe(ModeInfo(width: 1920, height: 1080, pixelWidth: 1920,
                                    pixelHeight: 1080, hz: 60))
        == "1920×1080，渲染 1920×1080，60 Hz，普通 DPI")
    #expect(Modes.describe(nil) == "模式暂不可用")
    #expect(Modes.formatG(60.0) == "60")
    #expect(Modes.formatG(59.94) == "59.94")
}
