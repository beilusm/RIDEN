# RIDEN implementation constraints

当前主分支由用户授权迁移至 Compose Multiplatform。旧 Flutter 约束与源代码保存在 `legacy/flutter`，不再阻止本次架构和调度器重写。

- 不自动提交、推送或发布，除非用户明确要求。
- 版本唯一来源为 `VERSION`：当前 `2.0.0-1`；新版本递增最后一位（`2.0.1`），同版补丁递增后缀（`2.0.0-1`、`2.0.0-2`）。补丁属于正式发布，不是预发行。发布 tag 为 `v` + 完整版本号。
- 保留用户已有的未提交文件；`labview/` 不属于重构范围。
- 串口 I/O 必须由平台实现移到 `Dispatchers.IO`，不能阻塞 Compose UI。
- ModbusScheduler 是单个会话的唯一通信入口；多步写入必须在一个调度任务中执行。
- FAST 150 ms、SLOW 1000 ms、响应累积预算 250 ms、异常排空 80 ms。
- 未知和只读寄存器拒绝写入；映射来源必须保留，不能根据字段名称猜测协议。
- 预设切换使用 HR19，UI 仅允许 M1-M9。OVP/OCP 读取和编辑活动预设地址。
- 部分轮询合并到会话缓存，不得将未读字段重置为零。
- CSV 只消费业务 PowerSnapshot，每个成功 FAST 采样与波形点对应一行。
- 断开时必须终止轮询、关闭调度器、结算等待者，最后关闭平台串口。
- 修改共享核心后运行 `./gradlew :composeApp:desktopTest`；修改 Android 路径后构建 `:composeApp:assembleDebug`。
- 界面变更须检查桌面和窄屏截图；发布与真实硬件验收没有证据时不得声明完成。

当前进度与待验收项目见 `docs/MIGRATION.md`。
