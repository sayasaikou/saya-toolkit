# saya-toolkit · AI 助手折腾出来的工具与方法论

> 这里放的是**真在用的东西**，不是玩具：一套给 AI 助手（DSH）用的工程实践 —— 跨会话交接、
> 计划任务不掉窗口、笔记本双烤监控、Blender 无头出图、ComfyUI 出图流水线，以及几次**真实故障的根因分析**。
> 全部是**自己踩过坑之后写下的结论**，路径与个人信息已清理。

**平台**：Windows 11 + PowerShell 7（多数脚本 5.1 也能跑）｜**License**：MIT（见各文件头）

---

## 目录

| 目录 | 内容 | 一句话价值 |
| --- | --- | --- |
| [`dsh-handoff/`](dsh-handoff/) | 跨会话交接三件套（state + template + check.ps1） | **上下文会丢，文件不会** —— 助手每次开场只读一个文件就能接上上次的活 |
| [`win-agent-tools/`](win-agent-tools/) | `run-hidden.exe` 源码、HTML→PNG 无头截图 | 计划任务**不再闪黑框抢焦点**；给 AI 一双「看网页」的眼睛 |
| [`thermal-monitor/`](thermal-monitor/) | `ab-monitor`（读 Afterburner 共享内存）+ 双烤一键监测 | 不装任何驱动就读到 91 项传感器；双烤自动收尾、带安全闸 |
| [`blender-headless/`](blender-headless/) | Blender 无头出图/诊断脚本集 | 批量渲多视角、材质排错，不用手点 GUI |
| [`comfy-pipeline/`](comfy-pipeline/) | `comfygen.py` / `promptbox.py` / 场景池 | 本地出图：多底模统一入口、按角色随机场景（不再白底站姿） |
| [`incident-notes/`](incident-notes/) | 故障根因记录 | 白屏、闪窗抢焦点、蓝屏排查 —— **症状 → 根因 → 修法**，附判据 |
| [`docs/`](docs/) | 盘点与清洗说明 | 哪些能公开、哪些必须脱敏、怎么自己复刻 |

---

## 三个最值得抄的东西

### 1. 跨会话交接（`dsh-handoff/`）
AI 助手会话一换就失忆，靠手写交接必然漂移。这套机制的做法是：
**单一数据源 + 机器渲染 + 每次实测**。助手只维护一份 `handoff-state.md`，
脚本负责核对（进程、计划任务、文件时间戳、指针存活）并渲染出 `HANDOFF.md`，
输出带 `CHECKED_AT` 时间戳 —— **「核对过了」有凭据，不靠自我总结**。

### 2. `run-hidden.exe`（`win-agent-tools/`）
Windows 计划任务想不弹黑框，`-WindowStyle Hidden` **是没用的**（它是"先建控制台再隐藏"，照样闪一下、照样抢焦点）。
真正的解法是**编译成 GUI 子系统**：`csc /target:winexe`。
源码 20 行 P/Invoke，替代掉整套 VBScript 方案。

### 3. 双烤监控（`thermal-monitor/`）
用 Afterburner 的共享内存（MAHM）拿传感器数据 —— **不装驱动、不读 WMI、91 项指标全都能读**。
配一个一键双烤脚本：实时显示 + 到点自动杀烤机 + 独立安全闸（防止跑飞了把机器烤干）。
本机实测结论示例：瓶颈在厂商功耗墙（GPU 172W / CPU 65W），散热与电源都有余量。

---

## 复刻须知（别踩同样的坑）

1. **路径全靠环境变量**：脚本里的 `$env:DSH_HOME` / `$env:DSH_WORKSPACE` 等请按自己的目录改；
2. **计划任务相关脚本必须纯 ASCII**：计划任务用 PowerShell 5.1 跑，无 BOM 的 UTF-8 会被当 ANSI 读 → 中文乱码 → 解析失败、连日志都不写；
3. **README 里写的"实测值"都是特定机器上的**：型号不同，结论会不同（我会标出机器型号）；
4. **没有 Windows 就没法跑这些**（`run-hidden`、任务计划、MAHM 都是 Windows 专属）。

---

## 状态

| 项 | 状态 |
| --- | --- |
| 目录骨架 | ✅ 已建 |
| 已脱敏可公开 | ✅ `dsh-handoff/`、`win-agent-tools/`、`thermal-monitor/`、`comfy-pipeline/`、`blender-headless/`（首批 13 个文件） |
| 待脱敏后加入 | ⏳ 云备份工具链、故障复盘全文、词库/人格配方、插件生态调研 —— 见 [`docs/发布盘点.md`](docs/发布盘点.md) |
| 已知局限 | ⚠️ 部分脚本仍含本机专属默认值（如 `$env:DSH_AI` 指向本地 ComfyUI 根目录），跑不起来就是路径没改 |

---

## License

本仓内容 MIT。第三方资产（模型、素材、插件）**各自遵循其原始许可**，本仓不附带任何模型权重。
