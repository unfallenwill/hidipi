# HidiPi（Swift 版）

Python 版 hidipi（`/Users/devuser/GitHub/hidipi`）的 Swift 移植：纯菜单栏 App，一条菜单开启 HiDPI，退出自动恢复。

- **实体屏 HiDPI**：列出每台显示器隐藏的 HiDPI 模式并切换
- **虚拟屏**（Apple Silicon）：无 HDMI 设备凭空创建 HiDPI Virtual Display
- **开机自启**：登录时启动（SMAppService）
- **备份/恢复**：与 Python 版完全互通（`~/.config/hidipi/`，同一 JSON 格式、同一把锁）

## 构建

仅需 Command Line Tools（无需 Xcode），macOS 13+ / Apple Silicon：

```sh
scripts/build-app.sh        # 产出 dist/HidiPi-<版本>.dmg
```

打开 DMG，把 HidiPi.app 拖入 Applications。也可直接运行 `build/HidiPi.app`。

分发现成的 DMG 时，收方首次打开若被隔离提示，执行：
`xattr -dr com.apple.quarantine /Applications/HidiPi.app`（本机自建通常无此问题）。

## 使用

双击启动后菜单栏出现图标（显示器轮廓 + 2×2 像素阵列）：

- **显示器 N ▸** 子菜单列出可用 HiDPI 尺寸（✓ 为当前）；镜像中的屏幕会禁用
- **虚拟屏幕 ▸** 创建 1920×1080 / 2560×1440，或移除
- **登录时启动** 开关
- **从备份恢复…** 最近 8 份备份
- **退出（恢复原始设置）**：物理屏恢复原模式，虚拟屏移除

虚拟屏 + 登录时启动 = 重启自动恢复：创建成功会把尺寸记到
`~/.config/hidipi/virtual.json`，App 登录启动后自动重建；只有菜单里
**显式「移除虚拟屏幕」** 才清除记录。意外消失（如系统重组显示器）不清除记录，
下次登录仍会重建。

安全模型与 Python 版一致：

- 任何改动前先写备份并回读核验（`~/.config/hidipi/backups/`，长期保留）
- 退出 / 移除即恢复；物理屏切换用 app-only 作用域，进程被杀也自动回退
- 与 Python 版共用 `operation.lock`：两边不能同时运行（后启动方会明确提示）
- 同一时刻只允许一种修改（物理屏或虚拟屏其一），菜单会引导

## 开发

```sh
swift build            # 构建
swift test             # 单元测试（纯逻辑 + 与 Python 备份互通）
```

结构：`Sources/HidiPiCore`（纯逻辑：模式选择 / 备份校验）、`Sources/HidiPi`（App：
CG 事务、虚拟屏桥接、菜单栏 UI）、`Sources/HidiPiIcon`（图标几何，状态栏与 icns 共用）、
`Sources/render-icon`（icns 素材生成）、`scripts/build-app.sh`（打包）。

已知怪癖：本机 swift 6.4-dev 工具链偶发 `TestingMacros plugin not found`（clean 也可能复发），
显式传入插件路径即可：

```sh
swift test -Xswiftc=-external-plugin-path \
  -Xswiftc='/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing#/Library/Developer/CommandLineTools/usr/bin/swift-plugin-server'
```

## 与 Python 版的差异（有意为之）

- 无 CLI、无 20 秒预览倒计时：菜单栏 App 常驻运行，退出即恢复
- 自启动用 SMAppService（App 注册自身），不写 LaunchAgent
- 图标以同一几何参数程序化绘制（与 `StatusIconTemplate.svg` 像素级一致），不打包 PNG

## 许可证

MIT（同 Python 版）。
