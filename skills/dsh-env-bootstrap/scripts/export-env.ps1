<#
  export-env.ps1 -- export a machine-independent snapshot of the LIVE environment.

  Migration workflow (this is the "migrate to a higher DSH version" tool):
    1) export on the old environment  -> baseline
    2) upgrade DSH / move to a new machine
    3) export again                   -> script prints the diff vs the baseline
    4) only if the diff is meaningful, promote it into reference/env-manifest.json
       and run apply

  Default output is reference/env-manifest.exported.json. The curated
  reference/env-manifest.json is NEVER overwritten.

  ASCII-only on purpose (see verify-env.ps1 header).

  Usage:
    run-env.cmd export
    run-env.cmd export -Out D:\tmp\env.json
#>
[CmdletBinding()]
param(
    [string]$Profile = $env:DSH_PROFILE,
    [string]$DshHome = $env:DSH_HOME,
    [string]$Out,
    [string]$Baseline,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$skillDir = Split-Path -Parent $PSScriptRoot
if (-not $DshHome) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
if (-not $Profile) { $Profile = 'tauri' }
if (-not $Out)      { $Out = Join-Path $skillDir 'reference\env-manifest.exported.json' }
if (-not $Baseline) { $Baseline = Join-Path $skillDir 'reference\env-manifest.json' }

$profileDir = Join-Path $DshHome "profiles\$Profile"
$pkgPath    = Join-Path $profileDir 'package.json'
$patchPath  = Join-Path $profileDir 'cordis.patch.yml'
$moduleDir  = Join-Path $profileDir 'node_modules'

if (-not (Test-Path $pkgPath)) { throw "profile manifest not found: $pkgPath" }

$pkg  = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$deps = @{}
if ($pkg.dependencies) { $pkg.dependencies.PSObject.Properties | ForEach-Object { $deps[$_.Name] = $_.Value } }
$bundles = @()
if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $bundles = @($pkg.dsh.profile.bundles) }

# reuse the human annotations (role / why) from the curated manifest
$oldWork  = @{}
$oldPatch = @{}
if (Test-Path $Baseline) {
    try {
        $old = Get-Content $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $old.layers.work.packages) { $oldWork[$p.name] = $p }
        foreach ($e in $old.patch) { if ($e.id) { $oldPatch[$e.id] = $e } }
    } catch { }
}

# ---- dependencies -> host / work ----
$hostPkgs = @()
$workPkgs = New-Object System.Collections.Generic.List[object]
foreach ($name in ($deps.Keys | Sort-Object)) {
    $spec = [string]$deps[$name]
    if ($spec.StartsWith('link:')) { $hostPkgs += $name; continue }
    $installed = $null
    $pj = Join-Path (Join-Path $moduleDir ($name -replace '/', '\')) 'package.json'
    if (Test-Path $pj) {
        try { $installed = (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
    }
    $oldEntry = $oldWork[$name]
    $workPkgs.Add([pscustomobject][ordered]@{
        name      = $name
        range     = $spec
        installed = $installed
        role      = $(if ($oldEntry) { $oldEntry.role } else { 'todo' })
        why       = $(if ($oldEntry) { $oldEntry.why } else { 'TODO: say why this plugin is needed' })
        inBundles = ($bundles -contains $name)
    })
}

# ---- bundles ----
$coreBundles = @($bundles | Where-Object { $_ -like '@deepseek-ai/*' })
$workBundles = @($bundles | Where-Object { $_ -notlike '@deepseek-ai/*' })

# ---- patch layer (split on `- id:`, keep raw YAML per entry) ----
$patchOut = @()
if (Test-Path $patchPath) {
    $curId = $null
    $curLines = $null
    $blocks = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Get-Content $patchPath -Encoding UTF8)) {
        if ($line -match '^\s*-\s*id:\s*(\S+)\s*$') {
            if ($curId) { $blocks.Add([pscustomobject]@{ id = $curId; text = ($curLines -join "`n") + "`n" }) }
            $curId = $Matches[1]
            $curLines = @($line)
        } elseif ($curId) {
            $curLines += $line
        }
    }
    if ($curId) { $blocks.Add([pscustomobject]@{ id = $curId; text = ($curLines -join "`n") + "`n" }) }

    foreach ($b in $blocks) {
        $why = 'TODO: say why this override/disable exists'
        if ($oldPatch.ContainsKey($b.id) -and $oldPatch[$b.id].why) { $why = $oldPatch[$b.id].why }
        $patchOut += [pscustomobject][ordered]@{ id = $b.id; why = $why; yaml = $b.text }
    }
}

# ---- skills ----
# $skillDir is <skills-root>\dsh-env-bootstrap; see verify-env.ps1 for both layouts.
$skillsRoot = Split-Path -Parent $skillDir
$dshDir = Split-Path -Parent $skillsRoot
if ((Split-Path -Leaf $dshDir) -eq '.dsh') { $ws = Split-Path -Parent $dshDir } else { $ws = $null }
$projectSkills = @()
if (Test-Path $skillsRoot) {
    $projectSkills = @(Get-ChildItem $skillsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
        Select-Object -ExpandProperty Name | Sort-Object)
}
$shared = @()
$sharedRoot = Join-Path $skillsRoot 'scripts'
if (Test-Path $sharedRoot) {
    $shared = @(Get-ChildItem $sharedRoot -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object { 'scripts/' + ($_.FullName.Substring($sharedRoot.Length + 1) -replace '\\', '/') } | Sort-Object)
}

$snapshot = [pscustomobject][ordered]@{
    schemaVersion = 1
    kind          = 'dsh-work-env'
    exportedAt    = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    exportedFrom  = [pscustomobject][ordered]@{ profile = $Profile; platform = 'win32'; dshHome = '$DSH_HOME' }
    readme        = 'Auto-generated by export-env.ps1 (includes actually installed versions), meant for cross-version diffing. The curated source of truth is env-manifest.json.'
    layers        = [pscustomobject][ordered]@{
        host = [pscustomobject][ordered]@{
            note     = 'Desktop-shell link: packages. Absolute paths bound to this machine; not migratable, repaired by the desktop installer.'
            detectBy = 'dsh-tauri*'
            packages = @($hostPkgs)
        }
        core = [pscustomobject][ordered]@{
            note    = 'Official bundles. No versions pinned; they follow the DSH upgrade.'
            bundles = @($coreBundles)
        }
        work = [pscustomobject][ordered]@{
            note     = 'User work plugins: the part that actually has to be rebuilt when migrating.'
            packages = $workPkgs.ToArray()
        }
        workBundles = [pscustomobject][ordered]@{
            note    = 'Mounted bundles that are not in dependencies (e.g. injected by the host shell).'
            bundles = @($workBundles)
        }
    }
    patch  = @($patchOut)
    skills = [pscustomobject][ordered]@{
        project = @($projectSkills)
        shared  = @($shared)
    }
    verification = [pscustomobject][ordered]@{ script = 'scripts/verify-env.ps1'; launcher = 'run-env.cmd verify'; expectedExit = 0 }
}

$dir = Split-Path -Parent $Out
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$json = $snapshot | ConvertTo-Json -Depth 12
try {
    [System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Set-Content -Path $Out -Encoding UTF8 -Value $json
}
Write-Host "exported: $Out" -ForegroundColor Green

# ---- diff vs baseline ----
if (Test-Path $Baseline) {
    try {
        $base = Get-Content $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
        $baseWork  = @($base.layers.work.packages | Select-Object -ExpandProperty name)
        $nowWork   = @($workPkgs | Select-Object -ExpandProperty name)
        $baseCore  = @($base.layers.core.bundles)
        $basePatch = @($base.patch | Select-Object -ExpandProperty id)

        # Known-benign entry ids (onboarding / UI taste) never count as drift.
        $ignore = @()
        if ($base.patchIgnore) { $ignore = @($base.patchIgnore | Select-Object -ExpandProperty id) }

        $rows = @(
            @{ Label = 'work plugin ADDED';    Items = @($nowWork  | Where-Object { $baseWork  -notcontains $_ }) },
            @{ Label = 'work plugin REMOVED';  Items = @($baseWork | Where-Object { $nowWork   -notcontains $_ }) },
            @{ Label = 'core bundle ADDED';    Items = @($coreBundles | Where-Object { $baseCore -notcontains $_ }) },
            @{ Label = 'core bundle REMOVED';  Items = @($baseCore | Where-Object { $coreBundles -notcontains $_ }) },
            @{ Label = 'patch entry ADDED';    Items = @($patchOut.id | Where-Object { $basePatch -notcontains $_ -and $ignore -notcontains $_ }) },
            @{ Label = 'patch entry REMOVED';  Items = @($basePatch | Where-Object { $patchOut.id -notcontains $_ }) }
        )

        Write-Host ""
        Write-Host "diff vs baseline ($Baseline)" -ForegroundColor Cyan
        Write-Host ("-" * 70)
        $any = $false
        foreach ($row in $rows) {
            if ($row.Items.Count -gt 0) {
                $any = $true
                Write-Host ("{0}: {1}" -f $row.Label, ($row.Items -join ', ')) -ForegroundColor Yellow
            }
        }
        if (-not $any) { Write-Host "no differences: the live environment matches the baseline." -ForegroundColor Green }
        Write-Host ("-" * 70)
    } catch {
        Write-Host "diff skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($PassThru) { $snapshot }
