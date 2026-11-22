<#
.SYNOPSIS
    Record what the Windows side does while a USB/IP device is in use.

.DESCRIPTION
    Samples, at fixed intervals, everything that can explain a disconnect:

      tcp   TCP connections from this machine to the phone's port 3240
      port  virtual hub port state (usbip port), only on change
      proc  usbip.exe / wusbip.exe processes and their command lines
      net   network adapter link state and speed
      ping  ICMP reachability of the phone (learned from the TCP peer)
      evt   matching Windows System event log entries
      etw   driver WPP trace (only when started elevated)
      beat  heartbeat every 10 s

    Output is one line per change with a millisecond timestamp, so it can be
    lined up with the HarmonyOS app log. merge-logs.ps1 does that alignment.

    No administrator rights required. Started elevated, it additionally
    captures the driver's WPP/ETW trace into driver.etl.

.PARAMETER Seconds
    Stop after this many seconds. 0 (default) means run until Ctrl+C or
    until stop.flag appears next to this script.

.PARAMETER IntervalMs
    TCP sampling interval in milliseconds. Default 500.

.PARAMETER PhoneIp
    Phone address for the ICMP probe. When empty it is learned from the
    first established TCP connection to port 3240.

.EXAMPLE
    .\usbip-monitor.ps1
    .\usbip-monitor.ps1 -Seconds 1800 -PhoneIp 192.168.1.5
#>
[CmdletBinding()]
param(
    [int]$IntervalMs  = 500,
    [int]$Seconds     = 0,
    [int]$RemotePort  = 3240,
    [string]$PhoneIp  = '',
    [string]$UsbipExe = 'C:\Program Files\USBip\usbip.exe',
    [string]$OutDir   = ''
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- plumbing --

$script:Root    = if ($OutDir) { $OutDir } else { Join-Path $PSScriptRoot 'logs' }
$script:Stamp   = (Get-Date).ToString('yyyyMMdd-HHmmss')
$script:RunDir  = Join-Path $script:Root $script:Stamp
$script:LogPath = Join-Path $script:RunDir 'pc.log'
$script:StopFlag = Join-Path $PSScriptRoot 'stop.flag'
$script:EventCount = 0
$script:EtwSession = ''
$script:EtwFile = ''
$script:PhoneIp = $PhoneIp

New-Item -ItemType Directory -Force -Path $script:RunDir | Out-Null
$script:Writer = New-Object System.IO.StreamWriter($script:LogPath, $false, (New-Object System.Text.UTF8Encoding($false)))
$script:Writer.AutoFlush = $true

function Write-Event {
    param(
        [string]$Tag,
        [string]$Message,
        [string]$Color = 'Gray'
    )
    $now  = Get-Date
    $line = $now.ToString('yyyy-MM-dd HH:mm:ss.fff') + ' [' + $Tag + '] ' + $Message
    $script:Writer.WriteLine($line)
    $script:EventCount++
    Write-Host ($now.ToString('HH:mm:ss.fff') + '  ' + $Tag.PadRight(4) + '  ' + $Message) -ForegroundColor $Color
}

function Write-Banner {
    param([string]$Text, [string]$Color = 'White')
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor $Color
    Write-Host ''
}

# ------------------------------------------------------------------ probes --

function Get-TcpMap {
    $map = @{}
    $conns = Get-NetTCPConnection -RemotePort $script:RemotePort -ErrorAction SilentlyContinue
    if ($null -eq $conns) { return $map }
    foreach ($c in @($conns)) {
        $k = ('{0}:{1}' -f $c.LocalAddress, $c.LocalPort)
        $map[$k] = $c
    }
    return $map
}

function Get-PortSnapshot {
    if (-not (Test-Path $script:UsbipExe)) { return '' }
    $raw = & $script:UsbipExe port 2>&1 | Out-String
    if ($null -eq $raw) { return '' }
    $txt = ($raw -replace "`r", '').Trim()
    return $txt
}

function Get-ProcMap {
    $map = @{}
    $procs = Get-CimInstance Win32_Process -Filter "Name='usbip.exe' OR Name='wusbip.exe'" -ErrorAction SilentlyContinue
    if ($null -eq $procs) { return $map }
    foreach ($p in @($procs)) {
        $map[[int]$p.ProcessId] = [string]$p.CommandLine
    }
    return $map
}

function Get-NetMap {
    $map = @{}
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    if ($null -eq $adapters) { return $map }
    foreach ($a in @($adapters)) {
        $map[[string]$a.Name] = ('{0}/{1}' -f $a.Status, $a.LinkSpeed)
    }
    return $map
}

function Get-WlanSignal {
    # netsh output is localised, so match loosely and only trust the numbers.
    $raw = & netsh wlan show interfaces 2>$null | Out-String
    if (-not $raw) { return $null }
    if ($raw -notmatch '信号|Signal') { return $null }
    if ($raw -notmatch '(\d{1,3})%') { return $null }
    $pct = [int]$Matches[1]
    $connected = $raw -match '已连接|Connected|connected'
    return [pscustomobject]@{ Pct = $pct; Connected = $connected }
}

$script:Pinger = New-Object System.Net.NetworkInformation.Ping

function Invoke-PingProbe {
    param([string]$Ip)
    if (-not $Ip) { return 'n/a' }
    try {
        $reply = $script:Pinger.Send($Ip, 900)
        return [string]$reply.Status
    } catch {
        return 'Exception'
    }
}

# ------------------------------------------------------------------- setup --

if (Test-Path $script:StopFlag) { Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Banner 'USB/IP  PC-side recorder' 'Cyan'
Write-Host ('  output : ' + $script:LogPath) -ForegroundColor DarkGray
Write-Host ('  run    : until Ctrl+C' + $(if ($Seconds -gt 0) { ' or ' + $Seconds + 's' } else { '' })) -ForegroundColor DarkGray
Write-Host '  tip    : reproduce the problem now, then press Ctrl+C to stop and merge' -ForegroundColor DarkGray
Write-Host ''

$nowLocal = Get-Date
$nowUtc   = $nowLocal.ToUniversalTime()
Write-Event 'sys' ('host=' + $env:COMPUTERNAME + ' os=' + [System.Environment]::OSVersion.Version.ToString())
Write-Event 'sys' ('clock local=' + $nowLocal.ToString('yyyy-MM-dd HH:mm:ss.fff') + ' utc=' + $nowUtc.ToString('yyyy-MM-dd HH:mm:ss.fff') + ' tz=' + [TimeZoneInfo]::Local.Id)
Write-Event 'sys' ('elevated=' + $isAdmin + ' intervalMs=' + $IntervalMs + ' remotePort=' + $RemotePort)

if (Test-Path $script:UsbipExe) {
    $ver = (& $script:UsbipExe --version 2>&1 | Out-String).Trim()
    Write-Event 'sys' ('usbip.exe ' + $ver + ' @ ' + $script:UsbipExe)
} else {
    Write-Event 'sys' ('usbip.exe NOT found at ' + $script:UsbipExe) 'Yellow'
}

$svc = Get-Service usbip2_ude -ErrorAction SilentlyContinue
Write-Event 'sys' ('service usbip2_ude: ' + $(if ($svc) { $svc.Status.ToString() } else { 'absent' }))

$drv = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\usbip2_ude\Parameters' -ErrorAction SilentlyContinue
if ($null -ne $drv) {
    Write-Event 'sys' ('driver: ReattachMaxAttempts=' + $drv.ReattachMaxAttempts + ' FirstDelay=' + $drv.ReattachFirstDelay + ' MaxDelay=' + $drv.ReattachMaxDelay)
    Write-Event 'sys' ('driver: TCP_KEEPIDLE=' + $drv.TCP_KEEPIDLE + ' TCP_KEEPINTVL=' + $drv.TCP_KEEPINTVL + ' TCP_KEEPCNT=' + $drv.TCP_KEEPCNT)
}

$adaptersNow = Get-NetAdapter -ErrorAction SilentlyContinue
if ($null -ne $adaptersNow) {
    foreach ($a in @($adaptersNow)) {
        if ($a.Status -eq 'Up') {
            Write-Event 'net' ('up: ' + $a.Name + ' ' + $a.LinkSpeed + ' mac=' + $a.MacAddress)
        }
    }
}

$portNow = Get-PortSnapshot
if ($portNow) {
    Write-Event 'port' ('baseline ports: ' + (($portNow -split "`n") -join ' | '))
} else {
    Write-Event 'port' 'baseline: no imported device'
}

# Optional driver trace (needs elevation).
if ($isAdmin) {
    $script:EtwFile    = Join-Path $script:RunDir 'driver.etl'
    $script:EtwSession = 'usbiplog'
    & logman stop $script:EtwSession -ets 2>$null | Out-Null
    $null = & logman create trace $script:EtwSession -p '{ed18c9c5-8322-48ae-bf78-d01d898a1562}' 0xFFFF 0xFF -o $script:EtwFile -ets 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Event 'etw' 'driver WPP trace started (flags=0xFFFF level=0xFF)' 'Cyan'
    } else {
        Write-Event 'etw' 'driver WPP trace could not start' 'Yellow'
        $script:EtwSession = ''
    }
} else {
    Write-Event 'etw' 'skipped (not elevated) - TCP/port/proc timeline still complete'
}

# ------------------------------------------------------------------- state --

$prevTcp  = @{}
$prevPort = $portNow
$prevProc = Get-ProcMap
$prevNet  = Get-NetMap
$lastEvt  = (Get-Date).AddSeconds(-5)
$clipHash = ''
$prevWlanPct  = -1
$prevWlanConn = $null

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$nextTcp  = 0
$nextPort = 0
$nextProc = 0
$nextNet  = 0
$nextEvt  = 0
$nextPing = 0
$nextBeat = 0
$nextClip = 0
$pingUp   = $true

Write-Banner 'recording...' 'Green'

try {
    while ($true) {
        $ms = $sw.ElapsedMilliseconds
        if ($Seconds -gt 0 -and $ms -ge ($Seconds * 1000)) { break }
        if (Test-Path $script:StopFlag) { break }

        # ---- TCP connections to the phone ----
        if ($ms -ge $nextTcp) {
            $nextTcp = $ms + $IntervalMs
            $cur = Get-TcpMap
            foreach ($k in @($cur.Keys)) {
                $c = $cur[$k]
                if (-not $prevTcp.ContainsKey($k)) {
                    $peer = ('{0}:{1}' -f $c.RemoteAddress, $c.RemotePort)
                    $pn = ''
                    if ($c.OwningProcess) {
                        $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
                        if ($pr) { $pn = $pr.ProcessName }
                    }
                    Write-Event 'tcp' ('+ ' + $k + ' -> ' + $peer + ' ' + $c.State + ' pid=' + $c.OwningProcess + '/' + $pn) 'Green'
                    if (-not $script:PhoneIp -and $c.RemoteAddress) {
                        $script:PhoneIp = [string]$c.RemoteAddress
                        Write-Event 'sys' ('phone ip learned: ' + $script:PhoneIp) 'Cyan'
                    }
                } elseif ($prevTcp[$k].State -ne $c.State) {
                    Write-Event 'tcp' ('~ ' + $k + ' ' + $prevTcp[$k].State + ' -> ' + $c.State) 'Yellow'
                }
            }
            foreach ($k in @($prevTcp.Keys)) {
                if (-not $cur.ContainsKey($k)) {
                    $was = $prevTcp[$k]
                    Write-Event 'tcp' ('- ' + $k + ' (last state ' + $was.State + ')') 'Red'
                }
            }
            $prevTcp = $cur
        }

        # ---- virtual hub ports ----
        if ($ms -ge $nextPort) {
            $nextPort = $ms + 1000
            $snap = Get-PortSnapshot
            if ($snap -ne $prevPort) {
                if ($snap) {
                    Write-Event 'port' ('change: ' + (($snap -split "`n") -join ' | ')) 'Magenta'
                } else {
                    Write-Event 'port' 'change: no imported device' 'Magenta'
                }
                $prevPort = $snap
            }
        }

        # ---- attach helper processes ----
        if ($ms -ge $nextProc) {
            $nextProc = $ms + 2000
            $cur = Get-ProcMap
            foreach ($p in @($cur.Keys)) {
                if (-not $prevProc.ContainsKey($p)) {
                    Write-Event 'proc' ('+ pid=' + $p + ' ' + $cur[$p]) 'Cyan'
                }
            }
            foreach ($p in @($prevProc.Keys)) {
                if (-not $cur.ContainsKey($p)) {
                    Write-Event 'proc' ('- pid=' + $p + ' exited') 'DarkCyan'
                }
            }
            $prevProc = $cur
        }

        # ---- adapter link state ----
        if ($ms -ge $nextNet) {
            $nextNet = $ms + 5000
            $cur = Get-NetMap
            foreach ($n in @($cur.Keys)) {
                if (-not $prevNet.ContainsKey($n)) {
                    Write-Event 'net' ('+ ' + $n + ' ' + $cur[$n]) 'Green'
                } elseif ($prevNet[$n] -ne $cur[$n]) {
                    Write-Event 'net' ('~ ' + $n + ' ' + $prevNet[$n] + ' -> ' + $cur[$n]) 'Yellow'
                }
            }
            foreach ($n in @($prevNet.Keys)) {
                if (-not $cur.ContainsKey($n)) {
                    Write-Event 'net' ('- ' + $n) 'Red'
                }
            }
            $prevNet = $cur

            # WiFi signal: a 15 point step or any change of link state is
            # worth a line. Slow drift accumulates until it crosses 15.
            $wlan = Get-WlanSignal
            if ($null -ne $wlan) {
                $why = ''
                if ($null -eq $prevWlanConn) {
                    $why = 'baseline'
                } elseif ($wlan.Connected -ne $prevWlanConn) {
                    $why = 'link'
                } elseif ($prevWlanPct -ge 0 -and [math]::Abs($wlan.Pct - $prevWlanPct) -ge 15) {
                    $why = 'signal'
                }
                if ($why) {
                    $color = 'Cyan'
                    if (-not $wlan.Connected) { $color = 'Red' }
                    else { if ($why -eq 'signal' -and $wlan.Pct -lt 50) { $color = 'Yellow' } }
                    Write-Event 'wlan' ($why + ' conn=' + $wlan.Connected + ' signal=' + $wlan.Pct + '%') $color
                    $prevWlanConn = $wlan.Connected
                    $prevWlanPct  = $wlan.Pct
                }
            }
        }

        # ---- ICMP reachability of the phone ----
        if ($ms -ge $nextPing) {
            $nextPing = $ms + 2000
            if ($script:PhoneIp -and $prevTcp.Count -gt 0) {
                $st = Invoke-PingProbe $script:PhoneIp
                $ok = ($st -eq 'Success')
                if ($ok -ne $pingUp) {
                    Write-Event 'ping' ('phone ' + $script:PhoneIp + ' -> ' + $st) $(if ($ok) { 'Green' } else { 'Red' })
                    $pingUp = $ok
                }
            }
        }

        # ---- Windows event log ----
        if ($ms -ge $nextEvt) {
            $nextEvt = $ms + 3000
            $evts = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $lastEvt } -MaxEvents 60 -ErrorAction SilentlyContinue
            if ($null -ne $evts) {
                foreach ($e in @($evts)) {
                    if ($e.TimeCreated -gt $lastEvt) { $lastEvt = $e.TimeCreated }
                    $prov = [string]$e.ProviderName
                    if ($prov -match 'usbip') {
                        $msg = ([string]$e.Message -split "`r?`n")[0]
                        if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 180) }
                        Write-Event 'evt' ('[' + $prov + '] id=' + $e.Id + ' ' + $msg) 'DarkYellow'
                    }
                }
            }
        }

        # ---- clipboard pickup of the app log ----
        if ($ms -ge $nextClip) {
            $nextClip = $ms + 10000
            try {
                $txt = Get-Clipboard -Raw -ErrorAction Stop
                if ($txt -and $txt -match 'HarmonyOS USB/IP') {
                    $h = [string]$txt.GetHashCode()
                    if ($h -ne $clipHash) {
                        $clipHash = $h
                        $dst = Join-Path $PSScriptRoot 'app.log'
                        [System.IO.File]::WriteAllText($dst, $txt, (New-Object System.Text.UTF8Encoding($true)))
                        Write-Event 'sys' ('app log picked up from clipboard -> ' + $dst) 'Green'
                    }
                }
            } catch { }
        }

        # ---- heartbeat ----
        if ($ms -ge $nextBeat) {
            $nextBeat = $ms + 10000
            $est = 0
            foreach ($k in @($prevTcp.Keys)) {
                if ($prevTcp[$k].State -eq 'Established') { $est++ }
            }
            Write-Event 'beat' ('alive up=' + [int]($ms / 1000) + 's established=' + $est + ' events=' + $script:EventCount) 'DarkGray'
        }

        Start-Sleep -Milliseconds 100
    }
}
finally {
    if ($script:EtwSession) {
        & logman stop $script:EtwSession -ets 2>$null | Out-Null
        if (Test-Path $script:EtwFile) {
            $xml = Join-Path $script:RunDir 'driver.xml'
            & tracerpt $script:EtwFile -o $xml -of XML -y 2>$null | Out-Null
            Write-Event 'etw' ('driver trace saved: ' + $xml) 'Cyan'
        }
    }
    Write-Event 'sys' ('recorder stopped, ' + $script:EventCount + ' events, ' + [int]($sw.Elapsed.TotalSeconds) + 's')
    $script:Writer.Close()
    if (Test-Path $script:StopFlag) { Remove-Item $script:StopFlag -Force -ErrorAction SilentlyContinue }

    $merge = Join-Path $PSScriptRoot 'merge-logs.ps1'
    if (Test-Path $merge) {
        Write-Banner 'merging with the app log...' 'Cyan'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $merge -PcLog $script:LogPath
    }
}
