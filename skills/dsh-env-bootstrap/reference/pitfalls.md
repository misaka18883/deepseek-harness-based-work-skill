# 坑位速查 + 迁移缺陷修法

> 每条都标注了**证据强度**：`实测` = 本会话真跑过并留有输出；`推断` = 基于帮助文本/文件结构，尚未在真机安装路径上验证。

## A. 执行层

| # | 坑 | 证据 | 处置 |
| --- | --- | --- | --- |
| A1 | `ExecutionPolicy = Restricted`，`dsh.ps1` 加载失败 | 实测：`File ...\dsh.ps1 cannot be loaded because running scripts is disabled on this system` | 用 `dsh.cmd`；脚本用 `run-env.cmd`（内部 `-ExecutionPolicy Bypass`），不改机器策略 |
| A2 | 本机只有 Windows PowerShell **5.1**，无 `pwsh` | 实测：`The term 'pwsh' is not recognized`；`$PSVersionTable.PSVersion = 5.1.26100.8115` | 启动器先探测 `pwsh`，没有就回退 `powershell` |
| A3 | PS 5.1 按 ANSI 读 `.ps1`，中文注释被破坏 → 语法错误 | 实测：带中文的 `verify-env.ps1` 报 `Unexpected token 'unknown'`、`Missing closing ')'` | **脚本强制 ASCII-only**；要中文就先写入 UTF-8 BOM |
| A4 | `dsh plugin list` 必须带 `--profile` | 实测：`error: required option '--profile <name>' not specified` | 统一写 `dsh plugin --profile <name> ...` |
| A5 | 多行 PowerShell 命令在 `pwsh -Command` 下易被解析坏 | 实测：一条复合命令里 `dsh` 与后续语句混排时解析异常 | 一条命令只干一件事，或落成 `.ps1` 文件跑 |
| A6 | PS 5.1：`[pscustomobject][ordered]@{ k = @($genericList) }` 抛 `Argument types do not match` | 实测（最小复现）：`New-Object System.Collections.Generic.List[object]` 后取 `@($list)` 作为字典值即失败；`.ToArray()`、原生 `+=` 数组、直接放 `$list` 都正常 | 泛型 List 转数组一律用 `.ToArray()`，别用 `@($list)` |

## B. 沙箱层

| # | 坑 | 证据 | 处置 |
| --- | --- | --- | --- |
| B1 | 会话沙箱是 `workspace-write`，写 `%DSH_HOME%` 被拒 | 实测：`EPERM: operation not permitted, open 'C:\Users\...\.dsh\profiles\web\cordis.yml'`（`@deepseek-ai/dsh` 的 `prepareProfile`） | `apply` 在普通终端 / GUI 插件页跑；`verify`、`export` 只读，沙箱内可用 |
| B2 | 管道捕获别的进程输出 → `spawn EPERM` | 仓库 `smoke/BRIEF.md` 记录（原生 exe 的管道 spawn；纯 Node/Python 子进程不受影响） | 不要"换个写法重试"；`apply-env.ps1` 不捕获 `dsh` 输出，只看 `$LASTEXITCODE` |
| B3 | 沙箱内 `curl.exe` / `Invoke-RestMethod` 被拦（schannel `SEC_E_NO_CREDENTIALS`） | 仓库 `smoke/BRIEF.md` 记录 | 需要网络时用 `node -e "fetch(...)"` 或 `pnpm` |
| B4 | 期望内的限制不要当故障修 | 官方 `diagnose-windows-sandbox-acl` 技能说明 | 只有"本该可读/可写却失败"才怀疑 ACL |

## C. 结构与迁移

| # | 坑 | 证据 | 处置 |
| --- | --- | --- | --- |
| C1 | `dsh plugin add` ≈ pnpm 安装，**不会**自动挂进 `dsh.profile.bundles` | 推断：`dsh --help` 写作 `dsh plugin --profile <name> <pnpm-args...>`；挂载信息在 `package.json` 的 `dsh.profile.bundles` | `apply-env.ps1` 额外补 `bundles`；迁移后用 `verify` 确认 `inBundles` |
| C2 | `link:` 依赖写死绝对路径（`dsh-tauri*` 10 个） | 实测：`link:C:/Users/misaka.HUAWEI/AppData/Local/Deepseek Harness Desktop/resources/node_modules/dsh-tauri` | 归入 `host` 层，不迁移；由桌面安装器重新注入 |
| C3 | `minimumReleaseAgeExclude` 残留已卸载的包 | 实测：`@xmanrui/dsh-im@4.30.0`、`dsh-better-sidebar@0.24.1` 在豁免表里但不在 `dependencies` 里 | 看 diff 时以 `dependencies` 为准；确认无用可手工清 |
| C4 | `cordis.yml` 是自动生成的空根，手改会被覆盖 | 文件头自述：`Edit cordis.patch.yml, not this file.` | 只改 `cordis.patch.yml` |
| C5 | bundle 是**有序**数组，顺序即加载顺序 | 实测：`dsh.profile.bundles` 里 `dsh-base` → `dsh-web-app` → 外壳 → 市场 → 其它 | `apply` 只在**末尾追加**，不重排 |
| C6 | `office-xlsx/SKILL.md` 末尾「本机接线」段含绝对路径 | 实测：第 84 行 `C:\\Users\\misaka.HUAWEI\\...` | 见下方 D 节 |

## D. `office-xlsx` 的迁移缺陷与修法

现状：`<workspace>\.dsh\skills\office-xlsx\SKILL.md` 第 76–89 行是一段「本机接线（本地追加，非官方原文）」，硬编码了：

- `python` 在 PATH（这条本身没问题）
- LibreOffice Kit 的 `node` / `cli` **绝对路径**（`C:\Program Files\nodejs\node.exe` + `C:\Users\<user>\AppData\Roaming\dsh-tauri\dependencies\dsh\node_modules\@deepseek-ai\libreoffice-kit\lib\cli.js`）

换机器/换用户/换 DSH 安装位置后这段即失效，且技能正文照样会照它执行。

**推荐改法（不改正文语义，只把"本机事实"外置）：**

1. 新建 `<workspace>\.dsh\skills\office-xlsx\local.json`（**加入版本控制的就是模板**）：

   ```json
   {
     "python": "python",
     "libreofficeKit": { "node": "$NODE", "cli": "$DSH_HOST/node_modules/@deepseek-ai/libreoffice-kit/lib/cli.js" }
   }
   ```

2. 把 `SKILL.md` 里的绝对路径段改成一句指引：

   > 本部署未挂载官方 office 插件，`Installed LibreOffice Kit` 段不会自动注入。
   > 运行前先读本技能目录下的 `local.json` 取 `node` / `cli`；
   > 其中 `$NODE` = `(Get-Command node).Source`，`$DSH_HOST` = `%APPDATA%\dsh-tauri\dependencies\dsh`。

3. 需要时让 `dsh-env-bootstrap` 负责生成实际的 `local.json`（本技能已能算出这两个路径）。

这样正文保持可迁移，机器相关事实收敛到一个可重新生成的 JSON。

## E. 快速自检清单

开工前 5 秒过一遍：

- [ ] `run-env.cmd verify` 退出码 0
- [ ] `DSH_PROFILE` 与预期一致（本机 `tauri`）
- [ ] GUI `http://127.0.0.1:3080` 打得开
- [ ] 技能目录里能看到本工作区需要的技能（当前：`office-xlsx`、`dsh-env-bootstrap`）
- [ ] 上一个 `env-bootstrap-*` 备份还在（回滚用）
