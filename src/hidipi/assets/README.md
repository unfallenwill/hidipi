# 状态栏图标

图形使用显示器轮廓和 2 × 2 像素阵列，表达显示模式与 HiDPI 的双倍像素渲染。无文字、无背景、单色透明，专为 18 × 18 pt 的 macOS 状态栏设计。

- `StatusIconTemplate.svg`：可编辑矢量源文件。
- `StatusIconTemplate.png`：18 × 18 px，1×。
- `StatusIconTemplate@2x.png`：36 × 36 px，Retina 2×。
- `StatusIconTemplate@3x.png`：54 × 54 px，备用 3×。
- `../../../docs/status-icon-preview.png`：浅色与深色背景预览，含放大图与实际逻辑尺寸。

## 接入实现

状态栏已由 `src/hidipi/menubar.py` 接入：`runtime.preview` 在进入等待循环前创建 `NSStatusItem`，
退出（预览超时、Ctrl+C、菜单退出或异常）时移除。图标按本文约定加载：`NSImage` 逻辑尺寸 18 × 18 pt，
`isTemplate = true`，由系统随菜单栏外观着色；按钮 tooltip 与辅助功能名称均为 hidipi。
菜单包含当前模式状态行与「恢复原始设置并退出」，动作与 Ctrl+C 走同一恢复路径。

纯 ctypes 实现，导入时不加载框架，不依赖 PyObjC，且不限于 ARM64（Intel 机型同样显示）。
图标仅为体验增强：创建失败、无桌面会话或设置环境变量 `HIDIPI_MENUBAR=0` 时自动降级为无图标，
不影响任何显示切换与回滚逻辑。单元测试见 `tests/test_menubar.py`（模拟 ObjC 桥）。

## 重新生成

在 macOS 上从仓库根目录运行（仅使用系统 AppKit，无新增 Python 依赖）：

```sh
swift -module-cache-path /tmp/hidipi-swift-cache scripts/render-status-icon.swift
```

渲染脚本与 SVG 使用相同几何坐标；修改设计时需要同步更新两者。脚本生成三种 PNG 和预览图，不启动 hidipi，也不修改显示器设置。
