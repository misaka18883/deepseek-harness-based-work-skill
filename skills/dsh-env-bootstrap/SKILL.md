---
name: dsh-env-bootstrap
description: 开始工作时先把 DSH 工作插件环境配置成「可用、可迁移、可回滚」的状态。当用户说"配置工作环境 / 插件环境"、"开始工作前先准备环境"、"迁移到新版本 DSH / 换机器"、"插件没装 / 技能不见了 / 环境坏了"、"检查一下环境"时使用。先跑零网络只读校验，只在缺件时幂等补齐；用 export 快照跨版本 diff，避免每次重装。
---

# DSH 工作插件环境引导（dsh-env-bootstrap）

**一句话**：先诊断，再补齐；清单是事实源，脚本是执行器；任何动作都可回滚。

## 什么时候用

- 用户说「开始工作 / 先配置环境 / 插件环境」→ 跑 `verify`，把结果当作开工前的体检报告。
- 换机器、升级 DSH、重装桌面端之后 → `export` 对比基线，再决定要不要 `apply`。
- 插件突然不生效、技能列表空了、GUI 缺页签 → `verify` 定位到具体哪一层坏了。

**不要**用它来：删插件（用 `dshmarket` 或 GUI 插件页）、改模型/provider 凭据（用设置页）、装与本清单无关的新插件（先加进清单再 apply）。

## 30 秒流程

```bat
cd "<本技能目录>"          :: 即 <workspace>\.dsh\skills\dsh-env-bootstrap
run-env.cmd verify        :: 只读体检。绿=环境可用，什么都不用装
run-env.cmd export        :: 导出实际环境快照 + 与基线 diff
run-env.cmd apply -DryRun :: 预览要补什么
run-env.cmd apply         :: 真的补齐（幂等，只动缺失项）
```

`apply` 会先备份 `package.json` / `cordis.patch.yml` 到 `%DSH_HOME%\.plugin-backups\env-bootstrap-<时间戳>\`。

## 分层模型（这是它能迁移的原因）

清单 `reference/env-manifest.json` 把环境拆成四层，每层的可迁移性不同：

| 层 | 内容 | 迁移性 | 怎么处理 |
| --- | --- | --- | --- |
| `host` | `dsh-tauri*` 等 10 个包 | ❌ 不可迁移 | 用 `link:` 写死本机绝对路径，由桌面安装器在新机器重新注入。只探测、不修复、不算失败 |
| `core` | `@deepseek-ai/dsh-base`、`dsh-web-app`、experimental-* | ✅ 免费跟随 | **不写版本号**，跟着 DSH 升级走 |
| `work` | `dshmarket`、`dsh-skill-hub`、`dsh-excel-chat`… 共 8 个 | ✅ 包名 + semver | 迁移时唯一需要重建的部分 |
| `patch` | `cordis.patch.yml` 里的覆盖/禁用条目 | ✅ 纯文本 | 按 `id` 幂等追加，不覆盖已有条目 |

**核心原则：清单里永远不出现绝对路径，也不出现 DSH 版本号。** 出现即视为缺陷。

## 环境事实（本机实测，2026-09-29）

| 项 | 值 |
| --- | --- |
| `DSH_HOME` | `C:\Users\<user>\.dsh` |
| `DSH_PROFILE` | `tauri`（profile 目录 `%DSH_HOME%\profiles\tauri`） |
| Web GUI | `http://127.0.0.1:3080` |
| DSH 启动器 | `%LOCALAPPDATA%\deepseek-harness\bin\dsh.cmd` |
| DSH 宿主 | `%APPDATA%\dsh-tauri\dependencies\dsh`（只读参考） |
| pnpm | `%APPDATA%\dsh-tauri\dependencies\pnpm\bin\pnpm.cjs` |
| Node / Python | v24.21.0 / 3.14.3（openpyxl 3.1.5、pandas 3.0.5） |
| 技能根 | 项目级 `<workspace>\.dsh\skills\`；用户级 `%DSH_HOME%\skills\` |

Profile 的三个文件，分工别搞混：

- `package.json` → `dependencies`（装了什么）+ `dsh.profile.bundles`（**加载**什么，有序）
- `cordis.patch.yml` → 用户覆盖层，官方 bundle 之后应用；**只改这个文件**，别改 `cordis.yml`（自动生成的空根）
- `pnpm-workspace.yaml` → `minimumReleaseAgeExclude` 等供应链策略

## 已知坑（都有实测证据，别重复踩）

1. **`ExecutionPolicy = Restricted`，`dsh.ps1` 直接跑不了。**
   实测报错：`File ...\dsh.ps1 cannot be loaded because running scripts is disabled`。
   → 一律走 `dsh.cmd`，或 `powershell -ExecutionPolicy Bypass -File`。`run-env.cmd` 就是干这个的。
2. **本机是 Windows PowerShell 5.1，没有 `pwsh`。**
   且 PS 5.1 按 **ANSI** 读 `.ps1`（除非带 UTF-8 BOM）。
   → 本技能所有脚本**强制 ASCII-only**。加中文注释会在别的代码页机器上把脚本解析坏（已实测踩过）。要加中文就先补 BOM。
3. **`dsh plugin` 必须带 `--profile`。** 不带会报 `required option '--profile <name>' not specified`。
4. **会话沙箱里跑不了 `apply`。** 当前策略是 `workspace-write`，写 `%DSH_HOME%` 会被拒（实测 `EPERM ... cordis.yml`）。
   → `apply` 在**普通终端**跑，或改用 GUI 的「插件」页。`verify` / `export` 是只读的，沙箱里随时能跑。
5. **沙箱里用管道捕获子进程输出会 `spawn EPERM`。**
   → `apply-env.ps1` 故意不捕获 `dsh` 的输出，只看 `$LASTEXITCODE`。别"换个写法重试"。
6. **`dsh plugin add` 只等于 pnpm 安装，不会自动挂进 `dsh.profile.bundles`。**
   `dsh --help` 明说 `dsh plugin --profile <name> <pnpm-args...>`，而挂载信息在 `package.json` 的 `dsh.profile.bundles` 里。
   *（推断，未在真机安装路径上验证过）* → `apply` 因此会**额外**把包名补进 `bundles`；迁移后请用 `verify` 确认 `inBundles` 为真。
7. **`link:` 依赖写死绝对路径**，例如 `link:C:/Users/<user>/AppData/Local/Deepseek Harness Desktop/resources/node_modules/dsh-tauri`。
   换机器/换用户名/换安装目录即断。这是不可迁移层，交给安装器。
8. **`minimumReleaseAgeExclude` 会残留已卸载的包**（本机就残留了 `@xmanrui/dsh-im`、`dsh-better-sidebar`）。
   无害，但会让 diff 变吵 —— 看 diff 时以 `dependencies` 为准。
9. **`.dsh/skills/office-xlsx/SKILL.md` 末尾的「本机接线」段写着绝对路径**（python 路径 + LibreOffice Kit 的 node/cli）。
   这是当前唯一一处**内容级**迁移缺陷；见 `reference/pitfalls.md` 的改法。

## 迁移到更高版本 DSH（标准动作）

```bat
:: ① 旧环境：留基线
run-env.cmd export -Out baseline-env.json

:: ② 升级 DSH / 换机器 / 重装桌面端

:: ③ 新环境：再导一次，脚本自动打印差异（新增/移除的插件、bundle、patch 条目）
run-env.cmd export -Baseline baseline-env.json

:: ④ 差异合理 → 提升为清单，然后补齐
::    （把要长期保留的变更合进 reference/env-manifest.json）
run-env.cmd apply -DryRun
run-env.cmd apply
run-env.cmd verify
```

升级后回归三件事：`verify` 全绿、GUI 能打开 `http://127.0.0.1:3080`、`dshmarket` / 技能页能正常列出内容。

## 回滚与救援

| 情况 | 动作 |
| --- | --- |
| `apply` 装坏了 | 从 `%DSH_HOME%\.plugin-backups\env-bootstrap-<时间戳>\` 拷回 `package.json` + `cordis.patch.yml` |
| 想卸掉某个插件 | GUI 插件页 / `dshmarket` 卸载（会同步 `dependencies` 与 `bundles`），然后 `verify` 会如实报失败 |
| profile 整个坏了 | 用官方救援：`dsh rescue --from-default-profile web`（从出厂模板新建 profile 再启动） |
| 只想看当前合成树 | `dsh --profile tauri --dump-config` |

## 成本纪律（为什么它便宜）

- `verify` = 纯本地文件读取，**零网络、零 token**。先跑它，绝大多数时候结论是"什么都不用装"。
- `apply` 幂等：已就位的包直接跳过，不打网络。
- `export` 只读 profile 目录，不发请求。
- 清单里的默认模型固定在 `deepseek-flash`（见 `patch` 层的 `agent-default-model`），子代理模型走白名单 —— 防止迁移后被默认路由到高价模型。
- 需要重装时才加 `-PreferOffline` 复用 pnpm store。

## 文件清单

| 路径 | 作用 |
| --- | --- |
| `SKILL.md` | 本文件：判据、坑、流程 |
| `reference/env-manifest.json` | **唯一事实源**：分层清单 + patch 条目（人工维护） |
| `reference/env-manifest.exported.json` | `export` 的产物（自动生成，勿手改） |
| `reference/pitfalls.md` | 坑位速查 + `office-xlsx` 迁移缺陷的修法 |
| `scripts/verify-env.ps1` | 只读校验，退出码 0/1/2 |
| `scripts/export-env.ps1` | 导出实际环境 + 与基线 diff |
| `scripts/apply-env.ps1` | 幂等补齐（`-DryRun` 预览） |
| `run-env.cmd` | 绕开 ExecutionPolicy 的启动器 |

## 维护约定

1. **脚本保持 ASCII-only**，中文只出现在 `.md` 里。
2. **清单里不写绝对路径、不写 DSH 版本号。**
3. 新增插件 → 先补 `layers.work.packages`（含 `role` 与 `why`）→ 再 `apply` → 再 `verify`。
4. **已知无害的引导态/UI 偏好 patch 条目写进 `patchIgnore`，不要塞进 `patch`**（否则每次 `export` 都会报漂移，diff 一旦变吵就没人看了）。
5. 每季度或每次大版本升级，跑一次 `export` 并把有意义的变更提升进清单。
6. 本技能是**工作区级**的。想全项目通用：整个目录复制到 `%DSH_HOME%\skills\dsh-env-bootstrap\`（用户级技能根），脚本里对技能根的两级布局都能自适应。
