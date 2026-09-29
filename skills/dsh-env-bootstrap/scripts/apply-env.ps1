<#
  apply-env.ps1 -- rebuild the DSH work plugin environment from the manifest.

  Idempotent: it only fills the gaps. Safe to run repeatedly.
  It does two things per missing work plugin:
    a) dsh plugin --profile <p> add <name>@<range>     (install + declare dependency)
    b) append <name> to dsh.profile.bundles in the profile package.json
  Then it appends any missing user patch entries to cordis.patch.yml,
  and finally re-runs verify-env.ps1.

  IMPORTANT: this writes OUTSIDE the session workspace (into $DSH_HOME), so it
  cannot run inside the DSH sandbox. Run it in a normal terminal, or use the
  GUI plugin page. Use -DryRun to preview without touching anything.

  ASCII-only on purpose (see verify-env.ps1 header).

  Usage:
    run-env.cmd apply -DryRun
    run-env.cmd apply
    run-env.cmd apply -Scope patch
#>
[CmdletBinding()]
param(
    [string]$Profile = $env:DSH_PROFILE,
    [string]$DshHome = $env:DSH_HOME,
    [string]$Manifest,
    [ValidateSet('all', 'work', 'patch')][string]$Scope = 'all',
    [switch]$DryRun,
    [switch]$PreferOffline,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$skillDir = Split-Path -Parent $PSScriptRoot

if (-not $Manifest) { $Manifest = Join-Path $skillDir 'reference\env-manifest.json' }
if (-not $DshHome)  { $DshHome  = Join-Path $env:USERPROFILE '.dsh' }
if (-not $Profile)  { $Profile  = 'tauri' }

$profileDir = Join-Path $DshHome "profiles\$Profile"
$pkgPath    = Join-Path $profileDir 'package.json'
$patchPath  = Join-Path $profileDir 'cordis.patch.yml'
$moduleDir  = Join-Path $profileDir 'node_modules'

if (-not (Test-Path $Manifest)) { Write-Host "cannot read manifest: $Manifest" -ForegroundColor Red; exit 2 }
if (-not (Test-Path $pkgPath)) {
    Write-Host "profile not found: $pkgPath" -ForegroundColor Red
    Write-Host "Create it first (desktop installer), or boot it once:  dsh --from-default-profile web" -ForegroundColor Yellow
    exit 2
}
$mf = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json

function Write-TextNoBom {
    param([string]$Path, [string]$Text)
    try {
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Set-Content -Path $Path -Encoding UTF8 -Value $Text
    }
}

function Resolve-DshCommand {
    $onPath = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $cand = Join-Path $env:LOCALAPPDATA 'deepseek-harness\bin\dsh.cmd'
    if (Test-Path $cand) { return $cand }
    return $null
}

$mode = if ($DryRun) { 'DRY-RUN' } else { 'APPLY' }
Write-Host "=== dsh-env-bootstrap [$mode] profile=$Profile ===" -ForegroundColor Cyan

# ---------- backup ----------
if (-not $DryRun) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $backupDir = Join-Path $DshHome ".plugin-backups\env-bootstrap-$stamp"
    try {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item $pkgPath (Join-Path $backupDir 'package.json') -Force
        if (Test-Path $patchPath) { Copy-Item $patchPath (Join-Path $backupDir 'cordis.patch.yml') -Force }
        Write-Host "backup: $backupDir" -ForegroundColor DarkGray
    } catch {
        Write-Host "WARNING: backup failed ($($_.Exception.Message))" -ForegroundColor Yellow
        Write-Host "         likely a sandbox/permission block. Run this from a normal terminal." -ForegroundColor Yellow
    }
}

$installed = 0; $failed = @(); $skipped = 0

# ---------- work plugin layer ----------
if ($Scope -eq 'all' -or $Scope -eq 'work') {
    $dshCmd = Resolve-DshCommand
    if (-not $dshCmd -and -not $DryRun) {
        Write-Host "dsh.cmd not found; install the plugins from the GUI plugin page instead." -ForegroundColor Red
        exit 2
    }

    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $deps = @{}
    if ($pkg.dependencies) { $pkg.dependencies.PSObject.Properties | ForEach-Object { $deps[$_.Name] = $_.Value } }
    $bundles = @()
    if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $bundles = @($pkg.dsh.profile.bundles) }
    $bundlesChanged = $false

    foreach ($p in $mf.layers.work.packages) {
        $name = $p.name
        $spec = "$name@$($p.range)"

        # 1) dependency declared?
        if (-not $deps.ContainsKey($name)) {
            if ($DryRun) {
                Write-Host "  [dry] would install: $spec" -ForegroundColor Yellow
            } else {
                Write-Host "  installing: $spec" -ForegroundColor Cyan
                $env:DSH_HOME = $DshHome
                $dshArgs = @('plugin', '--profile', $Profile, 'add', $spec)
                if ($PreferOffline) { $dshArgs += '--prefer-offline' }
                try {
                    & $dshCmd @dshArgs
                    if ($LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
                    $installed++
                } catch {
                    Write-Host "  FAILED: $spec -- $($_.Exception.Message)" -ForegroundColor Red
                    $failed += $name
                    continue
                }
                # re-read the profile manifest after the install
                $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $deps = @{}
                if ($pkg.dependencies) { $pkg.dependencies.PSObject.Properties | ForEach-Object { $deps[$_.Name] = $_.Value } }
            }
        } else {
            $skipped++
        }

        # 2) mounted in bundles?
        if ($bundles -notcontains $name) {
            if ($DryRun) {
                Write-Host "  [dry] would mount in bundles: $name" -ForegroundColor Yellow
            } else {
                $bundles += $name
                $bundlesChanged = $true
                Write-Host "  mounting in bundles: $name" -ForegroundColor Cyan
            }
        }
    }

    if ($bundlesChanged -and -not $DryRun) {
        $pkg.dsh.profile.bundles = @($bundles)
        Write-TextNoBom -Path $pkgPath -Text ($pkg | ConvertTo-Json -Depth 10)
        Write-Host "  profile manifest updated (bundles)" -ForegroundColor Green
    }
}

# ---------- user patch layer ----------
if ($Scope -eq 'all' -or $Scope -eq 'patch') {
    $text = ''
    if (Test-Path $patchPath) { $text = Get-Content $patchPath -Raw -Encoding UTF8 }
    $added = 0
    foreach ($entry in $mf.patch) {
        if ($text -match ("(?m)^\s*-\s*id:\s*" + [regex]::Escape($entry.id) + "\s*$")) { continue }
        if ($DryRun) {
            Write-Host "  [dry] would append patch entry: $($entry.id)" -ForegroundColor Yellow
        } else {
            if ($text -and -not $text.EndsWith("`n")) { $text += "`n" }
            $text += $entry.yaml
            $added++
            Write-Host "  appended patch entry: $($entry.id)" -ForegroundColor Cyan
        }
    }
    if ($added -gt 0 -and -not $DryRun) {
        Write-TextNoBom -Path $patchPath -Text $text
        Write-Host "  cordis.patch.yml updated" -ForegroundColor Green
    }
}

# ---------- summary ----------
Write-Host ""
if ($DryRun) {
    Write-Host "DRY-RUN complete: nothing was changed." -ForegroundColor Green
} else {
    Write-Host "APPLY complete: installed=$installed skipped(already present)=$skipped failed=$($failed.Count)" -ForegroundColor Green
    if ($failed.Count -gt 0) { Write-Host "failed: $($failed -join ', ')" -ForegroundColor Red }
}

# ---------- verify ----------
if (-not $SkipVerify -and -not $DryRun) {
    $verify = Join-Path $PSScriptRoot 'verify-env.ps1'
    if (Test-Path $verify) {
        Write-Host ""
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verify -Manifest $Manifest -DshHome $DshHome -Profile $Profile
    }
}

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
