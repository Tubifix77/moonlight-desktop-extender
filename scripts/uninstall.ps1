<#
.SYNOPSIS
    Removes Moonlight Desktop Extender's changes.

.DESCRIPTION
    - Removes the "Extended Screen" app and the output_name / stream_audio
      lines from Sunshine's config (other Sunshine settings are kept).
    - Sets the Sunshine service back to Automatic start (Sunshine's default).
    - Deletes the shortcuts and disables the virtual display.
    - With -RemoveDriver, also uninstalls the Virtual Display Driver.

    Sunshine and Moonlight themselves are left installed.
#>
param(
    [switch]$RemoveDriver
)

$script:LogTag = 'uninstall'
. "$PSScriptRoot\Common.ps1"

if (-not (Test-IsAdmin)) {
    exit (Invoke-Elevated $PSCommandPath @(if ($RemoveDriver) { '-RemoveDriver' }))
}

$utf8 = New-Object Text.UTF8Encoding($false)
$failed = $false
function Step([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { Write-Log "$Name failed: $_"; $script:failed = $true }
}

$confPath = Join-Path $SunshineDir 'config\sunshine.conf'
$appsPath = Join-Path $SunshineDir 'config\apps.json'
$svc = Get-Service $Config.sunshineService -ErrorAction SilentlyContinue
$wasRunning = $svc -and $svc.Status -eq 'Running'

Step 'Stopping Sunshine' {
    if ($wasRunning) {
        Stop-Service $svc.Name -Force
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    }
}

Step 'Disabling the virtual display' {
    $dev = Get-VddDevice
    if ($dev -and (Test-VddEnabled $dev)) { Invoke-Pnputil 'disable-device' $dev.InstanceId }
}

Step 'Cleaning sunshine.conf' {
    if (Test-Path $confPath) {
        $conf = @(Get-Content $confPath | Where-Object { $_ -notmatch '^\s*(output_name|stream_audio)\s*=' })
        [IO.File]::WriteAllLines($confPath, [string[]]$conf, $utf8)
        Write-Log 'Removed output_name and stream_audio from sunshine.conf'
    }
}

Step 'Cleaning apps.json' {
    if (Test-Path $appsPath) {
        $apps = Get-Content $appsPath -Raw | ConvertFrom-Json
        $apps.apps = @($apps.apps | Where-Object { $_.name -ne 'Extended Screen' })
        [IO.File]::WriteAllText($appsPath, ($apps | ConvertTo-Json -Depth 10), $utf8)
        Write-Log "Removed the 'Extended Screen' app"
    }
}

Step 'Restoring service start type' {
    if ($svc) {
        Set-Service $svc.Name -StartupType Automatic
        Write-Log 'Sunshine service set back to Automatic start'
    }
}

Step 'Removing shortcuts' {
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        Remove-Item (Join-Path $dir 'Extended Screen.lnk') -ErrorAction SilentlyContinue
    }
    Write-Log 'Shortcuts removed'
}

if ($RemoveDriver) {
    Step 'Removing the Virtual Display Driver' {
        $dev = Get-VddDevice
        if ($dev) {
            $infName = (Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" |
                    Where-Object { $_.DeviceID -eq $dev.InstanceId }).InfName
            Invoke-Pnputil 'remove-device' $dev.InstanceId
            Write-Log "Removed device $($dev.InstanceId)"
            if ($infName -like 'oem*.inf') {
                $ErrorActionPreference = 'Continue'
                & pnputil.exe /delete-driver $infName /uninstall /force | Out-Host
                Write-Log "Deleted driver package $infName"
            }
        }
        $settingsDir = Split-Path -Parent $Config.vddSettingsPath
        if (Test-Path $settingsDir) {
            Remove-Item $settingsDir -Recurse -Force
            Write-Log "Removed $settingsDir"
        }
    }
}

Step 'Starting Sunshine again' {
    if ($wasRunning) { Start-Service $svc.Name }
}

if ($failed) { Write-Log 'Uninstall finished with errors (see above)'; exit 1 }
Write-Log 'Uninstall finished'
exit 0
