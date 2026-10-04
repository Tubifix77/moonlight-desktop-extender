<#
.SYNOPSIS
    Sets up Moonlight Desktop Extender. Safe to re-run at any time
    (after a Sunshine update, a new PC, or to change the options).

.DESCRIPTION
    1. Installs Sunshine and the Virtual Display Driver with winget if missing.
    2. Installs the virtual display device and learns its Sunshine device_id,
       which becomes Sunshine's output_name. While the virtual display is off,
       Sunshine falls back to the main monitor, so the normal "Desktop" app
       still mirrors.
    3. Turns off Sunshine audio streaming (unless -StreamAudio), so the PC
       keeps its sound.
    4. Adds the "Extended Screen" app to Sunshine.
    5. Sets the Sunshine service to Manual start.
    6. Creates "Extended Screen" on/off shortcuts (Desktop + Start menu).
    7. Leaves the virtual display disabled.

.PARAMETER Position
    Where the tablet screen sits relative to the main monitor.
.PARAMETER Align
    Alignment along that edge.
.PARAMETER StreamAudio
    Also send the PC's sound to the tablet (Sunshine then takes over the
    default audio device while streaming).
.PARAMETER NoPrereqs
    Don't install missing Sunshine / Virtual Display Driver with winget.

.EXAMPLE
    .\install.ps1 -Position right
#>
param(
    [ValidateSet('below', 'above', 'left', 'right')]
    [string]$Position,
    [ValidateSet('center', 'start', 'end')]
    [string]$Align,
    [switch]$StreamAudio,
    [switch]$NoPrereqs
)

$script:LogTag = 'install'
. "$PSScriptRoot\Common.ps1"

if (-not (Test-IsAdmin)) {
    $fwd = @()
    if ($Position) { $fwd += '-Position', $Position }
    if ($Align) { $fwd += '-Align', $Align }
    if ($StreamAudio) { $fwd += '-StreamAudio' }
    if ($NoPrereqs) { $fwd += '-NoPrereqs' }
    exit (Invoke-Elevated $PSCommandPath $fwd)
}

Start-Transcript -Path (Join-Path $LogDir 'install.log') -Force | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)

function Backup-Once($Path) {
    if ((Test-Path $Path) -and -not (Test-Path "$Path.pre-extender")) {
        Copy-Item $Path "$Path.pre-extender"
        Write-Log "Backed up $Path"
    }
}

function Install-WithWinget([string]$Id) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget is not available. Install '$Id' manually, then run this again."
    }
    Write-Log "Installing $Id with winget (this can take a minute)"
    $ErrorActionPreference = 'Continue'
    & winget.exe install --id $Id -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "winget install $Id failed (exit $LASTEXITCODE)" }
}

function Find-VddPackage {
    $roots = @("$env:LOCALAPPDATA\Microsoft\WinGet\Packages", "$env:ProgramFiles\WinGet\Packages")
    foreach ($r in $roots) {
        $p = Get-ChildItem $r -Directory -Filter 'VirtualDrivers.Virtual-Display-Driver*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($p -and (Test-Path (Join-Path $p.FullName 'SignedDrivers\x86\VDD\MttVDD.inf'))) { return $p.FullName }
    }
    $null
}

function Read-SharedFile([string]$Path) {
    # Sunshine keeps its log open for writing, so ReadAllText would fail.
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}

try {
    # --- 0. options ----------------------------------------------------------
    $cfgPath = Join-Path $ProjectRoot 'config.json'
    if ($Position -or $Align -or $PSBoundParameters.ContainsKey('StreamAudio')) {
        if ($Position) { $Config.position = $Position }
        if ($Align) { $Config.align = $Align }
        if ($PSBoundParameters.ContainsKey('StreamAudio')) { $Config.streamAudio = [bool]$StreamAudio }
        [IO.File]::WriteAllText($cfgPath, ($Config | ConvertTo-Json), $utf8)
    }
    Write-Log "Options: position=$($Config.position) align=$($Config.align) streamAudio=$($Config.streamAudio)"

    # --- 1. prerequisites ----------------------------------------------------
    if (-not (Get-Service $Config.sunshineService -ErrorAction SilentlyContinue)) {
        if ($NoPrereqs) { throw 'Sunshine is not installed (https://github.com/LizardByte/Sunshine)' }
        Install-WithWinget 'LizardByte.Sunshine'
        if (-not (Get-Service $Config.sunshineService -ErrorAction SilentlyContinue)) {
            throw 'Sunshine installed, but its service was not found. Reboot and run this again.'
        }
    }
    $SunshineDir = Get-SunshineDir
    $SunshineLog = Join-Path $SunshineDir 'config\sunshine.log'
    $confPath = Join-Path $SunshineDir 'config\sunshine.conf'
    $appsPath = Join-Path $SunshineDir 'config\apps.json'
    Write-Log "Sunshine: $SunshineDir"

    $dev = Get-VddDevice
    $pkg = Find-VddPackage
    if (-not $dev -and -not $pkg) {
        if ($NoPrereqs) { throw 'Virtual Display Driver is not installed (https://github.com/VirtualDrivers/Virtual-Display-Driver)' }
        Install-WithWinget 'VirtualDrivers.Virtual-Display-Driver'
        $pkg = Find-VddPackage
        if (-not $pkg) { throw 'Virtual Display Driver package not found after winget install' }
    }

    # --- 2. virtual display device -------------------------------------------
    if (-not (Test-Path $Config.vddSettingsPath)) {
        if (-not $pkg) { throw "Missing $($Config.vddSettingsPath); reinstall the Virtual Display Driver" }
        New-Item -ItemType Directory -Force (Split-Path -Parent $Config.vddSettingsPath) | Out-Null
        Copy-Item (Join-Path $pkg 'SignedDrivers\x86\VDD\vdd_settings.xml') $Config.vddSettingsPath
        Write-Log "Copied default driver settings to $($Config.vddSettingsPath)"
    }

    if (-not $dev) {
        # The package's "x86" folder holds the amd64 build (see MttVDD.inf).
        $inf = Join-Path $pkg 'SignedDrivers\x86\VDD\MttVDD.inf'
        $devcon = Join-Path $pkg 'Dependencies\devcon.exe'
        Write-Log 'Installing the virtual display device'
        $ErrorActionPreference = 'Continue'
        & $devcon install $inf $Config.vddHardwareId | Out-Host
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -ne 0) { throw "devcon install failed (exit $LASTEXITCODE)" }
        Start-Sleep -Seconds 3
        $dev = Get-VddDevice
        if (-not $dev) { throw 'Driver installed but no device found' }
    }
    Write-Log "Virtual display device: $($dev.InstanceId)"

    # --- 3. Sunshine output_name + audio -------------------------------------
    if (-not (Test-VddEnabled $dev)) { Invoke-Pnputil 'enable-device' $dev.InstanceId }
    $deadline = (Get-Date).AddSeconds(20)
    while (-not ($vdd = Get-VddAdapter) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (-not $vdd) { throw 'Virtual display did not show up' }
    Write-Log "Virtual display is $($vdd.DeviceName)"

    # Sunshine prints every display with its device_id when it starts.
    $svc = Get-Service $Config.sunshineService
    $wasRunning = $svc.Status -eq 'Running'
    if ($svc.Status -ne 'Stopped') { Stop-Service $svc.Name -Force; $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20)) }
    $sunshineStarted = Get-Date
    Start-Service $svc.Name
    $deviceId = $null
    $deadline = (Get-Date).AddSeconds(45)
    while (-not $deviceId -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if (-not (Test-Path $SunshineLog)) { continue }
        # Skip the previous run's log until Sunshine has rewritten it.
        if ((Get-Item $SunshineLog).LastWriteTime -lt $sunshineStarted) { continue }
        $log = try { Read-SharedFile $SunshineLog } catch { '' }
        $m = [regex]::Match($log, 'Currently available display devices:\s*(\[.*?\r?\n\])', 'Singleline')
        if ($m.Success) {
            $devices = $m.Groups[1].Value | ConvertFrom-Json
            $deviceId = ($devices | Where-Object { $_.display_name -eq $vdd.DeviceName }).device_id
            if (-not $deviceId) { Write-Log "Sunshine listed: $(($devices | ForEach-Object { "$($_.display_name)=$($_.device_id)" }) -join ', ')" }
        }
    }
    Stop-Service $svc.Name -Force
    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
    if (-not $deviceId) { throw 'Could not find the virtual display in the Sunshine log' }
    Write-Log "Sunshine device_id of the virtual display: $deviceId"

    Backup-Once $confPath
    $conf = @(if (Test-Path $confPath) { Get-Content $confPath | Where-Object { $_ -notmatch '^\s*(output_name|stream_audio)\s*=' } })
    $conf += "output_name = $deviceId"
    # Disabled: Sunshine leaves the PC's audio devices alone (no virtual sink, no muting).
    $conf += "stream_audio = $(if ($Config.streamAudio) { 'enabled' } else { 'disabled' })"
    [IO.File]::WriteAllLines($confPath, [string[]]$conf, $utf8)
    Write-Log "sunshine.conf: output_name set, stream_audio $(if ($Config.streamAudio) { 'enabled' } else { 'disabled' })"

    # --- 4. Sunshine app -----------------------------------------------------
    Backup-Once $appsPath
    $apps = if (Test-Path $appsPath) { Get-Content $appsPath -Raw | ConvertFrom-Json } else {
        [pscustomobject]@{ env = [pscustomobject]@{}; apps = @([pscustomobject]@{ name = 'Desktop'; 'image-path' = 'desktop.png' }) }
    }
    $ps = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'
    $vdisplay = "$ps `"$PSScriptRoot\vdisplay.ps1`""
    $app = [ordered]@{
        'name'         = 'Extended Screen'
        'cmd'          = "$ps `"$PSScriptRoot\session.ps1`""
        'prep-cmd'     = @([ordered]@{ 'do' = "$vdisplay on"; 'undo' = "$vdisplay off"; 'elevated' = $true })
        'auto-detach'  = $false
        'wait-all'     = $true
        'exit-timeout' = 5
        'image-path'   = (Join-Path $ProjectRoot 'assets\extended-screen.png')
    }
    $apps.apps = @($apps.apps | Where-Object { $_.name -ne 'Extended Screen' }) + $app
    [IO.File]::WriteAllText($appsPath, ($apps | ConvertTo-Json -Depth 10), $utf8)
    Write-Log "apps.json: 'Extended Screen' app written"

    # --- 5. service ----------------------------------------------------------
    Set-Service $svc.Name -StartupType Manual
    Write-Log 'Sunshine service set to Manual start (use the shortcut to turn it on)'

    # --- 6. shortcuts --------------------------------------------------------
    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
        $lnk = $shell.CreateShortcut((Join-Path $dir 'Extended Screen.lnk'))
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\toggle.ps1`""
        $lnk.WorkingDirectory = $ProjectRoot
        $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,104"
        $lnk.Description = 'Turn the tablet screen (Sunshine + virtual display) on or off'
        $lnk.Save()
    }
    Write-Log 'Shortcuts created on the Desktop and in the Start menu'

    # --- 7. off --------------------------------------------------------------
    Invoke-Pnputil 'disable-device' $dev.InstanceId
    if ($wasRunning) { Start-Service $svc.Name; Write-Log 'Sunshine restarted (it was running before)' }
    Write-Log 'Install finished; virtual display disabled'
} catch {
    Write-Log "INSTALL FAILED: $_"
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
exit 0
