# 现场捕获记录（invisible-console-window）

本文是 [`../invisible-console-window.md`](../invisible-console-window.md) 的原始材料，保留探测器逐行输出与时间戳。

## 探测器输出

```text
2026-09-18 20:12:37.977  WIN+  hwnd=0x100242 pid=8272(run-hidden) class=ConsoleWindowClass
                                title=%USERPROFILE%\.dsh\run-hidden.exe
                                rect=230,230,991x518  @EXTERNAL(primary)
2026-09-18 20:12:37.981  FG    抢走前台焦点
2026-09-18 20:12:38.036  WIN-  (closed)  存活 59 ms
```

## 任务侧对齐（任务计划状态）

- 同一时刻的看门狗任务：`LastRunTime = 20:12:37`、`rc=0` —— 与窗口出现时刻精确吻合。

## 事件序列

| 时间 | 事件 |
| --- | --- |
| 12:18 | 该启动器投入使用，当时仅验证任务 `Result=0` 与心跳正常 |
| 20:12:37.977 | 探测器捕获窗口出现；同刻任务计划记录 `LastRunTime=20:12:37, rc=0` |
| 20:12:37.981 | 同一窗口抢占前台焦点 |
| 20:12:38.036 | 窗口关闭，存活 59 ms |
| 20:14 | 以 `/target:winexe` 重新编译 |
| 20:17:39 | 生产条件 A/B 对照：新版零窗口、零抢焦点 |

附带事实：该缺陷自投入使用起共暴露约 8 小时，期间未被任务侧指标发现。

## 修复后回归回读

- 看门狗任务在 20:17:37 实跑，返回码 0，日志在 20:17:39 正常写入。
- 另建一次性任务实测「启动器 → `cmd.exe /c md <目录>`」：目录成功创建，返回码 0。
- 任务 `State` / `RunLevel` / `UserId` 改动前后一致，已回读确认。
