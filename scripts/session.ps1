<#
.SYNOPSIS
    The "command" of the Sunshine "Extended Screen" app.

.DESCRIPTION
    Sunshine only runs an app's undo commands when the app stops. A plain
    desktop app never stops by itself: backing out of Moonlight without
    choosing "Quit" would leave the virtual display on. This script stays
    alive while the stream is up and exits when Sunshine logs
    "CLIENT DISCONNECTED". Sunshine then runs "vdisplay.ps1 off".
#>
$script:LogTag = 'session'
. "$PSScriptRoot\Common.ps1"

$logPath = $SunshineLog
$connectTimeout = [TimeSpan]::FromSeconds(60)
$started = Get-Date
$connected = $false

$fs = [IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite, Delete')
$reader = New-Object IO.StreamReader($fs)

# PowerShell takes a few seconds to start, and the client usually connects
# in the meantime. So scan from the line where Sunshine launched this script.
$seen = $reader.ReadToEnd()
$launch = $seen.LastIndexOf('session.ps1"]')
if ($launch -ge 0) {
    $sinceLaunch = $seen.Substring($launch)
    $lastConnect = $sinceLaunch.LastIndexOf('CLIENT CONNECTED')
    $lastDisconnect = $sinceLaunch.LastIndexOf('CLIENT DISCONNECTED')
    if ($lastDisconnect -gt $lastConnect) {
        Write-Log 'Client already disconnected'
        $reader.Dispose()
        exit 0
    }
    $connected = $lastConnect -ge 0
}
Write-Log "Waiting for the stream to end (connected: $connected)"

try {
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) {
            # Sunshine restarted and rewrote its log: the stream is gone.
            if ($fs.Length -lt $fs.Position) { Write-Log 'Sunshine log was reset'; break }
            if (-not $connected -and ((Get-Date) - $started) -gt $connectTimeout) {
                Write-Log 'No client connected within 60s'
                break
            }
            Start-Sleep -Milliseconds 250
            continue
        }
        if ($line -like '*CLIENT CONNECTED*') { $connected = $true; Write-Log 'Client connected' }
        elseif ($line -like '*CLIENT DISCONNECTED*') { Write-Log 'Client disconnected'; break }
    }
} finally {
    $reader.Dispose()
}
exit 0
