# win-agent-tools —— 让 Windows 上的自动化别那么难看的两个小工具

## 1. `run-hidden.exe`（源码 `run-hidden.cs`）

**问题**：Windows 计划任务／无人值守脚本里，`powershell.exe -WindowStyle Hidden` **照样会闪一个黑框、并且抢走前台焦点**。
原因是 `-WindowStyle Hidden` 是「**先创建控制台窗口，再把它隐藏**」—— 窗口确实出现过。

**解法**：把启动器编译成 **GUI 子系统**（`/target:winexe`）的可执行文件，由它去 `CreateProcess` 拉起真正的命令。
GUI 子系统进程**不会被分配控制台**，所以根本不会创建那个窗口 —— 比 VBScript 的 `WScript.Shell.Run(cmd, 0, False)` 更彻底。

```powershell
# 编译（csc 随 .NET Framework 自带，无需装任何东西）
csc /nologo /target:winexe /optimize+ run-hidden.cs
```

```powershell
# 用法：第一个参数 = 要跑的命令（可带参数），后面的参数原样透传
& .\run-hidden.exe "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File D:\scripts\job.ps1
```

### 三个实测踩出来的坑

1. **第一个参数必须写完整路径**：写裸名 `powershell.exe` 会**静默失败** —— 任务返回码 `2`、脚本一行都不跑、日志空白。写成完整路径立刻正常。
2. **`Start-Process -ArgumentList` 会截断带空格和中文的路径** → 每条参数自己加引号，或者把路径写进脚本内部。
3. **别用 `.bak` 后缀备份可执行文件**：双击时 Windows 会弹「选取打开方式」对话框，很烦。

> 来源：本机 6 个计划任务里有 4 个每分钟/每五分钟跑一次，闪窗抢焦点被用户投诉后抓现行（用窗口枚举探针把"窗口出现 → 抢焦点 → 关闭"三帧和任务的启动时间精确对上），最后靠 PE 子系统这一层根治。

---

## 2. `html-shot.ps1` —— HTML 转 PNG（无头浏览器）

给自动化脚本（或 AI 助手）一个「把网页渲染成图」的能力，用于**自己验收自己的前端输出**。

```powershell
pwsh -NoProfile -File .\html-shot.ps1 -Html ".\report.html" -Out ".\report.png" -Width 1600 -Height 1200
```

- 用**无头 Edge / Chromium** 渲染，支持等待 JS 执行完再截图；
- **确定性输出**：同一输入连渲两次 SHA256 一致（适合做"改动前后对比"）；
- 不需要 Node、不需要 Puppeteer —— 纯 PowerShell 调浏览器参数。

⚠️ 实测提醒：**没装 Chrome 的机器上，Puppeteer 类方案会一律失败**（`Code: 0`），但系统自带的 Edge 可用 —— 优先用 Edge。

---

## License

MIT。
