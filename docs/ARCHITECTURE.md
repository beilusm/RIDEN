# Architecture

`composeApp` 是 Kotlin Multiplatform 模块，`commonMain` 共享协议、调度器、业务状态与 Compose Material 3 UI；`desktopMain` 支持 Linux/Windows JVM，`androidMain` 支持 Android USB Host。

## 数据流

```text
Compose UI -> PowerController -> ModbusScheduler -> ModbusRtu -> SerialTransport
                    ^                                  |
                    +--------- merged registers -------+
                    |
                    +-> FAST PowerSnapshot -> 300-point history
                                           -> RecordingSink (CSV)
```

## 核心

- `SerialTransport`：枚举、打开、字节读写、关闭；同步驱动通过 Dispatchers.IO 运行。
- `ModbusRtu`：0x03 / 0x06、CRC16、地址、功能码、异常帧、字节长度与写回显校验。累积读预算 250 ms，失败后 80 ms 排空。
- `ModbusScheduler`：一个 worker、互斥队列与合并唤醒通道。写入/用户读取/FAST/SLOW 基础优先级为 0/2/4/6；每等 500 ms 优先级提升一档。相同优先级遵循 FIFO。
- 相同 key 的待执行读取共享结果；已执行的任务不替换。写入不去重。FAST 待执行任务 300 ms 过期，队列上限 128。
- 关闭 worker 会使正在执行和待执行的结果全部结束；失败任务不会阻塞后续任务。已接受的写入不会因为等待调用者取消而无声丢弃。
- `Registers`：121 个地址、物理单位、缩放、可写权限、范围与来源；未知地址只读。`DeviceCapabilities` 根据 HR0 识别型号，`DeviceState.definitions` 统一提供当前型号的精度和设定/保护上限，未知型号的参数只读。
- `DeviceState`：不可变完整缓存。FAST 更新业务采样；SLOW 只合并预设和活动组，不生成重复采样。
- `PowerController`：会话生命周期互斥，维护 StateFlow；150 ms FAST、1 s SLOW、1 s USB 发现。手动断开关闭自动连接；连接失败关闭自动连接并报告错误。
- 多字段预设编辑及写后回读在单个调度任务中执行。设备没有事务回滚，失败时可能存在部分写入，应重新读取设备确认。
- 录制通过有界 channel 顺序消费业务快照；停止先停止接受，再排空、关闭并导出。

## 平台

桌面采用 jSerialComm，Swing 文件选择器在 UI 线程显示，文件 I/O 在 IO dispatcher。录制开始前的文件选择不持有采样所需的锁，轮询继续执行。
Android 采用 usb-serial-for-android，USB 权限使用系统广播，录制写私有文件后 SAF 导出，取消时保留文件。
Android Activity 处理旋转和 UI 模式变化以保留会话；销毁时释放控制器。
桌面主窗口和置顶监控窗口共享同一个控制器。

## 验证

```bash
./gradlew :composeApp:desktopTest
ANDROID_HOME="$HOME/Android/Sdk" ./gradlew :composeApp:assembleDebug
./gradlew :composeApp:createDistributable
```

测试包含调度优先级、FIFO、去重、老化、过期、关闭结算、协议 CRC、写入校验、缓存合并、演示往返、预设切换、逐点录制、历史上限、重连，以及桌面/360 px 窄屏 UI 流程。
这些测试不替代 Windows 主机与真实 RIDEN 硬件验收。未完成项记录在 [MIGRATION.md](MIGRATION.md)。
