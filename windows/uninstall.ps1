# Removes Yoyo Control for Windows: the scheduled task(s), the firewall rule, this user's grant of the secure-desktop
# broker, the program folder this script is in.
# The state (pairings, keys, the log in %LOCALAPPDATA%\YoyoControl or -StateDir) stays unless -State is given.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-State]
param([switch]$State)
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ScheduledTask -TaskName "Yoyo Control*" -ErrorAction SilentlyContinue | Where-Object { $_.Actions.Execute -like "$dir\*" } | ForEach-Object {
  Stop-ScheduledTask -TaskName $_.TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false
}
Get-Process yoyo-control, node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir\*" } | Stop-Process -Force
Get-NetFirewallRule -DisplayName "Yoyo Control (uu Link)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
# this user out of the secure-desktop broker (it goes when nobody is left; needs an administrator PowerShell)
if (Test-Path "$dir\broker\yoyo-broker.exe") {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  & "$dir\broker\yoyo-broker.exe" uninstall --user $sid
}
if ($State) {
  $h = if (Test-Path "$dir\home.txt") { Get-Content "$dir\home.txt" } else { Join-Path $env:LOCALAPPDATA "YoyoControl" }
  Remove-Item -Recurse -Force $h -ErrorAction SilentlyContinue
}
$path = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", (($path -split ";") | Where-Object { $_ -and $_ -ine $dir }) -join ";", "User")
Set-Location $env:TEMP
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force $dir
Write-Host "Yoyo Control is removed."
