# Windows-kiosk-setup
Full code from my write up on https://rootnotebook.com/windows-kiosk-setup/

Basic hardening: 
.\Kiosk-Hardening.ps1

For a workstation that does not use printing, Bluetooth, location/sensors, or UPnP:
.\Kiosk-Hardening.ps1 `
     -DisablePrinting `
    -DisableBluetooth `
    -DisableLocationSensors `
    -DisableUPnP

  If you want to leave Windows Update enabled:
 .\Kiosk-Hardening.ps1 -DisableWindowsUpdate $false
