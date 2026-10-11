# 证据原文与时间线（antivirus-rewrites-crash-dump-config）

本文是 [`../antivirus-rewrites-crash-dump-config.md`](../antivirus-rewrites-crash-dump-config.md) 的原始材料。正文只留结论，这里保留逐条证据原文与完整时间线。

## 时间线

以下时间线来自守卫脚本日志与注册表快照文件，非事后回忆。

| 时间 | 事件 | 证据来源 |
| --- | --- | --- |
| 09-21 | 配置完整转储：`CrashDumpEnabled=7`（完整转储）、`MinidumpDir` 指向 `<DUMP_DIR>` | 配置快照 |
| 09-22 | 守卫记录到改写 **3 次** | 守卫日志 |
| 09-23 | 守卫记录到改写 **15 次** | 同上 |
| 09-24 | 守卫记录到改写 **2 次** | 同上 |
| **09-25 10:55–17:25** | 改写 **14 次**，每半小时一次（与守卫巡检周期同步被观测到） | 同上 |
| **09-25 17:25:13** | 最后一次改写；随后 18:25 / 18:55 / 18:57 三次巡检均为 `OK` | 同上 |
| 09-25 | 回退现场快照存档 `crashcontrol-before.reg` | 备份目录 |
| 09-25 | 开启注册表审核，等待下一次复现 | 审核安装记录 |
| — | 从系统默认转储目录**补捞到 3 份此前未被发现的转储** | 逐哈希校验 |

**合计 34 次**（3 + 15 + 2 + 14），全部落在游戏运行时段内。

## 证据一：回退现场注册表快照

```
"AutoReboot"       =dword:00000000   <- 未动
"CrashDumpEnabled" =dword:00000003   <- 被改成「小内存转储」
"DumpFile"         =hex(2): <DUMP_DIR>\MEMORY.DMP   <- 未动
"MinidumpDir"      =hex(2): %SystemRoot%\Minidump   <- 被改成默认令牌
"LogEvent" / "Overwrite" / "DumpLogLevel" / "EnableLogFile"  <- 未动
```

## 证据二：二进制字符串命中

同一文件内同时存在：

```
CrashControl
CrashDumpEnabled
MinidumpDir
%SystemRoot%\Minidump
%SystemRoot%\MEMORY.DMP
MiniDumpWriteDump / Q?MiniDumpType:%d;
```

- 主体文件：反作弊模块目录下的 `ACE-Trace.dll`（v7.6.2212.89，2,377,608 字节，签名有效）。
- 同族文件：`<Steam库>\steamapps\common\<游戏>\Launcher\tenprotect\BugTrace.dll`（TenProtect）**命中同样的三个串**。

## 证据三：三份此前「消失」的转储

| 文件 | 时间 | 大小 | 说明 |
| --- | --- | --- | --- |
| `092126-15718-01.dmp` | 09-21 18:06 | 6.39 MB | — |
| `092126-15906-01.dmp` | 09-21 18:42 | 6.51 MB | — |
| **`092226-15843-01.dmp`** | **09-22 08:30** | **5.35 MB** | 正是当天 08:28 那次蓝屏留下的转储，因配置已在游戏时段被改写而落到了默认目录 |

三份已逐哈希校验后拷入 `<DUMP_DIR>` 归档。这份证据把「配置被改写」从一个理论风险，变成了一次**已经造成实际取证缺口**的事件。

## 现场抓获装置的安装步骤

对 `HKLM\SYSTEM\CurrentControlSet\Control\CrashControl` 启用注册表审核：

1. 对该键设置 SACL（`Everyone` / 成功）；
2. 打开「对象访问 → 注册表」子类审核（`auditpol`）；
3. 守卫每次巡检附带调用取证脚本，一旦检测到改写，就从安全日志里捞出对应事件并解析出进程名 ＋ pid ＋ 时间。

安装前状态已存档（原为 `No Auditing`，原 SACL 为空），可完整回滚。
