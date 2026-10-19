# Sketchpad

经典画图的 macOS 原生移植，目前是第 1 阶段骨架（名字是占位）。

## 构建

装了 Xcode：打开 `Sketchpad.xcodeproj`，运行 `Sketchpad` scheme。工程由 `project.yml` 生成，改了目标或文件结构后运行 `xcodegen generate`。

只有 Command Line Tools：

```sh
scripts/build-app.sh   # 生成 build/Sketchpad.app
scripts/test.sh        # 跑 PaintCore 的测试
```

脚本会自动绕过两个 Command Line Tools 的问题：残留的旧版 `PackageDescription` 接口文件导致 manifest 链接失败，以及 SwiftPM 找不到 swift-testing 的宏插件。

## 结构

- `Sources/PaintCore`：像素模型和算法，不依赖 AppKit。`Bitmap` 是左上角原点的 RGBA8 位图，`Raster` 是铅笔、橡皮和油漆桶的硬边算法，`Shapes` 用 Core Graphics 画抗锯齿形状，`ImageCodec` 负责 PNG、JPEG、BMP 读写。
- `Sources/Sketchpad`：AppKit 外壳。`CanvasDocument`（NSDocument，负责撤销）、`CanvasView`（画布和鼠标）、`CanvasWindowController`（侧栏、缩放、状态栏）、`MainMenu`（代码构建的菜单栏）。
- `Tests/PaintCoreTests`：swift-testing 单元测试。

## 和原版对齐的行为

依据《Windows 画图移植 macOS 分析》里的反编译结果：

- 油漆桶：精确颜色匹配，四连通，没有容差。
- 铅笔和橡皮：硬边方形笔头；橡皮涂的是颜色 2。
- 形状：默认抗锯齿，轮廓画在拖拽框之内；左键拖拽时轮廓用颜色 1、填充用颜色 2，右键拖拽时两者对调。Shift 约束为 45° 或正方形。
- 撤销：只保存改动区域的快照，最多 50 步。
- 缩放：12.5% 到 800%，最近邻显示。
- 快捷键：P 铅笔，E 橡皮，B 填充，I 取色，Z 放大镜；Esc 取消正在拖拽的形状。
