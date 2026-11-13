# Publish a pack (or a raw store) to the CDN through the site, and pin it in content.lock.json. Same flags as publish_pack.sh.
#   .\tools\publish_pack.ps1 [publish] -Source DIR -Id NAME [-Version V | -Bump patch|minor|major] [-Lock content.lock.json]
#       [-Into DIR] [-Kind pack|store] [-LockOptional] [-Name TEXT] [-Meta k=v,...] [-ExcludeDir a,b] [-Site URL] [-TokenFile FILE]
#       [-Out DIR] [-Godot BIN] [-DryRun] [-NoImport] [-HostAddons LOCK,...] [-HostLevel name=N,...]
#   publish derives requires.json like publish_pack.sh (dot-core's dot_requires.gd) and caps each level at the -HostAddons lock's
#   (addon repo at the locked ref, LEVEL in <addon>_api.gd) or -HostLevel name=N; a committed requires.json above the host is refused.
#   Not ported yet: leaving the host's addons out of the pack (use publish_pack.sh for a game that links family addons).
#   .\tools\publish_pack.ps1 versions [-Id NAME] [-Site URL] [-TokenFile FILE]
#   .\tools\publish_pack.ps1 member -Id NAME -MemberOf ASSET [-Site URL] [-TokenFile FILE]   (move a pack's versions into a collection page)
#   publish -MemberOf ASSET: publish as a member of that collection asset (keeps -Id, no Workshop page of its own)
# Token: $env:DOT_CLI_TOKEN (a creator token), else the file in -TokenFile / $env:DOT_CLI_TOKEN_FILE / ~\.config\dot\cli-token. Never an
# argument; an env token is copied to a temp file that is removed on exit. Site: -Site, $env:DOT_SITE, else https://tmcdev.net.
# Needs curl.exe (ships with Windows 10+) and Godot on PATH or -Godot. Flags map one to one onto publish_pack.sh's --kebab-case ones.
param([Parameter(Position = 0)][ValidateSet('publish', 'versions', 'member')][string]$Command = 'publish',
      [string]$Source, [string]$Id, [string]$Version, [ValidateSet('', 'patch', 'minor', 'major')][string]$Bump = '',
      [string]$Lock = 'content.lock.json', [string]$Into, [ValidateSet('', 'pack', 'store')][string]$Kind = '', [switch]$LockOptional, [int]$Asset = 0, [int]$MemberOf = 0,
      [string]$Name, [string[]]$Meta = @(), [string[]]$ExcludeDir = @(), [string]$Site, [string]$TokenFile, [string]$Out,
      [string[]]$HostAddons = @(), [string[]]$HostLevel = @(),
      [string]$Godot, [switch]$DryRun, [switch]$NoImport)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
if (-not $Godot) { $Godot = if ($env:GODOT) { $env:GODOT } else { 'godot' } }
if (-not $Site) { $Site = $env:DOT_SITE }
if (-not $TokenFile) { $TokenFile = if ($env:DOT_CLI_TOKEN_FILE) { $env:DOT_CLI_TOKEN_FILE } else { Join-Path $HOME '.config\dot\cli-token' } }
function Full($p) { if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path (Get-Location).Path $p } }

# HostLevelOf LOCK PROJECT ADDON: the API level the lock pins for ADDON ($null when the lock does not carry it). Same rule as publish_pack.sh.
function HostLevelOf($lock, $proj, $a) {
    $root = $null; $repo = $null; $ref = $null
    if (Test-Path (Join-Path $proj "addons/$a")) {
        $t = (Resolve-Path (Join-Path $proj "addons/$a")).Path
        $root = Split-Path -Parent (Split-Path -Parent $t); $repo = Split-Path -Leaf $root
    }
    foreach ($ln in Get-Content $lock) {
        if ($ln -match '^\s*(#|$)') { continue }
        $f = $ln -split "`t"
        if ($f.Count -lt 2) { continue }
        if (($f[0] -replace '-', '_') -eq $a -or ($repo -and $f[0] -eq $repo)) { $ref = $f[1].Trim(); $repo = $f[0]; break }
    }
    if (-not $ref) { return $null }
    foreach ($h in $HostLevel) { if ($h.Split('=')[0] -eq $a) { return $null } }
    git -C $root rev-parse -q --verify "$ref^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { $root = Join-Path (Split-Path -Parent $lock) "../$repo"; git -C $root rev-parse -q --verify "$ref^{commit}" *> $null }
    if ($LASTEXITCODE -ne 0) { throw "publish_pack: cannot find $repo at $ref (the host lock's) to read its level; fetch its tags or pass -HostLevel $a=N" }
    $m = (git -C $root show "${ref}:addons/$a/${a}_api.gd" 2>$null) | Select-String -Pattern '^const LEVEL *:= *(\d+)' | Select-Object -First 1
    if ($m) { return [int]$m.Matches[0].Groups[1].Value } else { return 1 }
}

# HostNames ARG: the addon folder names a -HostAddons argument lists (lock file, directory with addons.lock, or a directory of addons), underscores normalised. Same rule as publish_pack.sh.
function HostNames($f) {
    if (Test-Path $f -PathType Container) {
        if (Test-Path (Join-Path $f 'addons.lock')) { $f = Join-Path $f 'addons.lock' }
        else { $d = if (Test-Path (Join-Path $f 'addons')) { Join-Path $f 'addons' } else { $f }; return @(Get-ChildItem $d -Directory | ForEach-Object { $_.Name -replace '-', '_' }) }
    }
    if (-not (Test-Path $f -PathType Leaf)) { throw "publish_pack: -HostAddons $f is not a file or directory" }
    return @(Get-Content $f | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { (($_ -split "`t")[0].Trim()) -replace '-', '_' } | Where-Object { $_ })
}

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
    if ($MemberOf -gt 0) { $a += '--member-of', "$MemberOf" }
    if ($Command -eq 'member') {
        & $Godot @run member --token-file (Full $TokenFile) @a
        exit $LASTEXITCODE
    }
    if (-not $Source) { Write-Error 'publish_pack: -Source is required'; exit 1 }
    # A fresh clone has .import markers but no .godot/imported outputs; the publisher refuses those.
    if (-not $NoImport) {
        $p = (Resolve-Path (Full $Source)).Path
        while ($p -and -not (Test-Path (Join-Path $p 'project.godot'))) { $p = Split-Path -Parent $p }
        if ($p) {
            Write-Host "publish_pack: importing $p"
            & $Godot --headless --path $p --import *> $null
            if ($LASTEXITCODE -ne 0) { Write-Error "publish_pack: import of $p failed"; exit 1 }
        }
    }
    # -HostAddons leaves out the addons/<name> folders the host already owns (a duplicate class_name breaks the pack), like publish_pack.sh.
    # Matched by folder name or by the repository a linked addon points into; anchored at addons/ so cfg/addon/<name>/ stays.
    $sd = Join-Path (Full $Source) 'addons'
    if (Test-Path $sd -PathType Container) {
        if ($HostAddons.Count -eq 0) {
            [Console]::Error.WriteLine("publish_pack: no -HostAddons: packing every addon under $sd (a host that already owns one will refuse the pack; see docs/cdn-publish.md)")
        } else {
            $names = @($HostAddons | ForEach-Object { HostNames $_ } | Sort-Object -Unique)
            $left = @(); $kept = @()
            foreach ($d in Get-ChildItem $sd -Directory) {
                $n = $d.Name; $repo = $null
                $tgt = (Resolve-Path $d.FullName).Path
                if ($tgt -match '[\\/]([^\\/]+)[\\/]addons[\\/][^\\/]+$') { $repo = $Matches[1] -replace '-', '_' }
                if ($names -contains $n -or ($repo -and $names -contains $repo)) { $left += $n; $a += '--exclude-dir', "addons/$n" } else { $kept += $n }
            }
            [Console]::Error.WriteLine("publish_pack: -HostAddons left out $($left.Count) host-owned addon(s): $(if ($left) { $left -join ' ' } else { 'none' })")
            [Console]::Error.WriteLine("publish_pack: packing $($kept.Count) other addon(s): $(if ($kept) { $kept -join ' ' } else { 'none' })")
        }
    }
    # requires.json: derived like publish_pack.sh, capped at the host lock's levels; a committed one above them is refused.
    $pp = (Resolve-Path (Full $Source)).Path
    while ($pp -and -not (Test-Path (Join-Path $pp 'project.godot'))) { $pp = Split-Path -Parent $pp }
    if ($pp -and (Test-Path (Join-Path $pp 'addons/dot_core/tools/dot_requires.gd'))) {
        $req = Join-Path (Full $Source) 'requires.json'; $mode = 'check'
        if (-not (Test-Path $req)) {
            $req = Join-Path $tmp 'requires.json'; $mode = 'cap'
            & $Godot --headless --path $pp --script res://addons/dot_core/tools/dot_requires.gd -- --out $req *> $null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $req) -or (Get-Item $req).Length -eq 0) { Write-Error "publish_pack: could not derive requires.json for $pp"; exit 1 }
            $a += '--extra-file', "requires.json=$req"
        }
        $caps = @{}
        foreach ($h in $HostLevel) { $kv = $h.Split('=', 2); $caps[$kv[0]] = [int]$kv[1] }
        $doc = Get-Content -Raw $req | ConvertFrom-Json
        foreach ($h in $HostAddons) {
            if (Test-Path $h -PathType Container) { $h = Join-Path $h 'addons.lock' }
            if (-not (Test-Path $h -PathType Leaf) -or -not ((Get-Content -Raw $h) -match "`t")) { continue }
            foreach ($n in $doc.addons.PSObject.Properties.Name) {
                $lv = HostLevelOf $h $pp $n
                if ($null -ne $lv) { $caps[$n] = $lv }
            }
        }
        $bad = $false
        foreach ($n in @($doc.addons.PSObject.Properties.Name | Sort-Object)) {
            if ($caps.ContainsKey($n) -and [int]$doc.addons.$n -gt $caps[$n]) {
                if ($mode -eq 'check') { $bad = $true; [Console]::Error.WriteLine("publish_pack: requires.json asks $n level $($doc.addons.$n); the host carries $($caps[$n])") }
                else { [Console]::Error.WriteLine("publish_pack: requires.json: $n $($doc.addons.$n) capped at the host's $($caps[$n])"); $doc.addons.$n = $caps[$n] }
            }
        }
        if ($bad) { Write-Error "publish_pack: the committed requires.json is above the host's levels; the host would refuse the pack. Refusing."; exit 1 }
        if ($mode -eq 'cap') { [IO.File]::WriteAllText($req, ($doc | ConvertTo-Json -Depth 5) + "`n") }
        Write-Host ("publish_pack: requires.json ({0}): {1}" -f $(if ($mode -eq 'cap') { 'derived' } else { 'committed' }), (($doc.addons.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Value)" }) -join ', '))
    } elseif ($pp) {
        Write-Host "publish_pack: note: $pp has no addons/dot_core/tools/dot_requires.gd; the pack ships without requires.json"
    }
    if (-not $Out) { $Out = Join-Path $tmp 'out' }
    $a += '--source', (Full $Source), '--out', (Full $Out)
    if ($Version) { $a += '--version', $Version }
    if ($Bump) { $a += '--bump', $Bump }
    if ($Into) { $a += '--into', $Into }
    if ($Kind) { $a += '--kind', $Kind }
    if ($LockOptional) { $a += '--lock-optional' }
    if ($Asset -gt 0) { $a += '--asset', "$Asset" }
    if ($Name) { $a += '--name', $Name }
    foreach ($m in $Meta) { $a += '--meta', $m }
    foreach ($d in $ExcludeDir) { $a += '--exclude-dir', $d }
    if (-not $DryRun) { $a += '--upload', '--token-file', (Full $TokenFile), '--lock', (Full $Lock) }
    & $Godot @run publish @a
    exit $LASTEXITCODE
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
