<#
.SYNOPSIS
  Makes the VMware Tools uninstaller work on a machine that no longer runs on VMware (KVM, Hyper-V, physical).

.DESCRIPTION
  VMware Tools custom-action DLLs call the VMware "backdoor" (I/O ports 0x5658/0x5659) without any protection.
  Outside VMware those instructions raise a privileged-instruction fault (0xC0000096) in user mode. The custom action
  host crashes, and the removal can fail with error 1603.

  This script patches, in place and with the same length, every backdoor instruction in the user-mode programs it
  is pointed at, so that they return what a machine without the backdoor returns:
    in eax,dx            ->  EAX = 0xFFFFFFFF   (callers read this as "not VMware" / "RPC failed")
    rep insb / rep outsb ->  EBX = 0            (status "failed")

  By default it patches the custom-action DLLs stored inside the cached MSI package of the installed VMware Tools
  (C:\Windows\Installer\*.msi). With -InstalledFiles it also patches user-mode EXE/DLL files in the VMware Tools
  program folder. Kernel drivers (.sys) are never touched.

  A backup of every changed file is kept. Run as Administrator or SYSTEM, before "msiexec /x".

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File Fix-VMwareToolsUninstall.ps1
  powershell -ExecutionPolicy Bypass -File Fix-VMwareToolsUninstall.ps1 -InstalledFiles
  powershell -ExecutionPolicy Bypass -File Fix-VMwareToolsUninstall.ps1 -Path C:\temp\copy.msi -NoBackup
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [switch]$InstalledFiles,
    [switch]$DryRun,
    [switch]$NoBackup,
    [string]$BackupDir = (Join-Path $env:SystemRoot 'Temp\vmtools-uninstall-fix-backup'),
    [string]$LogPath = (Join-Path $env:SystemRoot 'Temp\vmtools-uninstall-fix.log')
)
$ErrorActionPreference = 'Stop'
$script:Latin1 = [Text.Encoding]::GetEncoding(28591)
$script:Changed = 0
$script:Sites = 0

function Write-Log([string]$m) {
    $line = '{0} {1}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), $m
    Write-Output $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

# name, regex (case-sensitive, over bytes mapped 1:1 to characters), replacement bytes
$script:Rules = @(
    @{ Name = 'InOut-x64'; Rx = '\x48\x8b\x00\xed(?=\x48\x87\x04\x24)';     New = [byte[]](0x83, 0xC8, 0xFF, 0x90) },      # or eax,-1 ; nop
    @{ Name = 'InOut-x86'; Rx = '(?<!\x48)\x8b\x00\xed(?=\x87\x04\x24)';    New = [byte[]](0x83, 0xC8, 0xFF) },            # or eax,-1
    @{ Name = 'HbIn';      Rx = '(?<=\x8b\x00\xfc)\xf3\x6c';                New = [byte[]](0x31, 0xDB) },                  # xor ebx,ebx
    @{ Name = 'HbOut';     Rx = '(?<=\x8b\x00\xfc)\xf3\x6e';                New = [byte[]](0x31, 0xDB) },                  # xor ebx,ebx
    @{ Name = 'Inline';    Rx = '\x66\xba\x58\x56\xed';                     New = [byte[]](0x83, 0xC8, 0xFF, 0x66, 0x90) } # or eax,-1 ; nop
)
foreach ($r in $script:Rules) { $r.Regex = New-Object Text.RegularExpressions.Regex($r.Rx, [Text.RegularExpressions.RegexOptions]::None) }

function Get-PeSites([byte[]]$b, [int]$Start, [int]$Length) {
    # Returns @{Offset; Name; New} for each backdoor instruction in the PE image at $b[$Start .. $Start+$Length-1].
    # Offsets are relative to $Start. Returns nothing for non-PE data and for kernel drivers.
    $sites = New-Object System.Collections.ArrayList
    if ($Length -lt 0x200 -or $b[$Start] -ne 0x4D -or $b[$Start + 1] -ne 0x5A) { return , $sites }
    $e = [BitConverter]::ToInt32($b, $Start + 0x3C)
    if ($e -le 0 -or $e + 0x108 -gt $Length) { return , $sites }
    if ([BitConverter]::ToUInt32($b, $Start + $e) -ne 0x00004550) { return , $sites }
    $nsec = [BitConverter]::ToUInt16($b, $Start + $e + 6)
    $opt = [BitConverter]::ToUInt16($b, $Start + $e + 20)
    $subsystem = [BitConverter]::ToUInt16($b, $Start + $e + 24 + 68)
    if ($subsystem -eq 1) { return , $sites }                       # native image (kernel driver): never patch
    $sh = $e + 24 + $opt
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $Start + $sh + 40 * $i
        if ($o + 40 -gt $Start + $Length) { break }
        $rsz = [BitConverter]::ToUInt32($b, $o + 16)
        $rptr = [BitConverter]::ToUInt32($b, $o + 20)
        $ch = [BitConverter]::ToUInt32($b, $o + 36)
        if (($ch -band 0x20000000) -eq 0 -or $rsz -eq 0) { continue }
        if ($rptr + $rsz -gt $Length) { $rsz = $Length - $rptr }
        if ($rsz -le 0) { continue }
        $code = $script:Latin1.GetString($b, $Start + $rptr, $rsz)
        foreach ($r in $script:Rules) {
            foreach ($m in $r.Regex.Matches($code)) {
                [void]$sites.Add(@{ Offset = [int]($rptr + $m.Index); Name = $r.Name; New = $r.New })
            }
        }
    }
    return , $sites
}

function Backup-File([string]$file) {
    if ($NoBackup -or $DryRun) { return }
    if (-not (Test-Path -LiteralPath $BackupDir)) { [void](New-Item -ItemType Directory -Path $BackupDir -Force) }
    $dst = Join-Path $BackupDir ((Split-Path -Leaf $file) + '.orig')
    if (-not (Test-Path -LiteralPath $dst)) { Copy-Item -LiteralPath $file -Destination $dst -Force }
}

function Write-Patches([string]$file, $patches) {
    # $patches: list of @{FileOffset; Value}
    if ($DryRun -or $patches.Count -eq 0) { return }
    $attr = [IO.File]::GetAttributes($file)
    if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($file, ($attr -bxor [IO.FileAttributes]::ReadOnly)) }
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        foreach ($p in $patches) { [void]$fs.Seek([long]$p.FileOffset, [IO.SeekOrigin]::Begin); $fs.WriteByte([byte]$p.Value) }
        $fs.Flush()
    } finally { $fs.Close() }
    if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($file, $attr) }
}

function Repair-PeFile([string]$file) {
    $b = [IO.File]::ReadAllBytes($file)
    $sites = Get-PeSites $b 0 $b.Length
    if ($sites.Count -eq 0) { return }
    $patches = New-Object System.Collections.ArrayList
    foreach ($s in $sites) { for ($k = 0; $k -lt $s.New.Length; $k++) { [void]$patches.Add(@{ FileOffset = $s.Offset + $k; Value = $s.New[$k] }) } }
    try {
        Backup-File $file
        Write-Patches $file $patches
        $script:Changed++; $script:Sites += $sites.Count
        Write-Log ("PE   {0}: {1} site(s) {2}" -f $file, $sites.Count, $(if ($DryRun) { 'found (dry run)' } else { 'patched' }))
    } catch {
        Write-Log ("PE   {0}: {1} site(s) NOT patched: {2}" -f $file, $sites.Count, $_.Exception.Message)
    }
}

function Repair-Msi([string]$file) {
    # OLE compound file: walk the FAT, patch every stream that is a user-mode PE image.
    $d = [IO.File]::ReadAllBytes($file)
    if ($d.Length -lt 512 -or [BitConverter]::ToString($d, 0, 8) -ne 'D0-CF-11-E0-A1-B1-1A-E1') { Write-Log "MSI  ${file}: not an OLE compound file, skipped"; return }
    $ss = 1 -shl [BitConverter]::ToUInt16($d, 0x1E)
    $cutoff = [BitConverter]::ToUInt32($d, 0x38)
    $nfat = [BitConverter]::ToUInt32($d, 0x2C)
    $per = [int]($ss / 4)
    $END = [uint32]4294967294; $FREE = [uint32]4294967295
    $difat = New-Object 'System.Collections.Generic.List[uint32]'
    for ($i = 0; $i -lt 109; $i++) { $difat.Add([BitConverter]::ToUInt32($d, 0x4C + 4 * $i)) }
    $nxt = [BitConverter]::ToUInt32($d, 0x44); $ndif = [BitConverter]::ToUInt32($d, 0x48)
    while ($nxt -ne $END -and $nxt -ne $FREE -and $ndif -gt 0) {
        $o = ([long]$nxt + 1) * $ss
        for ($i = 0; $i -lt $per - 1; $i++) { $difat.Add([BitConverter]::ToUInt32($d, $o + 4 * $i)) }
        $nxt = [BitConverter]::ToUInt32($d, $o + 4 * ($per - 1)); $ndif--
    }
    $fat = New-Object 'System.Collections.Generic.List[uint32]'
    for ($f = 0; $f -lt $nfat; $f++) {
        $s = $difat[$f]
        if ($s -eq $END -or $s -eq $FREE) { continue }
        $o = ([long]$s + 1) * $ss
        for ($i = 0; $i -lt $per; $i++) { $fat.Add([BitConverter]::ToUInt32($d, $o + 4 * $i)) }
    }
    function Get-Chain([uint32]$start) {
        $c = New-Object 'System.Collections.Generic.List[uint32]'
        $s = $start
        while ($s -ne $END -and $s -ne $FREE) {
            if ($s -ge $fat.Count -or $c.Count -gt $fat.Count) { throw 'bad FAT chain' }
            $c.Add($s); $s = $fat[[int]$s]
        }
        return , $c
    }
    $patches = New-Object System.Collections.ArrayList
    $streams = 0; $sitesHere = 0
    foreach ($ds in (Get-Chain ([BitConverter]::ToUInt32($d, 0x30)))) {
        $o = ([long]$ds + 1) * $ss
        for ($i = 0; $i -lt $ss; $i += 128) {
            $e = $o + $i
            if ([BitConverter]::ToUInt16($d, $e + 0x40) -eq 0 -or $d[$e + 0x42] -ne 2) { continue }
            $size = if ($ss -eq 4096) { [long][BitConverter]::ToUInt64($d, $e + 0x78) } else { [long][BitConverter]::ToUInt32($d, $e + 0x78) }
            if ($size -lt $cutoff) { continue }
            $chain = Get-Chain ([BitConverter]::ToUInt32($d, $e + 0x74))
            if ($chain.Count -eq 0) { continue }
            $first = ([long]$chain[0] + 1) * $ss
            if ($d[$first] -ne 0x4D -or $d[$first + 1] -ne 0x5A) { continue }
            $st = New-Object byte[] ($chain.Count * $ss)
            for ($k = 0; $k -lt $chain.Count; $k++) { [Buffer]::BlockCopy($d, ([long]$chain[$k] + 1) * $ss, $st, $k * $ss, $ss) }
            $sites = Get-PeSites $st 0 ([int]$size)
            if ($sites.Count -eq 0) { continue }
            $streams++; $sitesHere += $sites.Count
            foreach ($s in $sites) {
                for ($k = 0; $k -lt $s.New.Length; $k++) {
                    $so = $s.Offset + $k
                    $fo = ([long]$chain[[int][Math]::Floor($so / $ss)] + 1) * $ss + ($so % $ss)
                    [void]$patches.Add(@{ FileOffset = $fo; Value = $s.New[$k] })
                }
            }
        }
    }
    if ($patches.Count -eq 0) { Write-Log "MSI  ${file}: nothing to patch (already fixed, or no VMware custom-action DLLs)"; return }
    Backup-File $file
    Write-Patches $file $patches
    $script:Changed++; $script:Sites += $sitesHere
    Write-Log ("MSI  {0}: {1} DLL stream(s), {2} site(s), {3} byte(s) {4}" -f $file, $streams, $sitesHere, $patches.Count, $(if ($DryRun) { 'found (dry run)' } else { 'patched' }))
}

function Get-VMwareToolsProducts {
    $out = @()
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
    if (-not (Test-Path $root)) { return $out }
    foreach ($sid in Get-ChildItem $root -ErrorAction SilentlyContinue) {
        $products = Join-Path $sid.PSPath 'Products'
        if (-not (Test-Path $products)) { continue }
        foreach ($p in Get-ChildItem $products -ErrorAction SilentlyContinue) {
            $ip = Get-ItemProperty (Join-Path $p.PSPath 'InstallProperties') -ErrorAction SilentlyContinue
            if ($ip -and $ip.DisplayName -eq 'VMware Tools') { $out += $ip }
        }
    }
    return $out
}

Write-Log ("start: user {0}, dry run {1}, installed files {2}" -f [Environment]::UserName, [bool]$DryRun, [bool]$InstalledFiles)
$targets = @()
if ($Path) { $targets = $Path }
else {
    $products = Get-VMwareToolsProducts
    if (-not $products) { Write-Log 'VMware Tools is not installed (no MSI product named "VMware Tools"): nothing to do'; exit 0 }
    foreach ($ip in $products) {
        Write-Log ("product: VMware Tools {0}, package {1}, location {2}" -f $ip.DisplayVersion, $ip.LocalPackage, $ip.InstallLocation)
        if ($ip.LocalPackage -and (Test-Path -LiteralPath $ip.LocalPackage)) { $targets += $ip.LocalPackage }
        else { Write-Log 'cached MSI package not found' }
        if ($InstalledFiles -and $ip.InstallLocation -and (Test-Path -LiteralPath $ip.InstallLocation)) {
            $targets += (Get-ChildItem -LiteralPath $ip.InstallLocation -Recurse -File -Include *.exe, *.dll -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
}
foreach ($t in $targets) {
    try {
        $fs = [IO.File]::OpenRead($t); $h = New-Object byte[] 8; [void]$fs.Read($h, 0, 8); $fs.Close()
        if ([BitConverter]::ToString($h, 0, 8) -eq 'D0-CF-11-E0-A1-B1-1A-E1') { Repair-Msi $t } else { Repair-PeFile $t }
    } catch { Write-Log ("ERROR {0}: {1}" -f $t, $_.Exception.Message) }
}
Write-Log ("done: {0} file(s) changed, {1} site(s)" -f $script:Changed, $script:Sites)
exit 0
