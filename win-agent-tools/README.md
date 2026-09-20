# win-agent-tools

面向 Windows 自动化场景的组件与运维脚本。全部脚本为纯 ASCII、UTF-8 无 BOM、LF 换行；路径均通过参数配置，默认值优先取环境变量 `$env:DSH_HOME`，未设置时回退到当前用户目录。

## 一、核心组件

### 1.1 run-hidden：无窗口进程启动器

**问题**：在 Windows 计划任务或无人值守脚本中，`powershell.exe -WindowStyle Hidden` 仍会短暂显示控制台窗口并抢占前台焦点。原因是该参数的实现方式为「先创建控制台窗口，再将其隐藏」，窗口确实存在过。

**方案**：将启动器编译为 GUI 子系统可执行文件（`/target:winexe`），由它调用目标命令。GUI 子系统进程不会获得控制台分配，因此不会创建控制台窗口。该方式比 VBScript 的 `WScript.Shell.Run(cmd, 0, False)` 更彻底（后者依赖窗口创建后隐藏的行为）。

```powershell
# 编译：csc 随 .NET Framework 提供，无需额外安装
csc /nologo /target:winexe /optimize+ run-hidden.cs
```

```powershell
# 用法：首个参数为目标命令（可含参数），其余参数原样传递
& .\run-hidden.exe "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File D:\scripts\job.ps1
```

已验证的注意事项：

1. **首个参数必须为完整可执行文件路径。** 使用裸文件名会导致静默失败：计划任务返回码为 `2`，目标脚本不执行，且无日志输出。
2. **`Start-Process -ArgumentList` 会截断包含空格或非 ASCII 字符的路径。** 应为每个参数单独添加引号，或将路径直接写入脚本内部。
3. **可执行文件的备份不应使用 `.bak` 扩展名。** 双击时 Windows 会弹出「选择打开方式」对话框。

该结论已通过窗口枚举探针在生产环境验证：窗口创建、焦点抢占、窗口关闭三个事件与任务启动时间精确对应，修复后三个事件均不再出现。

### 1.2 html-shot：HTML 渲染为 PNG

用于为自动化脚本提供网页渲染能力，适用于交付前的视觉验收。

```powershell
pwsh -NoProfile -File .\html-shot.ps1 -Html ".\report.html" -Out ".\report.png" -Width 1600 -Height 1200
```

- 调用系统自带的 Edge / Chromium 内核渲染，支持等待脚本执行完成后截图；
- 输出具备确定性：相同输入连续两次渲染的 SHA256 一致，适用于改动前后的对比验证；
- 不依赖 Node.js 或 Puppeteer，仅通过 PowerShell 调用浏览器参数实现。

注意事项：在未安装 Chrome 的环境中，Puppeteer 类方案会统一失败（返回 `Code: 0`），而系统自带的 Edge 可用，应优先使用 Edge。

## 二、计划任务与服务运维脚本

以下脚本均为可选工具，参数均带默认值，可按部署环境覆盖。

### 2.1 fix-flash-tasks.ps1

消除计划任务的控制台窗口闪烁。将该任务的动作统一替换为无窗口启动器（`run-hidden`），并可选地对高频任务重设执行间隔。

| 参数 | 说明 |
| --- | --- |
| `-DshHome` | 工具与启动器所在目录 |
| `-HiddenRunner` | 无窗口启动器路径，默认 `<DshHome>\run-hidden-task.vbs` |
| `-TaskMap` | 任务名到启动器参数的映射，空则使用内置示例映射 |
| `-SlowTaskName` / `-SlowTaskHours` | 需要降低执行频率的任务名与新间隔（小时）；设为 0 则不修改触发器 |

修改前会导出原任务 XML 作为回滚点。

### 2.2 restart-verify.ps1

延迟重启本地服务，并在重启后执行验证：端口监听、页面探针长度、令牌刷新、可选插件脚印与客户端补丁标记检查。脚本以独立进程运行，因此不会被自身重启的服务中断。

| 参数 | 说明 |
| --- | --- |
| `-Delay` | 重启前等待秒数（留给调用方结束） |
| `-RestartScript` | 重启实现脚本，默认 `<DshHome>\dsh-restart.ps1` |
| `-Port` | 重启后必须监听的端口 |
| `-LauncherLog` | 用于读取令牌与探针结果的启动器日志 |
| `-SelfTaskName` | 完成后自注销的一次性任务名；空则不操作任何任务 |
| `-StampFile` | 可选的插件脚印文件，用于证明插件确实被重新加载；空则跳过 |
| `-PatchChecks` | 可选的客户端补丁标记检查项列表；空则不执行补丁检查 |

### 2.3 service-watchdog.ps1

面向「启动器 + 本地 Web 服务」结构的保活看门狗。定时探测服务端口，未监听时尝试重新拉起启动器，单轮最多重试 `-MaxRelaunch` 次；每轮写入一条心跳记录（含服务进程号、运行时长、最近启动时间），心跳断档可作为服务中断的可查证证据。

| 参数 | 说明 |
| --- | --- |
| `-Once` | 只执行一轮（供计划任务调用） |
| `-Launcher` / `-LauncherProcess` | 启动器路径与进程名 |
| `-Port` | 需要保活的端口 |
| `-MaxRelaunch` | 单轮最大重启尝试次数 |

### 2.4 watchdog-rescue-once.ps1

一次性救援脚本，用于「即将停服务或改动看门狗」的维护窗口：在延迟到期后检查看门狗是否仍处于启用状态、服务端口是否已恢复，异常则修复，随后自注销任务。该脚本应在维护开始前挂载，作为维护失败时的兜底。

| 参数 | 说明 |
| --- | --- |
| `-DelaySeconds` | 等待时长，须长于维护窗口 |
| `-WatchdogTask` | 必须恢复为启用状态的看门狗任务名 |
| `-SelfTaskName` | 完成时自注销的任务名 |
| `-Launcher` / `-Port` | 服务未恢复时用于拉起与验证的目标 |

### 2.5 update-check.ps1

会话开始时的环境与依赖更新自检：查询宿主应用本体、已注册插件、npm 全局工具与 winget 组件是否有新版本。**只查不升**，将结果输出为报告或单行结论。

| 参数 | 说明 |
| --- | --- |
| `-Quiet` | 仅输出一行结论 |
| `-Registry` | 版本查询所用 npm 源，默认官方源；可传镜像地址 |
| `-TimeoutSec` | 单次查询超时 |
| `-NpmTools` / `-WingetIds` | 需要检查的 npm 包与 winget 组件清单 |

退出码：`0` 表示无更新；`3` 表示存在可用更新；`2` 表示查询失败（网络或镜像问题）。

## 三、通用注意事项

1. **面向计划任务的脚本不得包含非 ASCII 字符。** Windows PowerShell 5.1 会将无 BOM 的 UTF-8 文件按 ANSI 解析，中文注释会导致解析失败并返回退出码 1，且不写出任何日志。
2. **计划任务的动作中，可执行文件必须写完整路径。** 依赖 PATH 解析会导致任务静默失败（返回码 `2`，目标不执行）。
3. **服务以非提权方式运行时，不要以 `-RunLevel Highest` 注册相关任务**，否则注册会被拒绝。
4. `[TimeSpan]::MaxValue` 无法用于任务的 `RepetitionDuration`（序列化后注册失败），应使用有限值（如 3650 天）。

## 许可

MIT。
