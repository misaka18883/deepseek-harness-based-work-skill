# deepseek-harness-based-work-skill

面向 [DeepSeek Harness](https://github.com/deepseek-ai) 的**工作技能**集合。

这里放的不是"能装多少插件"，而是**开工第一步就能把环境拉回可用状态**的那类技能——
判据明确、零成本自检、可跨版本迁移、坏了能回滚。

## 包含的技能

| 技能 | 作用 |
| --- | --- |
| [`dsh-env-bootstrap`](skills/dsh-env-bootstrap/SKILL.md) | 开工先体检 DSH 工作插件环境：只读校验 → 幂等补齐 → 快照迁移。清单是唯一事实源，脚本是执行器 |

## 安装

### 方式一：技能市场（推荐）

在 DSH 的「设置 → 技能 → 市场」里把这仓库加为源，扫描后勾选安装。
本仓库按市场约定布局（`<任意目录>/<技能名>/SKILL.md`），会被自动发现。

### 方式二：手动复制

```powershell
# 项目级（只对当前工作区生效）
Copy-Item -Recurse skills\dsh-env-bootstrap "<你的工作区>\.dsh\skills\"

# 用户级（所有项目生效）
Copy-Item -Recurse skills\dsh-env-bootstrap "$env:USERPROFILE\.dsh\skills\"
```

装好后 DSH 会自动识别，技能名即目录名。

## 用法

```bat
cd "<skills-root>\dsh-env-bootstrap"
run-env.cmd verify         :: 只读体检：零网络、零 token。绿了就是什么都不用装
run-env.cmd export         :: 导出实际环境快照，并与基线清单 diff
run-env.cmd apply          :: 幂等补齐缺失的插件 / bundle / patch 条目（先加 -DryRun 预览）
```

`verify` 退出码：`0` 环境可用 ｜ `1` 有必检项失败 ｜ `2` 环境不可判定。

## 设计原则

1. **清单里不出现绝对路径，也不出现 DSH 版本号。** 出现即视为缺陷。
2. **分层表达可迁移性**：`host`（桌面外壳 `link:` 包，不可迁移，只探测）／`core`（官方 bundle，跟随升级）／`work`（用户插件，包名 + semver，迁移时唯一要重建的）／`patch`（`cordis.patch.yml` 覆盖条目，按 id 幂等追加）。
3. **一切动手前先备份**到 `%DSH_HOME%\.plugin-backups\env-bootstrap-<时间戳>\`。
4. **只走官方稳定接口**：`dsh plugin --profile <p> add`、`--dump-config`、`--from-default-profile`。
5. **脚本保持 ASCII-only**：Windows PowerShell 5.1 按 ANSI 读 `.ps1`，非 ASCII 会在别的代码页机器上把脚本解析坏（已实测）。中文说明一律放 `.md`。

## 环境要求

- Windows + Windows PowerShell 5.1（或 PowerShell 7）
- DSH 已安装，且目标 profile 已存在
- 无需管理员权限；`run-env.cmd` 用 `-ExecutionPolicy Bypass` 启动，**不改机器策略**

## 已知限制

- `host` 层的 `dsh-tauri*` 用 `link:` 写死本机绝对路径，**换机器必然失效**，由桌面安装器重新注入；`verify` 只探测、不计失败。
- `dsh plugin add` 只等于 pnpm 安装，**不会**自动挂进 `dsh.profile.bundles`；`apply` 会额外补 bundles。*（此结论为推断，未在真机安装路径上端到端验证）*
- 在 DSH 会话沙箱（`workspace-write`）内 `apply` 会因写 `%DSH_HOME%` 被拒；请在普通终端或 GUI 插件页执行。`verify` / `export` 只读，随时可用。

## 许可

未指定。使用前请自行确认。
