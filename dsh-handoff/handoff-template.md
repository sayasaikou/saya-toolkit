# 交接文件（HANDOFF）

> **本文件由脚本生成，别手改** —— 手改会在下次 render 时被覆盖。
> 要改内容 → 改数据源 `{{STATE_PATH}}` → 再说一句"**刷新交接文件**"。
>
> **生成时间**：2026-09-12 18:14 首版 ｜ **最后更新**：{{NOW}}
> **机器核对**：`CHECKED_AT: {{CHECKED_AT}}` —— 这一行是**"核对过了"的凭据**（脚本实测后写入）。它比本文件的修改时间新＝这次核对覆盖了当前内容；一旦过期脚本会自己报警，不用你记。
> **用法**：新会话开头说一句「**读交接文件**」，助手读完即可接续，你不需要重讲背景。
> **完整档案**（人格、规则、用户档案、设备、系统改动台账）在 `$env:DSH_HOME\AGENTS.md`，新会话自动加载。

---

## 0. 当前状态一句话

{{STATUS_LINE}}

---

## 1. pending items（按优先级）

{{PENDING}}

---

## 2. 系统状态实测（脚本每次核对时重新测，**不是回忆**）

| 核对项 | 实测值 |
| --- | --- |
| 机器核对时间 | {{CHECKED_AT}} |
| 人格插件自检 | **{{PERSONA_PASS}}/{{PERSONA_TOTAL}} 项通过**{{#16}}（**有 {{PERSONA_FAIL}} 项 FAIL**）{{/16}} ｜ 规格 {{SPEC_CHARS}} 字符 ｜ 加载脚印 {{PERSONA_STAMP}}（{{PERSONA_AGE}} h 前）{{#64}} **⚠ 脚印偏旧，服务可能很久没重启**{{/64}} |
| 前端 boot 清单 | {{BOOT_COUNT}} 条 ｜ 缺失插件 {{BOOT_MISSING}} 个 {{BOOT_MISSING_LIST}} |
| 女仆skin flags | {{SKIN_LAYERS}} 层 ｜ 未启用 {{SKIN_BAD}} 层 |
| meme library | {{MEME_COUNT}} 张（custom {{MEME_CUSTOM}} 张） |
| Node 解释器 | `{{NODE_PATH}}`（{{NODE_VER}}） |
| 数据源（活档案） | `{{STATE_PATH}}` |

**计划任务**

| 任务 | 存在 | 状态 | 下次运行 |
| --- | --- | --- | --- |
{{TASK_ROWS}}

{{#2}}> ✓ all monitored scheduled tasks present{{/2}}

**skin flags明细**

| 层 | 文件 | disabled |
| --- | --- | --- |
{{SKIN_ROWS}}

**关键文件（时间戳即证据）**

| 文件 | 大小 | 最后修改 | 距今 |
| --- | --- | --- | --- |
{{FILE_ROWS}}

**档案族（谁比谁新，脚本据此判断漂移）**

| 文件 | 位置 | 大小 | 最后修改 |
| --- | --- | --- | --- |
{{ARCHIVE_ROWS}}

**check warnings**{{#1}}（**本次 {{WARN_COUNT}} 条，见下**）{{/1}}

{{#1}}{{WARNINGS}}{{/1}}{{#128}}无（全部核对项一致）{{/128}}

**漂移详情**：{{#32}}本文件落后于别的档案、或机器核对已超期（核对距今 {{CHECK_AGE_HOURS}} h，本文件与全局档案差 {{STALE_HANDOFF_HOURS}} h）—— **rerun 一次本脚本（不带 -Check）即可消除**。{{/32}}{{#128}}无 —— 本文件比所有档案新，机器核对也没超期。{{/128}}

---

## 3. 已完成的conclusions（**别重复排查**）

{{DONE}}

---

## 4. 已suspended（主动叫停 —— **别催、别再提**）

{{SUSPENDED}}

---

## 5. 路径速查（**脚本逐条验存活**）

| 指针 | 路径 | 存活 |
| --- | --- | --- |
{{POINTER_ROWS}}

| 用途 | 路径 |
| --- | --- |
| 全局档案（规则 / 人格 / 设备 / 台账） | `$env:DSH_HOME\AGENTS.md` |
| 工作区说明与文件清单 | `$env:DSH_WORKSPACE\AGENTS.md` |
| 交接机制三件套 | `$env:DSH_HOME\handoff\`（state / template / check.ps1） |
| 重启服务 / 装插件 | `$env:DSH_HOME\dsh-restart.ps1` / `install-plugins-20260917-v10.ps1` |
| launcher 主日志（插件脚印最全） | `$env:DSH_HOME\dsh-launcher\dsh.log` |

---

## 6. 交接机制怎么运转（防止本文件再次变旧）

| 环节 | 机制 |
| --- | --- |
| 数据源唯一 | 未结 / conclusions / suspended只写在 `handoff-state.md`，本文件由脚本渲染 → 不可能"两处事实打架" |
| 事实不靠嘴说 | 插件是否加载、皮肤开没开、任务在不在、指针有没有失效、文件多久没动 —— `handoff-check.ps1` **实测**并打上 `CHECKED_AT` |
| 漂移会自己叫 | 本文件比任何档案旧 / 核对超 24 h / 指针失效 / 插件掉出 boot 清单 / 皮肤被关 / 任务丢失 → 报 warning，并写进上面的「check warnings」栏 |
| 定期自检 | 计划任务 `DSH_HandoffCheck` 每 30 分钟只读跑一次（日志 `handoff-check.log`）；**它写不了本文件，只提醒** |
| 会话纪律 | 开场跑一次 `-Check`；收尾按 **改 state → render → 再 `-Check`** 复核。顺序反了脚本会报"HANDOFF 比 state 旧" |
| 编码坑 | **脚本正文纯 ASCII**（计划任务用 PS 5.1，会把无 BOM 的 UTF-8 当 ANSI 读 → 中文乱码 → 解析失败、退出码 1、连日志都不写）；**所有中文文案只在本模板里** |

> 踩过的坑（别再踩）：改 `PERSONA_SPEC` 正文**不能出现反引号**（JS 模板字符串会被提前闭合）；改完必跑 `node --check` + `check.mjs` + `spec-audit.mjs` 三连。
