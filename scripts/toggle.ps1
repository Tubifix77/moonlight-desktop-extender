<#
.SYNOPSIS
    One-click on/off for the tablet screen (target of the desktop shortcut).

.DESCRIPTION
    on     - starts Sunshine. Connect from the tablet with "Extended Screen".
    off    - stops Sunshine and makes sure the virtual display is gone.
    toggle - whichever of the two applies (default).
#>
param(
    [ValidateSet('toggle', 'on', 'off')]
    [string]$Mode = 'toggle'
)

$script:LogTag = "toggle $Mode"
. "$PSScriptRoot\Common.ps1"

if (-not (Test-IsAdmin)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", $Mode)
    exit
}

function Show-Popup([string]$Text, [int]$Icon = 64) {
    (New-Object -ComObject WScript.Shell).Popup($Text, 4, 'Extended Screen', $Icon) | Out-Null
}

$svc = Get-Service $Config.sunshineService
if ($Mode -eq 'toggle') {
    $Mode = if ($svc.Status -eq 'Running') { 'off' } else { 'on' }
    $script:LogTag = "toggle $Mode"
}

try {
    if ($Mode -eq 'on') {
        # Never start with a stale virtual display left from a crash.
        & "$PSScriptRoot\vdisplay.ps1" off | Out-Null
        if ($svc.Status -ne 'Running') { Start-Service $svc.Name }
        $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(20))
        Write-Log 'Sunshine started'
        Show-Popup "Sunshine is running.`n`nOn the tablet: turn on USB tethering, open Moonlight and pick 'Extended Screen'."
    } else {
        if ($svc.Status -ne 'Stopped') { Stop-Service $svc.Name -Force }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
        Write-Log 'Sunshine stopped'
        & "$PSScriptRoot\vdisplay.ps1" off | Out-Null
        Show-Popup 'Sunshine stopped and the virtual display is off.'
    }
} catch {
    Write-Log "ERROR: $_"
    Show-Popup "Something went wrong:`n$_`n`nSee logs\extender.log" 16
    exit 1
}
