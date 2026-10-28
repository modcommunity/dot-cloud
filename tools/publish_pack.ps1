# Publish a pack (or a raw store) to the CDN through the site, and pin it in content.lock.json. Same flags as publish_pack.sh.
#   .\tools\publish_pack.ps1 [publish] -Source DIR -Id NAME [-Version V | -Bump patch|minor|major] [-Lock content.lock.json]
#       [-Into DIR] [-Kind pack|store] [-LockOptional] [-Name TEXT] [-Meta k=v,...] [-ExcludeDir a,b] [-Site URL] [-TokenFile FILE]
#       [-Out DIR] [-Godot BIN] [-DryRun]
#   .\tools\publish_pack.ps1 versions [-Id NAME] [-Site URL] [-TokenFile FILE]
# Token: $env:DOT_CLI_TOKEN (a creator token), else the file in -TokenFile / $env:DOT_CLI_TOKEN_FILE / ~\.config\dot\cli-token. Never an
# argument; an env token is copied to a temp file that is removed on exit. Site: -Site, $env:DOT_SITE, else https://dev.dotgames.org.
# Needs curl.exe (ships with Windows 10+) and Godot on PATH or -Godot. Flags map one to one onto publish_pack.sh's --kebab-case ones.
param([Parameter(Position = 0)][ValidateSet('publish', 'versions')][string]$Command = 'publish',
      [string]$Source, [string]$Id, [string]$Version, [ValidateSet('', 'patch', 'minor', 'major')][string]$Bump = '',
      [string]$Lock = 'content.lock.json', [string]$Into, [ValidateSet('', 'pack', 'store')][string]$Kind = '', [switch]$LockOptional,
      [string]$Name, [string[]]$Meta = @(), [string[]]$ExcludeDir = @(), [string]$Site, [string]$TokenFile, [string]$Out,
      [string]$Godot, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = if ($env:GODOT) { $env:GODOT } else { 'godot' } }
if (-not $Site) { $Site = $env:DOT_SITE }
if (-not $TokenFile) { $TokenFile = if ($env:DOT_CLI_TOKEN_FILE) { $env:DOT_CLI_TOKEN_FILE } else { Join-Path $HOME '.config\dot\cli-token' } }
function Full($p) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("publish_pack_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
    if ($env:DOT_CLI_TOKEN) {
        $TokenFile = Join-Path $tmp 'token'
        [IO.File]::WriteAllText($TokenFile, $env:DOT_CLI_TOKEN)
    }
    if (-not $DryRun -and (-not (Test-Path $TokenFile) -or (Get-Item $TokenFile).Length -eq 0)) {
        Write-Error "publish_pack: no token (set DOT_CLI_TOKEN or write one to $TokenFile)"; exit 2
    }
    $a = @()
    if ($Id) { $a += '--id', $Id }
    if ($Site) { $a += '--site', $Site }
    if (-not (Test-Path (Join-Path $here '.godot\global_script_class_cache.cfg'))) {
        & $Godot --headless --path $here --import *> $null
    }
    $run = @('--headless', '--path', $here, '--script', 'addons/dot_cloud/publish/dot_cloud_cli.gd', '--')
    if ($Command -eq 'versions') {
        & $Godot @run versions --token-file (Full $TokenFile) @a
        exit $LASTEXITCODE
    }
    if (-not $Source) { Write-Error 'publish_pack: -Source is required'; exit 1 }
    if (-not $Out) { $Out = Join-Path $tmp 'out' }
    $a += '--source', (Full $Source), '--out', (Full $Out)
    if ($Version) { $a += '--version', $Version }
    if ($Bump) { $a += '--bump', $Bump }
    if ($Into) { $a += '--into', $Into }
    if ($Kind) { $a += '--kind', $Kind }
    if ($LockOptional) { $a += '--lock-optional' }
    if ($Name) { $a += '--name', $Name }
    foreach ($m in $Meta) { $a += '--meta', $m }
    foreach ($d in $ExcludeDir) { $a += '--exclude-dir', $d }
    if (-not $DryRun) { $a += '--upload', '--token-file', (Full $TokenFile), '--lock', (Full $Lock) }
    & $Godot @run publish @a
    exit $LASTEXITCODE
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
