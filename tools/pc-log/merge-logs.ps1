<#
.SYNOPSIS
    Merge the Windows-side recorder log with the HarmonyOS app log into one
    time-ordered timeline, and print what the timeline implies.

.DESCRIPTION
    Both logs carry a local wall-clock timestamp with milliseconds, so the
    merge is a straight sort. The summary then classifies every disconnect:

      FIN   the peer closed the connection gracefully (state moved through
            FinWait/CloseWait before the socket disappeared)
      RST   the socket vanished while still Established - abnormal teardown
            (process killed, USB/IP stack error, or a network path that
            silently dropped the flow)
      NET   an adapter link change or a failed ICMP probe happened within a
            few seconds of the drop, so the network layer is the suspect

    Clock skew between the two machines is reported as raw candidates rather
    than guessed at: pair up a PC '+' line with the app line that should
    describe the same instant, and the delta is the skew.

.PARAMETER PcLog
    pc.log produced by usbip-monitor.ps1. Defaults to the newest one.

.PARAMETER AppLog
    App log exported with the copy button. Defaults to app.log next to this
    script.

.PARAMETER OutFile
    Defaults to merged.log in the same folder as the PC log.
#>
[CmdletBinding()]
param(
    [string]$PcLog   = '',
    [string]$AppLog  = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------ locate input --

if (-not $PcLog) {
    $root = Join-Path $PSScriptRoot 'logs'
    if (Test-Path $root) {
        $newest = Get-ChildItem $root -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($newest) { $PcLog = Join-Path $newest.FullName 'pc.log' }
    }
}
if (-not $PcLog -or -not (Test-Path $PcLog)) {
    Write-Host 'pc.log not found. Run usbip-monitor.ps1 first.' -ForegroundColor Red
    exit 1
}

if (-not $AppLog) {
    $candidate = Join-Path $PSScriptRoot 'app.log'
    if (Test-Path $candidate) { $AppLog = $candidate }
}

if (-not $OutFile) {
    $OutFile = Join-Path (Split-Path $PcLog -Parent) 'merged.log'
}

# ---------------------------------------------------------------- parsing --

function ConvertTo-Dt {
    param([string]$y, [string]$mo, [string]$d, [string]$h, [string]$mi, [string]$s, [string]$ms)
    return [datetime]::new([int]$y, [int]$mo, [int]$d, [int]$h, [int]$mi, [int]$s, [int]$ms)
}

$rows = New-Object System.Collections.ArrayList

# --- PC side: 2026-11-22 20:06:17.123 [tcp] message
$pcTimes = New-Object System.Collections.ArrayList
$pcConnAdd = New-Object System.Collections.ArrayList
$pcConnDrop = New-Object System.Collections.ArrayList
$pcPortChange = New-Object System.Collections.ArrayList
$pcNetBad = New-Object System.Collections.ArrayList
$pcPingBad = New-Object System.Collections.ArrayList
$pcWlan = New-Object System.Collections.ArrayList

$pcLines = Get-Content $PcLog -Encoding UTF8 -ErrorAction SilentlyContinue
$lastState = @{}
$sockLeave = @{}
foreach ($line in $pcLines) {
    if ($line -match '^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) \[(\w+)\] (.*)$') {
        $t = ConvertTo-Dt $Matches[1] $Matches[2] $Matches[3] $Matches[4] $Matches[5] $Matches[6] $Matches[7]
        $tag = $Matches[8]
        $msg = $Matches[9]
        $null = $rows.Add([pscustomobject]@{ T = $t; Src = 'PC'; Tag = $tag; Msg = $msg })
        $null = $pcTimes.Add($t)

        if ($tag -eq 'tcp') {
            if ($msg -match '^\+ (\S+) -> (\S+) (\S+)') {
                $sock = $Matches[1]
                $null = $pcConnAdd.Add([pscustomobject]@{ T = $t; Local = $sock; Peer = $Matches[2]; State = $Matches[3] })
            } elseif ($msg -match '^~ (\S+) (\S+) -> (\S+)') {
                $sock = $Matches[1]
                $from = $Matches[2]
                $to   = $Matches[3]
                # The instant the socket stops being Established is the real
                # teardown moment. The later '-' line is only the kernel
                # draining TIME_WAIT, which can be two minutes afterwards.
                if ($from -eq 'Established' -and -not $sockLeave.ContainsKey($sock)) {
                    $sockLeave[$sock] = $t
                }
                $lastState[$sock] = $to
            } elseif ($msg -match '^- (\S+) \(last state (\S+)\)') {
                $sock = $Matches[1]
                $st   = $Matches[2]
                if ($lastState.ContainsKey($sock)) { $st = $lastState[$sock] }
                if ($sockLeave.ContainsKey($sock)) { $leave = $sockLeave[$sock] } else { $leave = $t }
                $null = $pcConnDrop.Add([pscustomobject]@{ T = $leave; Gone = $t; Local = $sock; LastState = $st })
            }
        } elseif ($tag -eq 'port' -and $msg -match '^change:') {
            $null = $pcPortChange.Add([pscustomobject]@{ T = $t; Msg = $msg })
        } elseif ($tag -eq 'net' -and ($msg -match '^~' -or $msg -match '^-')) {
            $null = $pcNetBad.Add([pscustomobject]@{ T = $t; Msg = $msg })
        } elseif ($tag -eq 'wlan') {
            $null = $pcWlan.Add([pscustomobject]@{ T = $t; Msg = $msg })
            if ($msg -match 'conn=False') {
                $null = $pcNetBad.Add([pscustomobject]@{ T = $t; Msg = 'wifi disconnected' })
            }
        } elseif ($tag -eq 'ping' -and $msg -match '-> (?!Success)(\w+)') {
            $null = $pcPingBad.Add([pscustomobject]@{ T = $t; Msg = $msg })
        }
    }
}

# --- App side: 17:24:49.851 message, date taken from the export header
$appBase = $null
$appLines = @()
if ($AppLog -and (Test-Path $AppLog)) {
    $appLines = Get-Content $AppLog -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $appLines) {
        if ($line -match '导出时间\s+(\d{4})-(\d{1,2})-(\d{1,2})') {
            $appBase = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 0, 0, 0, 0)
            break
        }
    }
    if (-not $appBase) { $appBase = (Get-Date).Date }

    $inBody = $false
    foreach ($line in $appLines) {
        if ($line -match '^\s*---\s*日志\s*---') { $inBody = $true; continue }
        if (-not $inBody) { continue }
        if ($line -match '^(\d{2}):(\d{2}):(\d{2})\.(\d{3}) (.*)$') {
            $t = $appBase.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2]).AddSeconds([int]$Matches[3]).AddMilliseconds([int]$Matches[4])
            $null = $rows.Add([pscustomobject]@{ T = $t; Src = 'APP'; Tag = ''; Msg = $Matches[5] })
        }
    }
}

if ($rows.Count -eq 0) {
    Write-Host 'nothing parsed - check the log formats' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------- merge & out --

$sorted = $rows | Sort-Object T

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine('===== USB/IP merged timeline =====')
$null = $sb.AppendLine('pc.log  : ' + $PcLog)
if ($AppLog -and (Test-Path $AppLog)) {
    $null = $sb.AppendLine('app.log : ' + $AppLog)
} else {
    $null = $sb.AppendLine('app.log : (not provided - PC side only)')
}
$null = $sb.AppendLine('note    : both sides use local wall clock; if the two machines are not')
$null = $sb.AppendLine('          NTP-synced, timestamps may be offset by a few seconds.')
$null = $sb.AppendLine('')

foreach ($r in $sorted) {
    $flag = ' '
    $body = $r.Msg
    if ($r.Src -eq 'PC') {
        $body = '[' + $r.Tag + '] ' + $r.Msg
        if ($r.Tag -eq 'tcp' -or $r.Tag -eq 'port' -or $r.Tag -eq 'wlan' -or $r.Tag -eq 'net' -or $r.Tag -eq 'ping') {
            $flag = '*'
        }
    } else {
        if ($r.Msg -match '导入|绑定|解绑|孤儿|拒绝|统计|保活|失败|错误|断开|客户端') { $flag = '*' }
    }
    $pad = if ($r.Src -eq 'PC') { 'PC ' } else { 'APP' }
    $null = $sb.AppendLine(('{0}{1}  {2}  {3}' -f $flag, $r.T.ToString('HH:mm:ss.fff'), $pad, $body))
}

# ---------------------------------------------------------------- analysis --

$null = $sb.AppendLine('')
$null = $sb.AppendLine('===== what the timeline says =====')

$pcFrom = if ($pcTimes.Count) { ($pcTimes | Measure-Object -Minimum).Minimum } else { $null }
$pcTo   = if ($pcTimes.Count) { ($pcTimes | Measure-Object -Maximum).Maximum } else { $null }
if ($pcFrom) {
    $null = $sb.AppendLine(('PC  window : {0:HH:mm:ss} - {1:HH:mm:ss}  ({2:n0} s)' -f $pcFrom, $pcTo, ($pcTo - $pcFrom).TotalSeconds))
}
if ($appLines.Count) {
    $appRows = $sorted | Where-Object { $_.Src -eq 'APP' }
    if ($appRows) {
        $a0 = ($appRows | Select-Object -First 1).T
        $a1 = ($appRows | Select-Object -Last 1).T
        $null = $sb.AppendLine(('APP window: {0:HH:mm:ss} - {1:HH:mm:ss}  ({2:n0} s)' -f $a0, $a1, ($a1 - $a0).TotalSeconds))
    }
}

$null = $sb.AppendLine('')
$null = $sb.AppendLine(('connections opened : {0}' -f $pcConnAdd.Count))
$null = $sb.AppendLine(('connections dropped: {0}' -f $pcConnDrop.Count))
$null = $sb.AppendLine(('port state changes : {0}' -f $pcPortChange.Count))

if ($pcConnAdd.Count) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('-- connect / disconnect sequence --')
    $null = $sb.AppendLine('   LOCAL-FIN : this PC closed first  (the client gave up)')
    $null = $sb.AppendLine('   PEER-FIN  : the phone closed first (the server dropped it)')
    $null = $sb.AppendLine('   RST       : no FIN handshake, abnormal teardown')
    foreach ($a in $pcConnAdd) {
        $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  up    {1} -> {2} ({3})' -f $a.T, $a.Local, $a.Peer, $a.State))
    }
    foreach ($d in $pcConnDrop) {
        $verdict = 'unknown(' + $d.LastState + ')'
        if ($d.LastState -match '^FinWait|^TimeWait') { $verdict = 'LOCAL-FIN' }
        elseif ($d.LastState -match '^CloseWait|^LastAck') { $verdict = 'PEER-FIN' }
        elseif ($d.LastState -eq 'Established') { $verdict = 'RST' }
        $lived = ''
        $up = $pcConnAdd | Where-Object { $_.Local -eq $d.Local -and $_.T -le $d.T } | Sort-Object T | Select-Object -Last 1
        if ($up) { $lived = ('  lived {0:n1}s' -f ($d.T - $up.T).TotalSeconds) }
        $extra = ''
        foreach ($n in $pcNetBad) {
            if ([math]::Abs(($n.T - $d.T).TotalSeconds) -le 8) { $extra = ' + adapter link change'; break }
        }
        foreach ($p in $pcPingBad) {
            if ([math]::Abs(($p.T - $d.T).TotalSeconds) -le 8) { $extra = ' + ICMP failed'; break }
        }
        $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  down  {1} last={2} => {3}{4}{5}' -f $d.T, $d.Local, $d.LastState, $verdict, $lived, $extra))
    }

    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('-- gap between a drop and the next connect --')
    for ($i = 0; $i -lt $pcConnDrop.Count; $i++) {
        $drop = $pcConnDrop[$i]
        $next = $pcConnAdd | Where-Object { $_.T -gt $drop.T } | Sort-Object T | Select-Object -First 1
        if ($next) {
            $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  +{1,6:n1}s  reconnect' -f $drop.T, ($next.T - $drop.T).TotalSeconds))
        } else {
            $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  no reconnect before the log ends' -f $drop.T))
        }
    }
}

if ($pcPortChange.Count) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('-- virtual port changes --')
    foreach ($p in $pcPortChange) {
        $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  {1}' -f $p.T, $p.Msg))
    }
}

if ($pcWlan.Count) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('-- wifi link / signal --')
    foreach ($w in $pcWlan) {
        $null = $sb.AppendLine(('{0:HH:mm:ss.fff}  {1}' -f $w.T, $w.Msg))
    }
}

# Clock skew candidates: pair each PC connect with the nearest app line that
# mentions an import/bind, and report the delta. Same-instant events should
# land on the same row, so a consistent delta is a clock offset.
if ($appLines.Count -and $pcConnAdd.Count) {
    $appMarks = $sorted | Where-Object { $_.Src -eq 'APP' -and $_.Msg -match '导入|绑定|客户端' }
    if ($appMarks) {
        $null = $sb.AppendLine('')
        $null = $sb.AppendLine('-- clock skew candidates (PC connect vs app import line) --')
        foreach ($a in $pcConnAdd) {
            $best = $null
            $bestDelta = 999
            foreach ($m in $appMarks) {
                $d = ($m.T - $a.T).TotalSeconds
                if ([math]::Abs($d) -lt $bestDelta) { $bestDelta = [math]::Abs($d); $best = $m }
            }
            if ($best -and $bestDelta -le 120) {
                $null = $sb.AppendLine(('{0:HH:mm:ss.fff} vs {1:HH:mm:ss.fff}  delta={2:+0.0;-0.0}s  {3}' -f $a.T, $best.T, ($best.T - $a.T).TotalSeconds, $best.Msg))
            }
        }
        $null = $sb.AppendLine('a consistent delta means the two machines clocks are offset by it;')
        $null = $sb.AppendLine('add that offset to the app timestamps when reading the timeline above.')
    }
}

# --------------------------------------------------------------- write out --

$utf8bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($OutFile, $sb.ToString(), $utf8bom)

Write-Host ''
Write-Host ('merged -> ' + $OutFile) -ForegroundColor Green
Write-Host ''

# short console preview
$preview = $sb.ToString() -split "`r?`n"
$lines = $preview.Count
$head = [Math]::Min(60, $lines)
for ($i = 0; $i -lt $head; $i++) { Write-Host $preview[$i] }
if ($lines -gt $head) {
    Write-Host ('... (' + ($lines - $head) + ' more lines in the file)') -ForegroundColor DarkGray
}
