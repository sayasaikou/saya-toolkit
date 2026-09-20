# 模式：进程创建事件触发的计划任务

用于实现「某进程启动时自动执行一个辅助程序」的需求，且不引入任何常驻进程。

典型场景：主程序启动后需要配套工具同时运行，但配套工具不适合作为服务常驻，也不希望引入轮询进程。

## 原理

Windows 安全审计提供进程创建事件（Event ID `4688`）。启用该审计后，系统会为每次进程创建写入一条事件记录。计划任务支持以「事件触发」方式注册，即在满足 XPath 查询条件的事件出现时执行一次任务。两者结合即可实现「指定进程启动 → 触发一次任务」的行为。

该方案的特点：

- 平时不存在任何常驻进程，仅在事件发生时执行一次；
- 触发条件由系统审计机制保证，不依赖轮询；
- 任务可配置为以最高权限运行，适用于需要提权的辅助程序。

## 实施步骤

### 1. 启用进程创建审计

```powershell
# 需要管理员权限
auditpol /set /subcategory:"Process Creation" /success:enable
```

或通过组策略：`计算机配置 → Windows 设置 → 安全设置 → 高级审核策略配置 → 详细跟踪 → 审核进程创建`。

### 2. 注册事件触发的计划任务

以管理员权限执行，将 `<TARGET_EXE>`、`<HELPER_EXE>`、`<HELPER_DIR>` 替换为实际路径：

```powershell
$query = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[EventID=4688]] and
      *[EventData[Data[@Name='NewProcessName']='<TARGET_EXE>']]</Select>
  </Query>
</QueryList>
"@

$action    = New-ScheduledTaskAction -Execute '<HELPER_EXE>' -WorkingDirectory '<HELPER_DIR>'
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)  # 占位，下面替换为事件触发
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

$task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
$task.Triggers = @()   # 事件触发需通过 XML 注入，见下方说明

# 事件触发器无法由 New-ScheduledTaskTrigger 直接构造，需注册后以 XML 方式写入：
$xml = Export-ScheduledTask -TaskName '<TASK_NAME>'
# 将 <Triggers> 段替换为：
#   <Triggers><EventTrigger><Enabled>true</Enabled>
#     <Subscription><QueryList>...</QueryList></Subscription>
#   </EventTrigger></Triggers>
Register-ScheduledTask -Xml $xml -TaskName '<TASK_NAME>' -Force
```

### 3. 回读验证

```powershell
$t = Get-ScheduledTask -TaskName '<TASK_NAME>'
$t.Actions      # 确认为目标辅助程序
$t.Triggers     # 确认为 EventTrigger
$t.State        # 期望 Ready
(Get-ScheduledTaskInfo -TaskName '<TASK_NAME>').LastTaskResult  # 手动触发后应检查
```

验证方式：手动执行一次 `Start-ScheduledTask`，并使用窗口枚举检查是否出现非预期的窗口（见下方注意事项）。

## 已验证的注意事项

1. **计划任务动作中，可执行文件必须写完整路径。** 使用裸文件名（依赖 PATH 解析）会导致静默失败：任务返回码 `2`、目标程序不启动、无日志输出。该问题在多种启动方式下均会复现。
2. **如需隐藏控制台窗口，应使用 GUI 子系统启动器**（见 `win-agent-tools/run-hidden.cs`）。仅设置 `-WindowStyle Hidden` 无法避免窗口创建与焦点抢占。
3. **任务 XML 的导出与再导入存在编码约束。** `Export-ScheduledTask | Set-Content` 默认写出无 BOM 的 UTF-8，而任务 XML 的声明为 UTF-16，直接 `XmlDocument.Load` 会报错。导出时应使用 `-Encoding Unicode`。
4. **`<Exec>` 节点可能不含 `<Arguments>` 子元素。** 需先创建该元素并按 `Command → Arguments → WorkingDirectory` 的顺序插入，直接赋值会因属性不存在而失败。
5. **修改任务不应重建任务对象。** 通过 `Export-ScheduledTask` 导出 XML、修改后再 `Register-ScheduledTask -Xml` 导入，可完整保留原任务的运行级别、用户上下文与触发器配置。
6. **该模式依赖 Windows 安全审计。** 若审计被关闭或日志被清理，触发将失效。审计日志本身也会持续增长，长期运行需评估日志容量。

## 许可

本文档描述的方法基于 Windows 公开机制，示例代码采用 MIT 许可。
