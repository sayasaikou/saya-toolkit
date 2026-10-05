# PowerShell 跨引擎兼容性护栏（pwsh 7 与 Windows PowerShell 5.1）

> 适用场景：同一台 Windows 上并存两套 PowerShell，且脚本会被**计划任务**、无窗口启动器或桌面快捷方式拉起。
> 测试环境：Windows 11（26100）｜pwsh **7.6.6**（Core ／ .NET 10）｜powershell.exe **5.1.26100.9444**（Desktop ／ .NET Framework）｜系统 ANSI 代码页 936。
> **证据分级**：全文结论标注为「实测」「现场记录（本次未复现）」「机制推断」三档，三档不混写。凡标注为推断者，不得在后续引用中升级为确定结论。

---

## 1. 问题

Windows 上同时存在两个 PowerShell：

| | `pwsh.exe` | `powershell.exe` |
| --- | --- | --- |
| 版本线 | PowerShell 7.x（Core） | Windows PowerShell 5.1（Desktop） |
| 运行时 | .NET（Core） | .NET Framework |
| 谁在调用 | 交互式会话、`& pwsh -File`、多数 `.cmd` 包装 | **计划任务默认**、`powershell.exe -File`、部分提权路径 |

两者**不是同一个程序的不同版本**，而是两套能力不同的运行时。典型翻车形态：一个脚本用 `pwsh` 写、用 `pwsh` 测、双击也正常，被计划任务拉起时立刻失败 —— 因为计划任务的动作默认落到 `powershell.exe`（5.1）上。

失败形态有两种，都很难从表面看出来：

1. **运行时找不到类型 / 命令**（报错明确，好定位）；
2. **整段解析失败**（报错指向奇怪的位置，脚本一行都不执行，连日志都不写）。

**判据：谁调它，就得在谁的语言里能用。**

---

## 2. 两个引擎的能力差异（实测）

### 2.1 缺失的类型、命令与参数

下表「5.1 报错原文」一列为本机实测输出，可直接用于日志检索。

| 对象 | pwsh 7 | powershell.exe 5.1 | 5.1 实测报错 |
| --- | --- | --- | --- |
| `System.Net.Http.SocketsHttpHandler` | 可用 | **不存在** | `Cannot find type [System.Net.Http.SocketsHttpHandler]: verify that the assembly containing this type is loaded.`（`PSArgumentException`） |
| `System.Net.Http.HttpClientHandler` | 可用 | **默认不可用**，须先加载程序集 | 同上 `Cannot find type`；执行 `Add-Type -AssemblyName System.Net.Http` 后可用（实测） |
| `System.Net.Http.HttpClient` | 可用 | 同上，须先加载程序集 | 同上 |
| `HttpClientHandler.SslOptions` | 可用 | 依赖上一条；且 .NET Framework 与 .NET 上该属性的可写项不同 | — |
| `Start-ThreadJob` | 内置（实测 2.2.0） | **不存在**（模块只随 PS7 分发） | `The term 'Start-ThreadJob' is not recognized as the name of a cmdlet...`（`CommandNotFoundException`） |
| `Get-Content -Encoding Byte` | **已移除** | 可用（实测返回 `120`） | 7 报 `'Byte' is not a supported encoding name`（`ParameterBindingArgumentTransformationException`）→ 7 上改 `-AsByteStream` |
| `Import-PowerShellDataFile -AsHashtable` | 有该参数 | **无该参数** | `NamedParameterNotFound` |
| `ForEach-Object -Parallel` | 支持 | **不支持** | 参数集无法解析（`AmbiguousParameterSet`） |

> 注意： **两条常见误传的更正（本次实测）**：
> - `[Type]::new()` **不是 PS7 专有语法** —— `::new()` 自 PowerShell 5.0 起可用，5.1 实测通过（`[System.Collections.Generic.List[string]]::new()` 两引擎均 exit=0）。
> - `clean { }` 也**不是**独立语句 —— 它只在 PS7 的 `ForEach-Object -Parallel` 内部有意义。独立写 `clean { 1 }`，**两个引擎都报 `CommandNotFoundException`**（5.1 只是不支持 `-Parallel` 这个参数）。

### 2.2 编码语义差异（实测）

| 行为 | pwsh 7 | powershell.exe 5.1 |
| --- | --- | --- |
| `Set-Content -Encoding UTF8` 写出的文件 | **无 BOM**（实测首 3 字节 `68 65 6C`） | **带 BOM**（实测首 3 字节 `EF BB BF`） |
| 读取无 BOM 的 UTF-8 中文文件 | 按 UTF-8 正确解码 | **按系统 ANSI 代码页解码** |
| `-Encoding Byte` | 不存在 | 可用 |

同一条 `Set-Content -Encoding UTF8`，在两个引擎下产出的**字节序列不同**。凡是「A 脚本写文件、B 脚本读文件」且两者可能落在不同引擎上的链路，都必须显式指定 BOM 的有无，不能依赖默认值。

### 2.3 PS7 专有语法在 5.1 下是整段解析失败

用 `[System.Management.Automation.Language.Parser]::ParseInput()` 对同一段代码在两个引擎下各跑一次（实测）：

| 代码 | pwsh 7 | powershell.exe 5.1 |
| --- | --- | --- |
| `$a = $b ?? "x"` | 通过 | 否 `Unexpected token '??' in expression or statement.` |
| `$a ??= "x"` | 通过 | 否 `Unexpected token '??=' in expression or statement.` |
| `$a = $b ? 1 : 2` | 通过 | 否 `Unexpected token '?' in expression or statement.` |
| `[List[string]]::new()` | 通过 | 通过（非差异项） |
| `1..3 \| ForEach-Object -Parallel { $_ }` | 通过 | 语法通过，**运行期**报参数集错误 |
| `clean { }`（独立） | 语法通过，运行期 `CommandNotFoundException` | 同左 |

**为什么这件事严重**：解析失败不是「这一行没生效」，而是**整个脚本一行都不执行**。没有半途状态、没有部分副作用、没有日志 —— 因为连第一行都没跑起来。

---

## 3. 中文脚本在 5.1 下的两种失败（本节为核心）

### 3.1 机制

5.1 读取**无 BOM** 的 `.ps1` 时，按系统 ANSI 代码页解码（本机为 CP936）。UTF-8 编码的汉字是 **3 字节**、全部 `≥ 0x80`；被当成 GBK 解码时，这些高字节会**两两重新配对**，产生两种后果。

### 3.2 后果一：静默乱码（脚本照跑，数据是错的）

| 脚本正文（无 BOM UTF-8） | 高字节数 | 5.1 实测结果 |
| --- | --- | --- |
| `Write-Output '中文'` | 6（偶） | exit=0，输出 **`涓枃`** |
| `Write-Output '中文字符'` | 12（偶） | exit=0，输出 **`涓枃瀛楃`** |

字符串字面量变成乱码，但脚本**正常执行完毕**。这类失败比崩溃更危险：日志里出现的是一串看不懂的字，而不是一条错误。

### 3.3 后果二：整段解析失败（奇数个汉字 + 紧跟 ASCII）

GBK 的**尾字节范围是 `0x40–0x7E`**，其中包含 `'` `"` `#` `$` `\` `` ` `` 等 **ASCII 元字符**。当一行里有**奇数个汉字**，最后一个悬空字节会与其后紧跟的那个 ASCII 字符配成一个「汉字」——**那个 ASCII 字符被吃掉**。

如果被吃掉的是**引号**，字符串就没有终结符，整个脚本解析失败：

| 脚本正文（无 BOM UTF-8） | 高字节数 | 5.1 实测结果 |
| --- | --- | --- |
| `Write-Output '中'` | 3（**奇**） | exit=1，`TerminatorExpectedAtEndOfString`，**无任何输出** |
| `Write-Output '中文'` | 6（偶） | exit=0，乱码 |
| `Write-Output '中文字'` | 9（**奇**） | exit=1，同上 |
| `Write-Output '中文字符'` | 12（偶） | exit=0，乱码 |
| `Write-Output "中"` | 3（**奇**） | exit=1；报错回显中真实源码已变成 `Write-Output "涓?` —— 可以直观看到**闭合引号被吞** |
| `$a = '中'; Write-Output $a` | 3（**奇**） | exit=1，且级联报出 `Missing ')'`、`Missing closing '}'` 等一串假错误 |
| `# 中 abc` / `# 中文字 abc`（注释） | 3 / 9 | exit=0 —— **注释里的悬空字节后面撞上的是 CR（`0x0D`），不是合法尾字节，因此不吞** |

> **这解释了「有的中文脚本照跑、有的全炸」**：决定成败的是**汉字个数的奇偶**与**后面紧跟的字节**，不是「有没有中文」。注释里的中文几乎总是安全的；**字符串字面量里的中文一奇就炸**。

### 3.4 症状指纹与误导性报错

**症状指纹**（用于一眼认出这个病）：

| 指纹 | 说明 |
| --- | --- |
| 计划任务 `LastTaskResult = 1` | 解析失败的标准退出码 |
| **所有日志文件都不生成** | 脚本第一行都没跑，日志逻辑自然没执行 |
| 手工用 `pwsh` 跑同一个脚本**完全正常** | 因为 pwsh 按 UTF-8 读，看不到问题 |
| 报错行号指向**文件末尾** | 实测报错形如 `At <file>:2 char:26 ... The string is missing the terminator: '.'`，指向最后一行，**而真凶在前面几行的中文字符串里** |
| 报错里出现一串**级联的括号不匹配** | 吞掉引号后，解析器的括号栈跟着错位（实测同一次运行报出 `Missing ')' in function parameter list` 与 `Missing closing '}'`） |

### 3.5 环境依赖性（别用「我这台能跑」当结论）

「吞字符」依赖系统 ANSI 代码页是 **DBCS（如 936）**。若 ANSI 代码页是单字节页（如 1252），则只会出现乱码、不会吞字符 —— **同一份脚本在两台机器上表现不同**。

> **机制推断**：反向也成立 —— 在 936 机器上「今天恰好能跑」的脚本，改动一个中文字符的奇偶就可能突然全炸。因此**不要用运行结果反推安全性，要用解析器与字节检查**。

---

## 4. 硬规则

### 规则 1：被计划任务 / 无窗口启动器调用的脚本，必须是「纯 ASCII」或「带 UTF-8 BOM 的中文」

两条路二选一，不要走中间态（无 BOM 的中文）。推荐**纯 ASCII**：它不依赖任何代码页假设，可迁移性最好。

### 规则 2：写盘工具会吃掉 BOM —— 改完必须回补，并做字节校验

许多编辑器 / 补丁工具 / API 在保存时会丢掉文件开头的 UTF-8 BOM。改完中文脚本后回补：

```powershell
$f   = '<脚本路径>'
$txt = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($true)))
```

校验（必须做，不能靠肉眼）：

```powershell
$b = [IO.File]::ReadAllBytes($f)
$hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
"BOM = $hasBom"
```

「声称纯 ASCII」的脚本同样要**字节级扫描**，不能凭印象：

```powershell
$n = 0
foreach ($byte in [IO.File]::ReadAllBytes($f)) { if ($byte -gt 127) { $n++ } }
"non-ASCII bytes = $n"   # 纯 ASCII 脚本此值必须为 0
```

### 规则 3：改完必过两道闸门，且**两种引擎各跑一次**

`node --check` 之于 JS，**PowerShell 解析器**之于 `.ps1`。解析器闸门用 `ParseFile()`，并在 `pwsh` 与 `powershell.exe` 下各执行一次 —— 只在一个引擎下通过不算通过。

```powershell
# check-parse.ps1 —— 纯 ASCII，双引擎可跑
param([Parameter(Mandatory = $true)][string]$ListFile)

$fail  = 0
$paths = [IO.File]::ReadAllLines($ListFile, [Text.Encoding]::UTF8)   # 清单用 UTF-8 读，规避中文路径传参问题
foreach ($p in $paths) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "MISSING $p"; $fail++; continue }

    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$parseErrors)

    if ($parseErrors.Count -gt 0) {
        $fail++
        Write-Host ("FAIL  {0}  ({1} error(s))" -f $p, $parseErrors.Count)
        foreach ($e in $parseErrors) {
            Write-Host ("      L{0}C{1}  {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
        }
    } else {
        Write-Host ("PASS  {0}" -f $p)
    }
}
Write-Host ("VERDICT: {0}" -f $(if ($fail -eq 0) { 'CLEAN' } else { "FAILED ($fail)" }))
exit $fail
```

调用方式（清单文件里一行一个路径）：

```powershell
pwsh            -NoProfile -File check-parse.ps1 -ListFile <UTF8清单>
powershell.exe  -NoProfile -File check-parse.ps1 -ListFile <UTF8清单>
```

### 规则 4：注意： 用正则扫「PS7 专有构造」会假阳性

**字符串内容是数据，不是代码。** 一个补丁脚本里出现 `??=`，很可能它只是**被写入目标文件的 JS 补丁正文**（位于引号或 here-string 内部），与 PowerShell 语法毫无关系。按正则命中就判定「此脚本 5.1 下必炸」会误报。

**最终判据永远是解析器，不是正则。** 正则扫描只能用来**缩小人工复核范围**，不能用来下结论。

### 规则 5：给 5.1 传中文路径时不要用 `-Command`

`-Command` 会把参数再走一次代码页转换；一旦转换出问题，得到的不是「路径找不到」这种正常错误，而是**看起来像语法错误的报错**，把排查方向带偏。

> 证据级别：**现场记录（本次未复现）**。本机在控制台代码页 65001 下，`-Command` 传中文实测正常（`pwsh → 5.1` 与 `cmd → 5.1` 两条路径均正确回显）。该规则的机制与第 3 节同源，在不同代码页环境下成立与否需按现场实测确认；但**清单文件方案本身没有任何代价**，因此照此执行。

**正确姿势**：路径写进一个 UTF-8 清单文件，再用**纯 ASCII** 的检查脚本按 `[IO.File]::ReadAllLines($ListFile, [Text.Encoding]::UTF8)` 读进来（见规则 3 的脚本）。

---

## 5. 两套 API 都要用时的写法

### 5.1 引擎分流骨架

先探测能力，再选路径；PS7 走 `HttpClient`（可并发），5.1 走 `HttpWebRequest`（串行）。

```powershell
$useHttpClient = $false
if ($PSVersionTable.PSEdition -eq 'Core') {
    try { [void](New-Object System.Net.Http.SocketsHttpHandler); $useHttpClient = $true } catch { $useHttpClient = $false }
}

if ($useHttpClient) {
    Add-Type -AssemblyName System.Net.Http          # Core 下亦无害
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.ServerCertificateCustomValidationCallback = [TlsPolicy]::AcceptAll   # 见 5.2
    $client  = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    # 并发：ForEach-Object -Parallel / 线程安全队列
} else {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($s, $c, $ch, $e) $true }  # 5.1 安全
    # 串行：HttpWebRequest
}
```

### 5.2 注意： PS7 的证书校验回调不能用脚本块

**PS7 的证书校验回调在 TLS 握手线程上执行 —— 那里没有 runspace**，用脚本块赋值会抛「此线程中没有可用于运行脚本的运行空间」。必须用 `Add-Type` 编译出**真委托**：

```powershell
if (-not ('TlsPolicy' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
using System.Net.Security;

public static class TlsPolicy {
    public static bool AcceptAll(HttpRequestMessage req, X509Certificate2 cert, X509Chain chain, SslPolicyErrors errors) {
        return true;
    }
}
'@
}
```

**5.1 是同步模型，回调跑在调用线程上，脚本块在那边是安全的**（实测赋值成功）—— 所以这段代码必须**分流**，不能两边写同一份。

> 同一个坑也在 `ContinueWith` 的续体上出现过：任何「在非 PowerShell 线程上回调」的地方，都不能指望脚本块。

### 5.3 类型转换陷阱：左侧强类型整数与字符串拼接

```powershell
$n = [int]3
$s = $n + '/'        # 否 报 InvalidCastFromStringToInteger
```

PowerShell 的 `+` 在**左操作数是强类型整数**时，会把右操作数**转成整数**再相加，而不是转成字符串拼接。

**实测更正**：这一条**不是 5.1 专有**。下列全部形态在 **pwsh 7.6.6 与 5.1 上表现一致**，错误 ID 均为 `InvalidCastFromStringToInteger`：

| 表达式 | 两个引擎的结果 |
| --- | --- |
| `1 + '/'` | 否 `无法将值 "/" 转换为类型 "System.Int32"。错误:"The input string '/' was not in a correct format."` |
| `([int]3) + '/'` | 否 同上 |
| `([int]::Parse('3')) + '/'` | 否 同上 |
| `([string]3) + '/'` | 是 `3/` |

**正确写法**：显式转字符串 —— `([string]$n) + '/'`，或用 `-join` / `-f` 格式化。这条在跨引擎项目里常被误记为「5.1 的毛病」，实际上它只是 PowerShell 的 `+` 语义，与引擎无关。

---

## 6. 变量名坑

**PowerShell 变量名不区分大小写**，且有一批**内置只读变量不能覆盖**：

```
$Home   $Host   $Input   $Args   $Error   $Pid   $PSItem
```

实测（两引擎一致）：

```
var-Home assign  => ERR: SessionStateUnauthorizedAccessException ::
                    无法覆盖变量 HOME，因为它是只读变量或常量。
```

`$Home` 被写进 `param([string]$Home = ...)` 时，**脚本在第 5 行左右直接失败、退出码 1、连日志都来不及写**。

### 6.1 单字母大小写变体也是同一个变量

变量名不区分大小写，**也包括单字母的大小写变体**：`$s` 与 `$S` 是**同一个变量**。

实测（两引擎一致）：

```
$s = 'abc'; $S = @('l1','l2')  →  $s 变成 array，原值 'abc' 被覆盖
```

真实故障形态：脚本里先写了 `$s = '...\state.md'`（路径字符串），后面又用 `$S = [IO.File]::ReadAllLines($s, ...)` 承接行数组 —— `$s` 被覆盖成行数组，下一个 `[IO.File]::WriteAllLines($s, ...)` 便报**「路径太长」**。

> **纪律**：一个脚本里不要用只差大小写的两个变量名。多字词命名（`$statePath` / `$stateLines`）最省心。

### 6.2 症状特征

| 指纹 | 说明 |
| --- | --- |
| 计划任务 `Result = 1` | 与第 3 节的解析失败**症状相同** |
| **所有日志文件都不生成** | 与第 3 节同样的一致特征 |

注意： **「`Result=1` 且没有任何日志」是一个复合指纹**，它同时对应至少三种病：中文编码解析失败、只读变量被覆盖、以及任何「第一行之前就死掉」的原因。排查时**按这三条依次过一遍**，不要只查一条就收工。

---

## 7. `.bat` 的硬规则

本机 `.bat` 正文、**文件名**、**换行符**三者任一不对，cmd 就可能把命令读坏（症状：`'hcp' is not recognized` / `'ocal' is not recognized` / `The syntax of the command is incorrect.`）。

### 规则 1：正文纯 ASCII

cmd 按控制台 / OEM 代码页读取批处理正文。**与第 3 节完全相同的吞字符机制在此同样成立**：奇数个汉字后紧跟 ASCII 字符时，那个 ASCII 字符会被吞掉 —— 落在命令上就是吃掉命令的首字母。

> 证据级别：**机制实测**（第 3 节已确证吞字符机制与奇偶相关）；**具体症状（`chcp` → `'hcp'`、`cd` → `'ocal'`）为现场记录**。本机控制台代码页为 65001，实测 LF/CRLF、UTF-8 无 BOM、UTF-8 带 BOM、GBK 四种写法下的简单批处理**均未复现**吞字符，因此该症状的触发条件与代码页强相关，**照规则做即可，不必复现**。

### 规则 2：`echo` 中文前先 `chcp 65001 >nul`

要显示的中文放在 `echo` 的**参数**里，不要放进文件名或命令名。

### 规则 3：换行必须是 CRLF

用工具写 `.bat` 时若落了 LF，部分 cmd 版本 / 复杂结构（含标签、`goto`、多行括号块）下会出现解析异常。

> 证据级别：**现场记录（本次未复现）**。本机实测 6 种结构（简单 echo ／ `chcp` ／ `cd /d` ／ 括号块 ／ `call`+`goto` ／ `setlocal`）在 LF 与 CRLF 下**行为完全一致**。仍要求写 CRLF 的理由是**确定性**：`.bat` 的规范形式是 CRLF，显式写入可消除跨 cmd 版本的差异风险，且写入成本为零。

写盘姿势（显式 CRLF、无 BOM）：

```powershell
[IO.File]::WriteAllText($p, ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
```

### 规则 4：`.bat` 的文件名不要写中文

> 证据级别：**现场记录（本次未复现）**。本机实测中文文件名（`跑-01.bat`）与中文目录下的 ASCII 批处理**均可正常执行**。仍建议纯 ASCII 文件名，因为批处理常被其他程序（计划任务动作、启动器、`Start-Process`）以字符串方式拼接调用，链路上任何一次代码页转换都可能破坏它。

### 规则 5：工具链相关的**目录名**必须纯 ASCII

这条与文件名相反，**目录名是真的会炸**：gcc 等工具链在链接阶段处理输出路径时对非 ASCII 目录名支持不佳，实测报

```
cannot open output file ...\<乱码>\04-xxx.exe
```

**中文文件名可以、中文目录名不行。**

### 规则 6（实测反例）：`.bat` 不要存成 UTF-16

实测把批处理存成 UTF-16 后执行，cmd 读到的是被拆碎的字节，报

```
'??@' is not recognized as an internal or external command
```

退出码 1，且**第一条命令的首字符被吃掉** —— 这正是「吞字符」类症状里可以稳定复现的一种。

---

## 8. 自查清单

改完任何面向计划任务 / 启动器的脚本后，逐条跑：

| # | 检查项 | 判据 |
| --- | --- | --- |
| 1 | 非 ASCII 字节计数 | 纯 ASCII 脚本必须为 **0** |
| 2 | BOM 前 3 字节 | 中文脚本必须是 `EF BB BF` |
| 3 | 解析器闸门（`pwsh`） | `ParseFile()` 报 0 错 |
| 4 | 解析器闸门（`powershell.exe`） | 0 错 —— **不能只跑一个引擎** |
| 5 | 声明为「只读」的任务 | `RunLevel` 不应为 `Highest` |
| 6 | 实际执行一次 | 回读退出码 **与副作用**（日志文件是否真的生成） |
| 7 | 变量名扫描 | 无只差大小写的成对变量；无 `$Home` / `$Host` / `$Input` / `$Args` / `$Error` / `$Pid` / `$PSItem` 被赋值 |

---

## 9. 已知限制与未解决

1. **吞字符机制依赖 DBCS 代码页**。本机为 CP936；在单字节 ANSI 代码页（如 1252）的机器上，第 3.3 节的解析失败不会出现，只会出现乱码。**结论的可迁移边界到此为止** —— 其它代码页下应重新跑一遍第 3.3 节的对照表。
2. **第 3.3 节的对照表只覆盖了「引号」这一种被吞的字符**。理论上 `#` `$` `\` `` ` `` 等同样落在 GBK 尾字节范围内的字符也应被吞，本次未逐一实测，属**机制推断**。
3. **规则 3（CRLF）与规则 7.1 / 7.4 的具体症状未被复现**，仅保留为防御性规范。它们零成本，但不应被引用为「已实测的 cmd 缺陷」。
4. **规则 5（`-Command` 传中文）未复现**。本机在控制台代码页 65001 下两条调用路径都正常；该规则的最初现场记录缺少代码页信息，无法判定触发条件。
5. **`clean { }` 与 `[Type]::new()` 的两处常见误传已更正**（第 2.1 节），但该结论基于本机两个具体版本（7.6.6 / 5.1.26100.9444），更老的版本未验证。
6. **第 5.2 节的证书回调方案未经真实 TLS 握手验证**。本机只验证了「5.1 下脚本块可赋值 / PS7 下必须用真委托」这一半，接受任意证书的连接行为未做端到端测试。
7. **`ParseFile()` 闸门只查语法**。它能抓住「整段解析失败」这一类，但抓不住运行期错误（未定义引用、类型错误、TDZ 类问题）。语法绿灯不等于能跑，第 8 节第 6 项（实际执行 + 回读副作用）不可省略。
