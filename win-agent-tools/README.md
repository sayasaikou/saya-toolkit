# win-agent-tools

面向 Windows 自动化场景的两个组件。

## 1. run-hidden：无窗口进程启动器

### 问题

在 Windows 计划任务或无人值守脚本中，`powershell.exe -WindowStyle Hidden` 仍会短暂显示控制台窗口，并抢占前台焦点。原因是 `-WindowStyle Hidden` 的实现方式为「先创建控制台窗口，再将其隐藏」，窗口确实存在过。

### 方案

将启动器编译为 GUI 子系统可执行文件（`/target:winexe`），由它调用目标命令。GUI 子系统进程不会获得控制台分配，因此不会创建控制台窗口。该方式比 VBScript 的 `WScript.Shell.Run(cmd, 0, False)` 更彻底（后者依赖窗口创建后隐藏的行为）。

```powershell
# 编译：csc 随 .NET Framework 提供，无需额外安装
csc /nologo /target:winexe /optimize+ run-hidden.cs
```

```powershell
# 用法：首个参数为目标命令（可含参数），其余参数原样传递
& .\run-hidden.exe "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File D:\scripts\job.ps1
```

### 已验证的注意事项

1. **首个参数必须为完整可执行文件路径。** 使用裸文件名（如 `powershell.exe`）会导致静默失败：计划任务返回码为 `2`，目标脚本不执行，且无日志输出。改为完整路径后立即正常。
2. **`Start-Process -ArgumentList` 会截断包含空格或非 ASCII 字符的路径。** 应为每个参数单独添加引号，或将路径直接写入脚本内部。
3. **可执行文件的备份不应使用 `.bak` 扩展名。** 双击时 Windows 会弹出「选择打开方式」对话框，影响日常使用。

工程结论：计划任务的动作应写为 `run-hidden.exe` + 目标程序的完整路径；该结论已通过窗口枚举探针在生产环境验证（窗口创建、焦点抢占、窗口关闭三个事件与任务启动时间精确对应，修复后三个事件均不再出现）。

## 2. html-shot：HTML 渲染为 PNG

用于为自动化脚本提供网页渲染能力，适用于交付前的视觉验收。

```powershell
pwsh -NoProfile -File .\html-shot.ps1 -Html ".\report.html" -Out ".\report.png" -Width 1600 -Height 1200
```

- 调用系统自带的 Edge / Chromium 内核渲染，支持等待脚本执行完成后截图。
- 输出具备确定性：相同输入连续两次渲染的 SHA256 一致，适用于改动前后的对比验证。
- 不依赖 Node.js 或 Puppeteer，仅通过 PowerShell 调用浏览器参数实现。

注意事项：在未安装 Chrome 的环境中，Puppeteer 类方案会统一失败（返回 `Code: 0`），但系统自带的 Edge 可用，应优先使用 Edge。

## 许可

MIT。
