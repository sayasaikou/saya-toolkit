# thermal-monitor —— 读 MSI Afterburner 共享内存做笔记本双烤监控

## 它解决什么

想给笔记本做**可复现的压力测试**，通常要装一堆监控软件、还要人手盯着屏幕看温度。
这里换个路子：**直接读 MSI Afterburner 暴露的共享内存（MAHM）** ——
不装驱动、不读 WMI、不依赖任何 SDK，**91 项传感器**（温度／功耗／频率／占用／功耗墙标志）全都能拿到。

## 用法

```powershell
# 列出全部 91 项指标（先看名字，再决定读哪些）
.\ab-monitor.exe --list

# 采样（示例：每 2 秒一次进 CSV）
.\ab-monitor.exe --csv out.csv --interval 2
```

```powershell
# 一键双烤：实时显示 + 到点自动杀烤机 + 安全闸（防止跑飞把机器烤干）
pwsh -NoProfile -File .\dual-stress-monitor.ps1 -Minutes 15
```

- `dual-stress-monitor.ps1`：串起 AIDA64 / FurMark（或你指定的烤机程序）→ 采样 → 出 CSV → 自动收尾；
- `stress-kill.ps1`：急停，任何时刻把烤机进程清干净；
- `ab-monitor.cs`：单文件 C#，`csc ab-monitor.cs` 即得 exe。

## 数据格式（逆出来的，省你一遍）

MAHM 共享内存：**32 字节头 + 每条 1324 字节的条目**，条目里含名字、单位、当前值、最大/最小值、格式标志。
`ab-monitor.cs` 里已完整解析，直接改成你要的字段即可。

## 本机实测结论（示例，说明这套东西能得出什么）

机器：MSI Vector 16 HX AI A2XWIG（Intel Ultra 9 275HX + RTX 5080 Laptop 16G，330W 适配器），
双烤 15 分钟 / 449 个采样点：

| 指标 | 结果 | 解读 |
| --- | --- | --- |
| GPU 稳态功耗 | **172 W**（96% 时间触发 `Power limit = 1`） | 撞的是**厂商功耗墙**，不是散热 |
| CPU 稳态功耗 | **65 W**（= 厂商 PL1） | 同上 |
| 温度 | GPU 69°C / CPU 78°C（上限 87 / 100） | **散热有余量** |
| `Temp limit` | 全程 **0 次** | 温度墙从未参与 |

**结论**：这类机器"性能上不去"通常与散热、适配器无关，**卡在厂商功耗墙**；
要榨性能只能动厂商设置（往往没有 CLI，只能手点），脚本能帮的是**把"改完能不能回退"这件事自动化**。

## 两个坑

1. **必须先把 Afterburner 跑起来**（共享内存是它创建的），否则读不到任何东西；
2. **`Win32_VideoController` 之类的 WMI 查不到笔记本的真实功耗与功耗墙标志** —— 想要这些数据只有 MAHM 这条路。

## License

MIT（`ab-monitor.cs` 为本项目原创；MSI Afterburner 属 MSI/作者所有，本项目只是读取它暴露的共享内存）。
