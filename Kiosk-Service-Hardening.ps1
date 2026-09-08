#requires -RunAsAdministrator

<#
.SYNOPSIS
    Hardens a dedicated Windows kiosk or fixed-purpose workstation.

.DESCRIPTION
    This script:
      - Backs up current Windows service startup modes
      - Creates a rollback script
      - Logs all changes
      - Disables common nonessential services
      - Optionally disables printing
      - Optionally disables Bluetooth
      - Optionally disables location/sensor services
      - Optionally disables SSDP/UPnP
      - Optionally disables Windows Update-related services
      - Leaves core Windows networking, RPC, WMI, Event Log,
        Task Scheduler, firewall, time, RDP, audio, and profile
        services intact

.NOTES
    Review before use.
    Test in your environment before deploying broadly.
#>

[CmdletBinding()]
param(
    [switch]$DisablePrinting,
    [switch]$DisableBluetooth,
    [switch]$DisableLocationSensors,
    [switch]$DisableUPnP,

    # Set to $false if Windows Update should remain enabled.
    [bool]$DisableWindowsUpdate = $true
)

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------
# Working directory and log files
# ------------------------------------------------------------

$Root = 'C:\ProgramData\KioskHardening'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$BackupCsv   = Join-Path $Root "Services-Before-$Stamp.csv"
$AfterCsv    = Join-Path $Root "Services-After-$Stamp.csv"
$RollbackPs1 = Join-Path $Root "Restore-Services-$Stamp.ps1"
$LogFile     = Join-Path $Root "Kiosk-Hardening-$Stamp.log"

New-Item -Path $Root -ItemType Directory -Force | Out-Null

Start-Transcript -Path $LogFile -Force

Write-Host ""
Write-Host "=== Windows Kiosk Hardening ===" -ForegroundColor Cyan
Write-Host "Backup:   $BackupCsv"
Write-Host "Rollback: $RollbackPs1"
Write-Host "Log:      $LogFile"
Write-Host ""

# ------------------------------------------------------------
# Back up current service configuration
# ------------------------------------------------------------

$Before = Get-CimInstance Win32_Service |
    Select-Object `
        Name,
        DisplayName,
        State,
        StartMode,
        StartName,
        PathName

$Before |
    Export-Csv `
        -Path $BackupCsv `
        -NoTypeInformation `
        -Encoding UTF8

# ------------------------------------------------------------
# Generate rollback script
# ------------------------------------------------------------

$RollbackHeader = @"
#requires -RunAsAdministrator

<#
    Automatically generated rollback script.

    Restores service startup modes captured before kiosk hardening.
#>

`$ErrorActionPreference = 'Continue'

function Restore-ServiceStartup {

    param(
        [string]`$Name,
        [string]`$StartMode
    )

    if (-not (Get-Service -Name `$Name -ErrorAction SilentlyContinue)) {
        return
    }

    switch (`$StartMode) {

        'Auto' {
            sc.exe config "`$Name" start= auto | Out-Null
        }

        'Manual' {
            sc.exe config "`$Name" start= demand | Out-Null
        }

        'Disabled' {
            sc.exe config "`$Name" start= disabled | Out-Null
        }
    }
}
"@

Set-Content `
    -Path $RollbackPs1 `
    -Value $RollbackHeader `
    -Encoding UTF8

foreach ($Service in $Before) {

    $EscapedName = $Service.Name.Replace("'", "''")

    Add-Content `
        -Path $RollbackPs1 `
        -Value "Restore-ServiceStartup -Name '$EscapedName' -StartMode '$($Service.StartMode)'"
}

Add-Content -Path $RollbackPs1 -Value @'

Write-Host ""
Write-Host "Service startup modes restored."
Write-Host "Reboot Windows to fully return to the captured configuration."
'@

# ------------------------------------------------------------
# Helper function
# ------------------------------------------------------------

function Disable-KioskService {

    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Reason = ''
    )

    $Service = Get-Service `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if (-not $Service) {

        Write-Host "[SKIP] $Name - not installed"

        return
    }

    Write-Host "[DISABLE] $Name - $Reason"

    if ($Service.Status -ne 'Stopped') {

        try {

            Stop-Service `
                -Name $Name `
                -Force `
                -ErrorAction Stop
        }
        catch {

            Write-Warning "Could not stop $Name immediately: $($_.Exception.Message)"
        }
    }

    $Result = & sc.exe config "$Name" start= disabled 2>&1

    if ($LASTEXITCODE -ne 0) {

        Write-Warning "Could not disable $Name : $($Result -join ' ')"
    }
}

# ------------------------------------------------------------
# Baseline services commonly unnecessary on dedicated kiosks
# ------------------------------------------------------------

$BaselineServices = [ordered]@{

    'DiagTrack'         = 'Connected User Experiences and telemetry'
    'MapsBroker'        = 'Downloaded maps'
    'WSearch'           = 'Windows Search indexing'
    'SysMain'           = 'SysMain / prefetching'
    'TrkWks'            = 'Distributed Link Tracking'
    'WMPNetworkSvc'     = 'Media Player network sharing'
    'RetailDemo'        = 'Retail Demo'
    'PhoneSvc'          = 'Phone integration'
    'WalletService'     = 'Windows Wallet'
    'wisvc'             = 'Windows Insider'
    'XblAuthManager'    = 'Xbox authentication'
    'XblGameSave'       = 'Xbox game saves'
    'XboxGipSvc'        = 'Xbox accessories'
    'XboxNetApiSvc'     = 'Xbox networking'
    'Fax'               = 'Fax'
    'icssvc'            = 'Mobile Hotspot'
    'SharedAccess'      = 'Internet Connection Sharing'
    'PushToInstall'     = 'Remote Microsoft Store installation'
    'dmwappushservice'  = 'Device-management messaging'
    'WerSvc'            = 'Windows Error Reporting'
}

foreach ($Entry in $BaselineServices.GetEnumerator()) {

    Disable-KioskService `
        -Name $Entry.Key `
        -Reason $Entry.Value
}

# ------------------------------------------------------------
# Windows Update services
# ------------------------------------------------------------

if ($DisableWindowsUpdate) {

    Write-Host ""
    Write-Host "--- Windows Update Services ---" -ForegroundColor Yellow

    $UpdateServices = [ordered]@{

        'wuauserv' = 'Windows Update'
        'UsoSvc'   = 'Update Orchestrator'
        'BITS'     = 'Background Intelligent Transfer Service'
        'DoSvc'    = 'Delivery Optimization'
    }

    foreach ($Entry in $UpdateServices.GetEnumerator()) {

        Disable-KioskService `
            -Name $Entry.Key `
            -Reason $Entry.Value
    }

    # Disable common update-related scheduled tasks.
    # Some protected Windows tasks may reject modification.

    $UpdateTaskPaths = @(

        '\Microsoft\Windows\WindowsUpdate\',
        '\Microsoft\Windows\UpdateOrchestrator\'
    )

    foreach ($TaskPath in $UpdateTaskPaths) {

        try {

            Get-ScheduledTask `
                -TaskPath $TaskPath `
                -ErrorAction Stop |

                ForEach-Object {

                    try {

                        Disable-ScheduledTask `
                            -InputObject $_ `
                            -ErrorAction Stop |
                            Out-Null

                        Write-Host "[TASK DISABLED] $($_.TaskPath)$($_.TaskName)"
                    }
                    catch {

                        Write-Warning "Could not disable task $($_.TaskPath)$($_.TaskName)"
                    }
                }
        }
        catch {

            Write-Host "[SKIP] Scheduled task path not present: $TaskPath"
        }
    }
}

# ------------------------------------------------------------
# Optional: Printing
# ------------------------------------------------------------

if ($DisablePrinting) {

    Write-Host ""
    Write-Host "--- Printing ---" -ForegroundColor Yellow

    @(
        'Spooler',
        'PrintNotify',
        'PrintDeviceConfigurationService',
        'PrintScanBrokerService'
    ) |
    ForEach-Object {

        Disable-KioskService `
            -Name $_ `
            -Reason 'Printing not required'
    }
}

# ------------------------------------------------------------
# Optional: Bluetooth
# ------------------------------------------------------------

if ($DisableBluetooth) {

    Write-Host ""
    Write-Host "--- Bluetooth ---" -ForegroundColor Yellow

    @(
        'bthserv',
        'BthAvctpSvc',
        'BTAGService'
    ) |
    ForEach-Object {

        Disable-KioskService `
            -Name $_ `
            -Reason 'Bluetooth not required'
    }
}

# ------------------------------------------------------------
# Optional: Location and sensor services
# ------------------------------------------------------------

if ($DisableLocationSensors) {

    Write-Host ""
    Write-Host "--- Location / Sensors ---" -ForegroundColor Yellow

    @(
        'lfsvc',
        'SensorDataService',
        'SensorService',
        'SensrSvc'
    ) |
    ForEach-Object {

        Disable-KioskService `
            -Name $_ `
            -Reason 'Location or sensors not required'
    }
}

# ------------------------------------------------------------
# Optional: SSDP / UPnP
# ------------------------------------------------------------

if ($DisableUPnP) {

    Write-Host ""
    Write-Host "--- SSDP / UPnP ---" -ForegroundColor Yellow

    @(
        'SSDPSRV',
        'upnphost'
    ) |
    ForEach-Object {

        Disable-KioskService `
            -Name $_ `
            -Reason 'UPnP discovery not required'
    }
}

# ------------------------------------------------------------
# Critical services intentionally left intact
# ------------------------------------------------------------

$KeepServices = @(

    'Schedule',             # Task Scheduler
    'EventLog',             # Windows Event Log

    'RpcSs',                # Remote Procedure Call
    'RpcEptMapper',         # RPC Endpoint Mapper
    'DcomLaunch',           # DCOM Server Process Launcher

    'BFE',                  # Base Filtering Engine
    'mpssvc',               # Windows Defender Firewall

    'Winmgmt',              # Windows Management Instrumentation

    'PlugPlay',             # Plug and Play
    'Power',                # Power service
    'ProfSvc',              # User Profile Service

    'Dhcp',                 # DHCP Client
    'Dnscache',             # DNS Client
    'NlaSvc',               # Network Location Awareness
    'nsi',                  # Network Store Interface
    'LanmanWorkstation',    # Workstation / SMB client

    'CryptSvc',             # Cryptographic Services
    'W32Time',              # Windows Time

    'TermService',          # Remote Desktop Services
    'SessionEnv',           # Remote Desktop Configuration
    'UmRdpService',         # RDP UserMode Port Redirector

    'AudioEndpointBuilder',
    'Audiosrv'
)

Write-Host ""
Write-Host "--- Critical Services Left Intact ---" -ForegroundColor Green

foreach ($Name in $KeepServices) {

    $Service = Get-Service `
        -Name $Name `
        -ErrorAction SilentlyContinue

    if ($Service) {

        Write-Host (
            "[KEEP] {0,-25} {1,-10} {2}" -f `
                $Name,
                $Service.Status,
                $Service.DisplayName
        )
    }
}

# ------------------------------------------------------------
# Export resulting service state
# ------------------------------------------------------------

Get-CimInstance Win32_Service |
    Select-Object `
        Name,
        DisplayName,
        State,
        StartMode |

    Export-Csv `
        -Path $AfterCsv `
        -NoTypeInformation `
        -Encoding UTF8

# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

Write-Host ""
Write-Host "=== Hardening Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "No reboot was performed."
Write-Host ""
Write-Host "Before-state:"
Write-Host "  $BackupCsv"
Write-Host ""
Write-Host "After-state:"
Write-Host "  $AfterCsv"
Write-Host ""
Write-Host "Rollback script:"
Write-Host "  $RollbackPs1"
Write-Host ""
Write-Host "Transcript log:"
Write-Host "  $LogFile"
Write-Host ""
Write-Host "Recommended validation:"
Write-Host "  - Verify the kiosk application"
Write-Host "  - Verify network connectivity"
Write-Host "  - Verify remote administration"
Write-Host "  - Verify scheduled tasks"
Write-Host "  - Verify required peripherals"
Write-Host "  - Reboot and confirm automatic recovery"
Write-Host ""

Stop-Transcript
