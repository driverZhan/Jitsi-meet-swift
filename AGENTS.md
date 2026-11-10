# 工作空间约定

## 共享来源（只读参考）

- **lib-jitsi-meet（第一对齐目标）**：`/Users/zhanyong/Downloads/lib-jitsi-meet-master`
  - 公共 API 与事件以该目录的 TypeScript 源码为准：`JitsiConference.ts`、`JitsiConnection.ts`、
    `JitsiConferenceEvents.ts`、`JitsiConnectionEvents.ts`、`JitsiMeetJS.ts`、
    `JitsiMediaDevices.ts`、`modules/RTC/*`、`modules/xmpp/*`。
  - 实际运行的是打包产物：`Sources/JitsiJSRuntime/Resources/js/99-lib-jitsi-meet.bundle.js`。
- **jitsi-meet（产品层 UI 参考，不是对齐目标）**：
  `/Users/zhanyong/Downloads/jitsi-meet-stable-jitsi-meet_11248`

## 任务范围

- 在 lib-jitsi-meet-master 完全对齐之前，**所有任务都围绕本仓库的 LJM 对齐展开**。
- **冻结项**：E2EE（保持显式 `unimplemented`，不静默降级）、jitsi-meet 产品层 UI 改造。
  除非用户特别说明，不要启动这两项，也不要把它们排进待办优先级。
- 待办优先级见 `README.md` §12.1：P0 会议控制/主持人能力 → P1 信令与媒体扩展 →
  P2 统计与可见性事件。

## 验证口径

- 改门面或 shim：`swift Scripts/check-js-shims.swift`（当前 7 脚本、39 条断言）。
- 改 Swift：模拟器测试，然后 `./Scripts/build-xcframework.sh`。
