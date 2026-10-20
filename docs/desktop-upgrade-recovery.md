# 桌面客户端升级后配置层被重置：一条完整的事故链

> 场景：基于 Electron 的桌面应用，插件化架构，profiles 下的补丁层（`cordis.patch.yml`）承担插件挂载与服务注入。
> 升级后出现：补丁层从 11.9 KB 变成 827 B、插件全部不加载、旧会话报「模型无适配器」、新会话沙箱设置失败。
>
> 分档：本文所有「实测」均有文件尺寸、SHA256、日志或时间戳可复核；推断处单独标注。

## 一、先看结论

爆出来的三个症状不是三个 bug，是
**一个插件带了旧版服务的硬依赖 → 启动审计判 fatal → 客户端「安全恢复」把补丁层改名重置 → 客户端在空档上写回自己的默认设置**。

把它当「配置被覆盖」修，只能治标：补回补丁层后，下次重启还会被同一个插件拖崩。

## 二、事故链（每一步都有证据）

| # | 事件 | 证据 |
| --- | --- | --- |
| 1 | 升级后首次启动，配置仍是好的 | 补丁层 11,903 B；插件已加载 |
| 2 | 某插件（版本 A）的补丁声明 `inject: [webRuntime, webServer]` | 该插件包内 `cordis.patch.yml` |
| 3 | 新版核心删除了 `webRuntime` 服务 | 新版 asar 内全量搜索无此字符串 |
| 4 | `connection` 插件永远不激活（它依赖 webRuntime） | 崩溃报告：`1 required plugin did not activate`，表里 `connection (required) → webRuntime` |
| 5 | Host 启动审计判 fatal，客户端弹「禁用全部插件」恢复 | 崩溃日志（`%APPDATA%\<app>\logs\crash-*-host.log`） |
| 6 | `sanitizeProfile` 把补丁层改名备份，bundles 重置成 web 模板 | 备份文件名 `.bak-<毫秒时间戳>`，毫秒值正是 `Date.now()` |
| 7 | 客户端在空档上写回 UI 默认设置（账号/聊天/默认模型） | 补丁层变成 827 B，CreationTime 与重置同时刻 |

## 三、排查手法（可复用到其他插件化应用）

### 1. 先分清「谁写的」

对比文件大小与 SHA256，再找同目录的备份：

```powershell
Get-ChildItem <profile> -Filter 'cordis.patch.yml*' | Select Name, Length, CreationTime, LastWriteTime
Get-FileHash <profile>\cordis.patch.yml
```

- 应用自己的配置写入会留 `.bak-<毫秒>`；
- 第三方或恢复流程的重置不会留（或只改名为 `.clobbered-*`）。
- **`.bak-<13 位数字>` 的毫秒值可以直接还原成时刻**，用它对齐日志。

### 2. 崩溃报告比应用日志有用

Electron 应用的 host 进程崩溃报告一般在 `%APPDATA%\<app>\logs\crash-*.log`，里面会写明「哪个必需插件没激活」以及它等的服务名。这比翻应用日志快得多。

### 3. 把「插件声明的服务名」和「核心实际提供的服务名」对表

```powershell
# 插件侧
Select-String -Path <plugin>\cordis.patch.yml -Pattern 'inject|name:'
# 核心侧：asar 里搜字符串
npx asar extract <app>\resources\app.asar <tmp>
Select-String -Path <tmp>\**\*.js -Pattern 'webRuntime' -SimpleMatch
```

没有 `asar` 工具时，Electron 自己就能读：`ELECTRON_RUN_AS_NODE=1 <app.exe> <script.mjs>`（见 `win-agent-tools/extract-presets.mjs` 的做法）。

### 4. 用临时 profile 预演，不动真环境

官方 CLI 的 `--dump-config` 可以打印合成后的配置树：

```bash
<app> --profile <test-profile> --dump-config
```

判据：必需插件行全部进入合成树、没有 `skip`；确认后再改真 profile。冒烟启动用 `--port 0 --no-open`，能起来且无 fatal 审计即通过。

## 四、恢复步骤（固定顺序）

1. **恢复补丁层**：从 `.bak-*` 拷回，回读 SHA256 与备份一致。
2. **修根因**：把肇事插件升级到兼容版本（`engines` 要覆盖当前核心版本）；确认新版的补丁不再引用已删除的服务。
3. **同步锁文件**：importer / packages / snapshots 三处都要更新，`grep` 确认旧版本号 0 残留。
4. **重抽内置预设**：升级后 `app.asar` 里的预设文件会变，镜像不刷新会导致后续「按旧清单比对」误删配置。
5. **同步预算/覆盖块**：依赖内置预设 id 的覆盖块要重新生成。
6. **重启并核对**：boot manifest 条数、插件脚印时间戳前进、`--dump-config` 无 skip。

每一步都要回读。**「脚本打印成功」不算证据。**

## 五、四个会反复踩的坑

| 坑 | 现象 | 判据 |
| --- | --- | --- |
| **端口不再固定** | 升级脚本等固定端口 240 s 超时，后续步骤整段跳过 | 新版可能每次启动随机端口；一律从 runtime 文件/进程参数读实际端口，不要探固定端口 |
| **pnpm 最小发布冷却** | 新版本装不上（`minimumReleaseAge`） | 报错里会写明发布时间不足；要么等，要么在 workspace 配置的排除名单里显式放行该版本 |
| **PowerShell 变量大小写** | 路径变量被循环变量覆盖，拼出 `System.Diagnostics.Process(...)\package.json` | PowerShell 变量名不区分大小写；**不要用单字母变量**，路径变量用 `$ProfileDir` 这类全名 |
| **`Copy-Item` 保留 mtime** | 靠文件时间判断「热重载生效」时误判 | 需要看时间前进时手动 `touch`，或改看内容哈希 |

## 六、长期建议

- 恢复流程要**先落一份「最近正常配置」再重置**，否则每次崩溃都只能在空档上补默认值。
- 升级前把「当前 profile 补丁层 + 锁文件 + 预设镜像」三件一起存快照，出了问题能一次回到可用点。
- 插件升级要看 `engines` 字段，不看 README；补丁里引用的服务名属于内部契约，随时可能被删。
