# 刘海文件托管台 · Notch File Shelf

一个面向 macOS 刘海屏的轻量文件托管台。它以独立的 AppKit 原生组件协作显示，不修改或注入第三方应用。

## 功能

- 将一个或多个文件、文件夹拖到刘海区域，保存为本机独立副本。
- 双击刘海展开托管台；支持 `⌘V` 粘贴文件、图片和文字。
- 支持框选、`⌘` 多选、`⌘C` 复制、`⌘V` 粘贴、`Delete` 移入废纸篓。
- 支持 UU 远程复制产生的异步文件接收，保留原文件名和格式。
- 支持通过 macOS 的 AirDrop 分享服务发送选中的托管副本。
- 删除只作用于托管副本，原文件保持不变。

## 构建

需要 macOS 12 或更高版本，以及 Xcode Command Line Tools 提供的 `clang`。

```sh
./build.sh
open build/刘海文件托管.app
```

默认构建结果位于 `build/`，脚本会生成一个可直接运行的应用包并进行临时签名。应用数据保存在当前用户的
`~/Library/Application Support/local.wanghao.NotchShelf`。

## 自测

```sh
./build.sh --self-test
./build.sh --clipboard-test
./build.sh --uu-test
```

自测只使用临时目录，不读取或修改系统通用剪贴板中的用户内容。

## 说明

这是一个独立的原生配合组件，默认按 `com.henrikruscon.Alcove` 的公开窗口信息进行位置协作；没有修改、注入或重新签署 Alcove。实际运行时的视觉效果和跨应用拖出行为取决于 macOS 版本、屏幕布局和宿主环境。

