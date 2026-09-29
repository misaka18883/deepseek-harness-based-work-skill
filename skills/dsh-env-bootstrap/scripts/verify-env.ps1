<#
  verify-env.ps1 -- read-only check of the DSH work plugin environment.
  Zero network, zero tokens, zero writes: run it FIRST to decide whether
  anything needs installing.

  NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 reads
  .ps1 files as ANSI unless they carry a UTF-8 BOM, so non-ASCII text here
  would be mangled on machines with a different code page. Keep it ASCII.

  Usage:
    run-env.cmd verify
    powershell -NoProfile -ExecutionPolicy Bypass -File verify-env.ps1 [-Json]

  Exit codes:
    0 = all required checks passed
    1 = at least one required check failed
    2 = environment not decidable (manifest unreadable / profile missing)
#>
[CmdletBinding()]
param(
    [string]$Manifest,
    [string]$DshHome = $env:DSH_HOME,
    [string]$Profile = $env:DSH_PROFILE,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$skillDir = Split-Path -Parent $PSScriptRoot

if (-not $Manifest) { $Manifest = Join-Path $skillDir 'reference\env-manifest.json' }
if (-not $DshHome)  { $DshHome  = Join-Path $env:USERPROFILE '.dsh' }
if (-not $Profile)  { $Profile  = 'tauri' }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Id, [string]$Level, [bool]$Ok, [string]$Detail)
    $script:results.Add([pscustomobject]@{ Id = $Id; Level = $Level; Ok = $Ok; Detail = $Detail })
}

function Test-Range {
    param([string]$Installed, [string]$Range)
    if (-not $Installed -or -not $Range) { return $false }
    try { $iv = [version]$Installed } catch { return $false }
    $clean = $Range.Trim()
    $caret = $clean.StartsWith('^')
    $tilde = $clean.StartsWith('~')
    $base  = $clean.TrimStart('^', '~', '=', 'v', ' ')
    try { $bv = [version]$base } catch { return $false }
    if ($iv -lt $bv) { return $false }
    if ($caret) {
        if ($bv.Major -gt 0) { return ($iv.Major -eq $bv.Major) }
        if ($bv.Minor -gt 0) { return ($iv.Major -eq 0 -and $iv.Minor -eq $bv.Minor) }
        return ($iv.Major -eq 0 -and $iv.Minor -eq 0 -and $iv.Build -eq $bv.Build)
    }
    if ($tilde) {
        if ($bv.Major -gt 0 -or $bv.Minor -gt 0) { return ($iv.Major -eq $bv.Major -and $iv.Minor -eq $bv.Minor) }
        return ($iv.Major -eq 0 -and $iv.Minor -eq 0 -and $iv.Build -eq $bv.Build)
    }
    return ($iv -ge $bv)
}

# ---------- 0. manifest ----------
if (-not (Test-Path $Manifest)) {
    Write-Host "cannot read manifest: $Manifest" -ForegroundColor Red
    exit 2
}
try {
    $mf = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "manifest is not valid JSON: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

# ---------- 1. host layout ----------
$profileDir = Join-Path $DshHome "profiles\$Profile"
$pkgPath    = Join-Path $profileDir 'package.json'
$patchPath  = Join-Path $profileDir 'cordis.patch.yml'
$moduleDir  = Join-Path $profileDir 'node_modules'

Add-Result 'dsh-home' 'info' (Test-Path $DshHome) "DSH_HOME = $DshHome"
if (-not (Test-Path $pkgPath)) {
    Add-Result 'profile' 'required' $false "profile manifest not found: $pkgPath"
    $results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host "hint: create the profile from the desktop installer, or boot it once with: dsh --from-default-profile web" -ForegroundColor Yellow
    exit 2
}
$profilePkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Result 'profile' 'required' $true "profile = $Profile"

# ---------- 2. tooling ----------
$dshCmd = $null
$onPath = Get-Command dsh.cmd -ErrorAction SilentlyContinue
if ($onPath) { $dshCmd = $onPath.Source }
if (-not $dshCmd) {
    $cand = Join-Path $env:LOCALAPPDATA 'deepseek-harness\bin\dsh.cmd'
    if (Test-Path $cand) { $dshCmd = $cand }
}
Add-Result 'dsh-cli' 'info' ($null -ne $dshCmd) $(if ($dshCmd) { $dshCmd } else { 'dsh.cmd not found (use GUI plugin page or node bin.js)' })

$psPolicy = 'unknown'
try { $psPolicy = (Get-ExecutionPolicy).ToString() } catch { }
Add-Result 'execution-policy' 'warn' ($psPolicy -ne 'Restricted') "ExecutionPolicy = $psPolicy (Restricted blocks dsh.ps1; use dsh.cmd or -ExecutionPolicy Bypass)"

foreach ($tool in @('node', 'python')) {
    $c = Get-Command $tool -ErrorAction SilentlyContinue
    $ver = ''
    if ($c) {
        try { $ver = (& $tool --version 2>&1 | Select-Object -First 1) } catch { $ver = 'unknown' }
    }
    Add-Result "tool:$tool" 'info' ($null -ne $c) $(if ($c) { "$($c.Source) $ver" } else { 'not on PATH' })
}

# ---------- 3. official bundles ----------
$bundles = @()
if ($profilePkg.dsh -and $profilePkg.dsh.profile -and $profilePkg.dsh.profile.bundles) {
    $bundles = @($profilePkg.dsh.profile.bundles)
}
$missingCore = @($mf.layers.core.bundles | Where-Object { $bundles -notcontains $_ })
Add-Result 'core-bundles' 'required' ($missingCore.Count -eq 0) `
    $(if ($missingCore.Count -eq 0) { "$($mf.layers.core.bundles.Count) official bundles mounted" } else { "missing: $($missingCore -join ', ')" })

# ---------- 4. work plugin layer ----------
$deps = @{}
if ($profilePkg.dependencies) {
    $profilePkg.dependencies.PSObject.Properties | ForEach-Object { $deps[$_.Name] = $_.Value }
}

foreach ($p in $mf.layers.work.packages) {
    $name = $p.name
    $declared = $deps.ContainsKey($name)
    $installed = $null
    $pj = Join-Path $moduleDir ($name -replace '/', '\')
    $pj = Join-Path $pj 'package.json'
    if (Test-Path $pj) {
        try { $installed = (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
    }
    $inBundles = $bundles -contains $name
    $ok = $declared -and ($null -ne $installed) -and $inBundles
    $detail = ''
    if ($ok) {
        $detail = "v$installed mounted ($($p.role))"
    } else {
        $bits = @()
        if (-not $declared)     { $bits += 'not in dependencies' }
        if ($null -eq $installed) { $bits += 'not in node_modules' }
        if (-not $inBundles)    { $bits += 'not in bundles' }
        $detail = "$($bits -join ' / ') -- want $($p.range)"
    }
    Add-Result "work:$name" 'required' $ok $detail
}

# ---------- 5. user patch layer ----------
$patchText = ''
if (Test-Path $patchPath) { $patchText = Get-Content $patchPath -Raw -Encoding UTF8 }
$missingPatch = @()
foreach ($entry in $mf.patch) {
    if ($patchText -notmatch ("(?m)^\s*-\s*id:\s*" + [regex]::Escape($entry.id) + "\s*$")) {
        $missingPatch += $entry.id
    }
}
Add-Result 'user-patch' 'required' ($missingPatch.Count -eq 0) `
    $(if ($missingPatch.Count -eq 0) { "$($mf.patch.Count) overrides/disabled entries present" } else { "missing: $($missingPatch -join ', ')" })

# ---------- 6. skills ----------
# $skillDir is <skills-root>\dsh-env-bootstrap. A project-level skills root is
# <workspace>\.dsh\skills; a user-level one is $DSH_HOME\skills. Resolve both.
$skillsRoot = Split-Path -Parent $skillDir
$dshDir = Split-Path -Parent $skillsRoot
if ((Split-Path -Leaf $dshDir) -eq '.dsh') { $ws = Split-Path -Parent $dshDir } else { $ws = $null }
# NOTE: skill presence is advisory (warn), not required. The plugin environment
# (core/work/patch) is what this skill owns; which workspace skills exist is
# machine- and project-specific, so a missing one must not fail the check on
# someone else's checkout.
foreach ($s in $mf.skills.project) {
    $f = Join-Path $skillsRoot "$s\SKILL.md"
    $hasName = $false
    if (Test-Path $f) {
        $head = (Get-Content $f -TotalCount 5 -Encoding UTF8) -join "`n"
        $hasName = $head -match ('(?m)^name:\s*' + [regex]::Escape($s) + '\s*$')
    }
    Add-Result "skill:$s" 'warn' $hasName $(if ($hasName) { $f } else { "not found under $skillsRoot (advisory only)" })
}
foreach ($sh in $mf.skills.shared) {
    $f = Join-Path $skillsRoot ($sh -replace '/', '\')
    Add-Result "shared:$(Split-Path -Leaf $sh)" 'warn' (Test-Path $f) $(if (Test-Path $f) { $f } else { "missing shared resource: $f" })
}

# ---------- 7. host shell layer (detect only) ----------
$hostFound = @(Get-ChildItem $moduleDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$($mf.layers.host.detectBy)" } | Select-Object -ExpandProperty Name)
Add-Result 'host-layer' 'info' ($hostFound.Count -gt 0) `
    "$($hostFound.Count) desktop-shell packages (link: absolute paths, not migratable; the installer repairs them)"

# ---------- output ----------
$failed = @($results | Where-Object { $_.Level -eq 'required' -and -not $_.Ok })

if ($Json) {
    [pscustomobject]@{
        ok      = ($failed.Count -eq 0)
        profile = $Profile
        dshHome = $DshHome
        failed  = @($failed | Select-Object -ExpandProperty Id)
        checks  = $results
    } | ConvertTo-Json -Depth 4
} else {
    Write-Host ""
    Write-Host "DSH work environment check  (profile=$Profile, home=$DshHome)" -ForegroundColor Cyan
    Write-Host ("-" * 78)
    foreach ($r in $results) {
        $tag = switch ($r.Level) { 'required' { 'REQ ' } 'warn' { 'WARN' } default { 'INFO' } }
        $mark = if ($r.Ok) { ' OK ' } else { 'FAIL' }
        $color = if ($r.Ok) { 'Green' } elseif ($r.Level -eq 'required') { 'Red' } else { 'Yellow' }
        Write-Host ("[$mark][$tag] {0,-40} {1}" -f $r.Id, $r.Detail) -ForegroundColor $color
    }
    Write-Host ("-" * 78)
    if ($failed.Count -eq 0) {
        Write-Host "RESULT: environment is usable, nothing to install." -ForegroundColor Green
    } else {
        Write-Host "RESULT: $($failed.Count) required check(s) failed -> $($failed.Id -join ', ')" -ForegroundColor Red
        Write-Host "FIX   : run-env.cmd apply        (idempotent, only fills the gaps)" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($failed.Count -eq 0) { exit 0 } else { exit 1 }
