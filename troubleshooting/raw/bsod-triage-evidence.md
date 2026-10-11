# 证据原文与时间线（bsod-triage）

本文是 [`../bsod-triage.md`](../bsod-triage.md) 的原始材料，保留逐行证据、模块地址段与完整时间线。

## 时间线

全部来自系统日志与转储文件，非事后回忆。

| 时间 | 事件 | 记录形式 | 性质 |
| --- | --- | --- | --- |
| 08-26 21:38 | NDIS 活内核转储（1887 MB） | `LiveKernelReports\NDIS-...dmp` | 网络栈挂起 |
| 08-30 13:45 | WHEA-Logger **ID 17**：PCIe **可纠正错误**，`PCI\VEN_8086&DEV_7ECA`（Intel 根端口 0:6.1），`CorrectableErrorStatus=0x1` | System 日志 | 硬件级 |
| 09-02 10:51 | 意外关机（**无转储**） | Kernel-Power 41 + 6008 | 硬冻结 / 掉电 |
| 09-02 10:54 | WATCHDOG 活内核转储（2 MB） | `LiveKernelReports\WATCHDOG\...dmp` | 设备挂起 |
| 09-02 11:17 / 11:57 / 15:54 | WHEA-Logger **ID 3** ×3：CPER 记录，`ErrorSeverity=3`（信息级，低危） | System 日志 | 固件上报 |
| 09-11 14:19 / 15:37 | 意外关机 ×2（**无转储**） | Kernel-Power 41 + 6008 | 硬冻结 / 掉电 |
| 09-13 12:15 | 蓝屏 **`0xCE`** DRIVER_UNLOADED_WITHOUT_CANCELLING_PENDING_OPERATIONS | `...-16593-01.dmp` | 驱动 |
| 09-17 23:29 | 断电（**外部原因**，与主机无关） | Kernel-Power 41 | 外部 |
| 09-18 10:24 | 蓝屏 **`0xE6`** DRIVER_VERIFIER_DMA_VIOLATION | `...-16421-01.dmp` | DMA / 驱动 |
| 09-18 19:18 | 蓝屏 **`0x116`** VIDEO_TDR_FAILURE，arg3=`0xC000009A`（STATUS_INSUFFICIENT_RESOURCES） | `...-17156-01.dmp` | 显卡超时 |
| 09-18 19:28 | **硬冻结**（长按电源键强制关机，**无转储**） | Kernel-Power 41 + 6008 | 硬冻结 |

近三周合计：3 次蓝屏（3 个互不相同的 bugcheck 码）＋ 4 次无转储的硬冻结 / 意外关机 ＋ 1 次 PCIe 可纠正错误 ＋ 3 次非致命内核挂起。

补充事实：几次无转储的意外关机系遇到问题时长按电源键强制关机所致。据此判定该主机在观察窗早期即已出现异常，并非最后一次事件才开始；且崩溃发生时机器近乎空转。

## 转储模块表（`0x116` 转储：`lm` 与已卸载模块表）

崩溃现场**加载中**的可疑第三方内核驱动：

| 模块 | 地址段 | 归属 |
| --- | --- | --- |
| `BAPIDRV64` | `0xfffff80330e00000`–`0xfffff80330e39000` | 某国产安全套件（已卸载） |
| `RTCore64` | `0xfffff8033e640000`–`0xfffff8033e64a000` | RivaTuner / MSI Afterburner |
| `ACE_CORE302706` | `0xfffff8033e730000`–`0xfffff803445a0000`（约 99 MB） | 腾讯 ACE 反作弊 |
| `MsIo64` | `0xfffff80330d60000`–`0xfffff80330d6b000` | MICSYS（主板厂商自带） |
| `Nahimic_Mirroring` / `NahimicBTLink` | — | MSI Nahimic |

已卸载但留痕的模块（模块表中的卸载残留项）：`360elam64.sy`、`ACE-SSC-DRV6`、`ACE-ADVT.sys`、`ace-game-0.s`、`ACE-CORE1027`、`ACE-CORE2027`、`ACE-GAME.sys`、`RTCore64.sys` ×2、`GPU-Z-v8.sys`、`kerneld-x64.`。

**bugcheck 参数定位（实测）**：`nt` 基址为 `0xfffff80386400000`；arg2 = `0xfffff80333a6a350`，落在 `nvlddmkm` 区间 `0xfffff80332110000`–`0xfffff80339485000` 之内（偏移 +0x195a350）。

> 限定：TDR 按定义就归因于显示驱动，因此该地址**不构成定罪**；它只说明崩溃现场位于显示驱动代码路径上。

## 孤儿内核驱动实测清单

- 服务 `BAPIDRV`：`Start=1`（`SYSTEM_START`）、`State=RUNNING`、`system32\DRIVERS\BAPIDRV64.sys`（229,128 B，签名有效）—— 转储证据证实崩溃时该驱动就在内核内存中。
- 服务 `360elam64`：`Start=0`（**`BOOT_START`**）、`Group=Early-Launch`、`system32\DRIVERS\360elam64.sys`（18,048 B）—— 早启动反恶意软件驱动。
- 目录残留与注册表项（清理前）：程序目录下三个子目录、`%APPDATA%` 下残留目录、`HKCU\SOFTWARE` 下三个键。
- 无相关进程、无卸载记录 ⇒ 判定为卸载残留的孤儿内核驱动。

## 图形调节工具的洗清（被自身证据推翻的假设）

- 安装于数据盘；不在任何 Run 启动项、无相关计划任务（配置中声明了由任务计划启动，但对应任务不存在）。
- 显卡配置文件：核心 / 显存偏移均为空 → 未套用超频。
- 电压解锁 / 强制恒压 / 非官方超频模式均为关闭。
- `RTCore64` 被加载的原因 ＝ 当天用调节工具 / 硬件信息工具读取传感器，**与超频无关**。

## 清理动作与回读结果

| 对象 | 动作 | 结果（回读实测） |
| --- | --- | --- |
| 早启动反恶意软件驱动服务 | 删除 | 注册表键已不存在 |
| 同名驱动文件 | 删除 | 已删除 |
| 另一个孤儿驱动服务 | 删除 | 已执行 `DeleteService`；键仍存在但 `DeleteFlag=1`、`Start=4`（标记删除且已禁用，重启后落地） |
| 同名驱动文件 | 删除 | 被占用（驱动仍在内存，`sc stop` 返回 1052）→ 已写入 `PendingFileRenameOperations`，重启时自动删除 |
| 残留目录（两处） | 删除 | 均已不存在 |
| 残留注册表项（三个） | 删除 | 均已不存在 |
| 失效防火墙规则 ×2（程序指向已不存在的可执行文件） | 删除 | 匹配数归 0 |

## 误伤拦截记录

清理清点阶段，匹配规则 `bapi` 误将 Windows 自带的 `cabapi.dll` 与 `dabapi.dll`（Cabinet API）列入候选 —— **未做删除**，清理完成后复核两者均完好。

> 教训：批量删除前必须逐条检视命中项，不能只看命中数量。

## 转储分析命令

```powershell
& "$env:ProgramFiles\WindowsApps\Microsoft.WinDbg_<version>_x64__<publisher>\amd64\kd.exe" `
  -z "$env:SystemRoot\Minidump\<dump>.dmp" `
  -y "srv*$env:SYMBOLS_DIR*https://msdl.microsoft.com/download/symbols" `
  -c "!analyze -v; q" -logo "$env:DSH_HOME\windbg\analyze.log"
```

安装的调试器版本：1.2606.22001.0；分页文件为 System 托管（12288 MB），自动内存转储具备写入空间。
