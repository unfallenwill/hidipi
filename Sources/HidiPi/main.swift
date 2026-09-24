/// HidiPi 菜单栏 App 入口：accessory 策略（无 Dock 图标，与 LSUIElement 双保险）。
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
