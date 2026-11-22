# Reset the Windows USB/IP client side.
#
# Why this exists: usbip-win2's UDE driver keeps a virtual port per attach and
# retries in the background. If a session is torn down uncleanly, the old port
# survives and a new attach creates a second port pointing at the same busid.
# Both ports then fight over one TCP session (attach -> kick -> attach ...),
# which looks like "it worked for 20 minutes, then reconnect never works".
# The only reliable cure on the client side is: detach every port, wait, then
# attach exactly once.
#
# Usage: double-click reset-usbip.bat, or
#        powershell -NoProfile -ExecutionPolicy Bypass -File reset-usbip.ps1 -Remote 10.77.0.5
param(
    [string]$Remote = '',
    [string]$Busid = '',
    [int]$WaitSeconds = 3,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$UsbipCandidates = @(
    'C:\Program Files\USBip\usbip.exe',
    'C:\Program Files (x86)\USBip\usbip.exe'
)
$Usbip = $UsbipCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Usbip) {
    $cmd = Get-Command usbip.exe -ErrorAction SilentlyContinue
    if ($cmd) { $Usbip = $cmd.Source }
}
if (-not $Usbip) {
    Write-Host "[FAIL] usbip.exe not found. Install usbip-win2 or pass its path."
    exit 1
}

Write-Host "==> usbip: $Usbip"

function Get-Ports {
    $text = (& $Usbip port 2>&1) -join "`n"
    $ports = @()
    # "Port 01: device in use at ..." followed by "-> usbip://IP:PORT/BUSID"
    # NOTE: do not name this $matches, that is an automatic variable in PS.
    $chunks = [regex]::Matches($text, '(?ms)Port\s+(\d+):(.*?)(?=Port\s+\d+:|\z)')
    foreach ($m in $chunks) {
        $num = $m.Groups[1].Value
        $body = $m.Groups[2].Value
        $u = [regex]::Match($body, 'usbip://([^:/\s]+)(?::(\d+))?/(\S+)')
        $ports += [pscustomobject]@{
            Port      = $num
            # Keep the IP only: "usbip attach -r" takes a host, not host:port
            Remote    = if ($u.Success) { $u.Groups[1].Value } else { '' }
            Busid     = if ($u.Success) { $u.Groups[3].Value.TrimEnd('X') } else { '' }
            InUse     = ($body -match 'in use')
        }
    }
    return $ports
}

$before = @(Get-Ports)
Write-Host ""
Write-Host "==> current ports: $($before.Count)"
foreach ($p in $before) {
    Write-Host ("    port {0}  {1}  {2}" -f $p.Port, $p.Remote, $p.Busid)
}

if ($before.Count -eq 0) {
    Write-Host "    (none)"
}

# Remember what to re-attach: prefer explicit args, else the first existing port.
if (-not $Remote -and $before.Count -gt 0) { $Remote = $before[0].Remote }
if (-not $Busid -and $before.Count -gt 0) { $Busid = $before[0].Busid }

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] would detach: $(($before | ForEach-Object { $_.Port }) -join ', ')"
    Write-Host "[DryRun] would attach: $Remote / $Busid"
    exit 0
}

# 1) detach everything
foreach ($p in $before) {
    Write-Host ""
    Write-Host "==> detach port $($p.Port)"
    & $Usbip detach -p $p.Port 2>&1 | ForEach-Object { Write-Host "    $_" }
}

if ($before.Count -gt 0) {
    Write-Host ""
    Write-Host "==> waiting ${WaitSeconds}s for the driver to drop the virtual ports"
    Start-Sleep -Seconds $WaitSeconds
}

$left = @(Get-Ports)
if ($left.Count -gt 0) {
    Write-Host "[WARN] $($left.Count) port(s) still present after detach:"
    foreach ($p in $left) { Write-Host "    port $($p.Port)  $($p.Remote)  $($p.Busid)" }
    Write-Host "       (the driver may still be retrying in the background; continue anyway)"
}

# 2) figure out the busid to attach
if (-not $Remote) {
    Write-Host ""
    $Remote = Read-Host "phone IP (e.g. 10.77.0.5)"
}
if (-not $Remote) {
    Write-Host "[FAIL] no remote IP"
    exit 1
}

if (-not $Busid) {
    Write-Host ""
    Write-Host "==> listing devices on $Remote"
    $listing = (& $Usbip list -r $Remote 2>&1) -join "`n"
    Write-Host $listing
    # usbip-win2 prints "1-33897: GN Hearing ... (16f0:0003)" with a trailing X
    $busids = @([regex]::Matches($listing, '(?m)^\s*([0-9]+-[0-9A-Za-z]+)\s*:') | ForEach-Object { $_.Groups[1].Value })
    if ($busids.Count -eq 0) {
        Write-Host ""
        Write-Host "[FAIL] the phone reported no exportable device."
        Write-Host "       On the phone: make sure the USB device is plugged in and the"
        Write-Host "       USB/IP service is started (the log should say '[设备列表] 回复 1 台')."
        Write-Host "       If it says 0 devices while a session is already established, you"
        Write-Host "       are running an older HAP that only lists idle devices."
        exit 1
    }
    $Busid = $busids[0]
    if ($busids.Count -gt 1) {
        Write-Host ""
        Write-Host "multiple devices:"
        for ($i = 0; $i -lt $busids.Count; $i++) { Write-Host ("  [{0}] {1}" -f $i, $busids[$i]) }
        $pick = Read-Host "pick one (default 0)"
        if ($pick -match '^\d+$' -and [int]$pick -lt $busids.Count) { $Busid = $busids[[int]$pick] }
    }
}

# 3) attach exactly once
Write-Host ""
Write-Host "==> attach $Remote / $Busid"
& $Usbip attach -r $Remote -b $Busid 2>&1 | ForEach-Object { Write-Host "    $_" }

Start-Sleep -Seconds 1
$after = @(Get-Ports)
Write-Host ""
Write-Host "==> ports after reset: $($after.Count)"
foreach ($p in $after) {
    Write-Host ("    port {0}  {1}  {2}  inUse={3}" -f $p.Port, $p.Remote, $p.Busid, $p.InUse)
}

if ($after.Count -eq 1) {
    Write-Host ""
    Write-Host "[OK] exactly one port. That is the only healthy state."
    exit 0
}
if ($after.Count -eq 0) {
    Write-Host ""
    Write-Host "[FAIL] no port attached. Check the phone log around '[导入]'."
    exit 2
}
Write-Host ""
Write-Host "[WARN] $($after.Count) ports still exist. Run this again, or reboot the phone side."
exit 3
