# AdSkipper — 开屏广告自动跳过（TrollFools 注入版）

一个 iOS dylib：注入后，App 启动后 10 秒内自动寻找屏幕上的「跳过 / 跳过广告 / 关闭广告 / skip」按钮和右上角「×」，找到就模拟点击帮你关掉开屏广告。

**原理**：进程内截屏 → 系统 Vision 框架 OCR → 规则匹配 → 模拟点击。零网络请求、零 hook、不改 App 任何逻辑——App 服务端看到的只是一次正常触摸。

## 安装（每次约 1 分钟）

1. 下载编译产物：本仓库 **Actions** 标签页 → 最新一次构建 → 底部 **Artifacts** → 下载 `AdSkipper-dylib` → 解压得到 `AdSkipper.dylib`
2. 传到 iPhone（AirDrop / 微信 / 网盘均可），存到「文件」App
3. 打开 **TrollFools** → 选择目标 App → 注入 → 选中 `AdSkipper.dylib`
4. **杀掉该 App 进程后重新冷启动**（注入不重启不生效）

> 对每个想生效的 App 都要注入一次；同一个 dylib 可以反复使用。App 从 App Store 更新后需要重新注入。

## 生效判断（三个信号）

- 设备日志（`idevicesyslog` 或 Console.app）过滤 `AdSkipper`：
  - `[AdSkipper] armed (v1, ...)` = 注入成功、已布防
  - `[AdSkipper] hit (text '跳过') at (x, y) → tapping` = 识别到按钮
  - `[AdSkipper] tapped OK, done` = 已点击并收工
- 观感：开屏广告出现约 0.5~2 秒后自动消失

## 当前能力边界（第一版，如实交代）

- 支持文字按钮「跳过 / 跳过广告 / 关闭广告 / skip」，以及右上角孤立「X × ✕」字符
- 图形「×」走右上角几何检测（OCR 认不出图形符号），误触保护 = 连续 2 帧确认
- **Unity/Metal/OpenGL 渲染的游戏 App 会截屏全黑，不支持**（这类 App 的开屏不在覆盖范围）
- 点击依赖标准 UIControl 或手势识别器；极少数广告 SDK 用私有触摸处理时点不动，日志会留痕
- OCR 每轮 80~300ms，10 秒窗口约 20~30 轮；点中或超时即停，不常驻、不耗电

## 免责与安全

- 代码全部在本仓库，透明可审计；不联网、不上传、不读取剪贴板
- 请勿注入银行 / 支付类 App（它们有完整性风控，且没必要）
- 仅供个人自用，请勿分发改装版本

## 自定义关键词（第二版规划）

改 `AdSkipper.m` 里 `kKeywords` 一行重新编译即可；后续版本计划支持免编译的配置文件。
