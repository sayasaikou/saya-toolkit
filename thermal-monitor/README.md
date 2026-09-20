# thermal-monitor：基于 Afterburner 共享内存的硬件压力测试监控

## 用途

为笔记本电脑提供可复现的压力测试与监控流程。通过直接读取 MSI Afterburner 暴露的共享内存（MAHM），无需安装驱动、不依赖 WMI 或厂商 SDK，可获取 91 项传感器指标，包括温度、功耗、频率、占用率以及功耗墙触发状态。

## 使用方法

```powershell
# 列出全部指标名称
.\ab-monitor.exe --list

# 采样并写入 CSV
.\ab-monitor.exe --csv out.csv --interval 2
```

```powershell
# 一键双烤：实时显示 + 到点自动终止烤机程序 + 安全中断
pwsh -NoProfile -File .\dual-stress-monitor.ps1 -Minutes 15
```

- `dual-stress-monitor.ps1`：串联烤机程序、采样、导出 CSV、自动收尾；
- `stress-kill.ps1`：中断当前压力测试并清理相关进程；
- `ab-monitor.cs`：单文件 C# 实现，使用 `csc ab-monitor.cs` 即可编译。

## 共享内存格式

MAHM 共享内存的结构为：32 字节头部，随后为若干定长条目，每条 1324 字节。条目包含指标名称、单位、当前值、最大值、最小值与格式标志。`ab-monitor.cs` 已实现完整解析，可直接按需扩展字段。

## 实测结果示例

测试环境：2026 年上市的双内存槽笔记本，Intel Core Ultra 9 级处理器，独立显卡 16 GB 显存，330 W 电源适配器。双烤持续 15 分钟，采集 449 个采样点。

| 指标 | 结果 | 说明 |
| --- | --- | --- |
| GPU 稳态功耗 | 172 W（96% 时间触发 `Power limit = 1`） | 受厂商功耗墙限制，非散热受限 |
| CPU 稳态功耗 | 65 W（等于厂商 PL1 设定） | 同上 |
| 温度 | GPU 69 °C，CPU 78 °C（上限 87 °C / 100 °C） | 散热能力有余量 |
| `Temp limit` | 全程 0 次 | 温度墙未参与限制 |

结论：此类设备性能受限的原因通常为厂商功耗墙，与散热方案及电源适配器余量无关。厂商侧设置通常不提供命令行接口，自动化方案的能力边界在于「修改后可可靠回退」。

## 使用限制

1. 必须先运行 MSI Afterburner，共享内存由其创建，否则无法读取任何数据。
2. 笔记本的真实功耗与功耗墙状态无法通过 `Win32_VideoController` 等 WMI 接口获取，MAHM 是目前可行的途径。

## 许可

MIT。`ab-monitor.cs` 为本项目原创实现；MSI Afterburner 的版权归其权利人所有，本项目仅读取其公开的共享内存数据。
