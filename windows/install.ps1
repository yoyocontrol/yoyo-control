# Installs Yoyo Control for Windows from this folder (windows/README.md「安装」): the files into a program folder,
# a scheduled task that starts it (yoyo-control.exe: the tray icon and the service) whenever the user signs in, and —
# when run as administrator — the firewall rule that lets the iPhone reach uu Link on this network. Run again to update.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1 [-User <name>] [-Dir <folder>] [-StateDir <folder>]
#                                                        [-LocalPort <n>] [-NoStart]
#
#   -User       whose sign-in starts it (default: you). Another user needs administrator rights here; it then runs
#               in that user's session as soon as they are signed in (the task's Interactive logon: no password).
#   -Dir        the program folder (default: %LOCALAPPDATA%\Programs\YoyoControl for yourself, else
#               %ProgramFiles%\Yoyo Control).
#   -StateDir   remote access's state: pairings, keys, the log (default: %LOCALAPPDATA%\YoyoControl of that user).
#   -LocalPort  also listen on 127.0.0.1:<n> for programs on this computer (docs/LOCAL-API.md), with a token written
#               to <StateDir>\token (readable by that user, SYSTEM and administrators).
#   -NoStart    don't start it now.
param(
  [string]$User = "",
  [string]$Dir = "",
  [string]$StateDir = "",
  [int]$LocalPort = 0,
  [switch]$NoStart
)
$ErrorActionPreference = "Stop"
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$self = $User -eq "" -or $User -ieq $env:USERNAME -or $User -ieq "$env:USERDOMAIN\$env:USERNAME"
if ($self) { $User = "$env:USERDOMAIN\$env:USERNAME" } elseif (-not $admin) { throw "Installing for another user needs an administrator PowerShell." }
if ($Dir -eq "") { $Dir = if ($self) { Join-Path $env:LOCALAPPDATA "Programs\YoyoControl" } else { Join-Path $env:ProgramFiles "Yoyo Control" } }
$task = if ($self) { "Yoyo Control" } else { "Yoyo Control ($($User.Split('\')[-1]))" }

# stop the running one (its files are about to be replaced)
Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
Get-Process yoyo-control -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir\*" } | Stop-Process -Force
Get-Process node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dir\*" } | Stop-Process -Force
Start-Sleep -Milliseconds 500

New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Get-ChildItem -Path $src | Where-Object { $_.Name -notin @("install.ps1") } | Copy-Item -Destination $Dir -Recurse -Force
Copy-Item (Join-Path $src "install.ps1") $Dir -Force

$serverArgs = @()
if ($StateDir -ne "") {
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  $serverArgs += @("--remote", "`"$StateDir`"")
}
if ($LocalPort -gt 0) {
  $state = if ($StateDir -ne "") { $StateDir } elseif ($self) { Join-Path $env:LOCALAPPDATA "YoyoControl" } else { throw "-LocalPort for another user needs -StateDir." }
  New-Item -ItemType Directory -Force -Path $state | Out-Null
  $tokenFile = Join-Path $state "token"
  if (-not (Test-Path $tokenFile)) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [IO.File]::WriteAllText($tokenFile, (($bytes | ForEach-Object { $_.ToString("x2") }) -join "") + "`n")
  }
  # the token: that user, SYSTEM and administrators only
  icacls $tokenFile /inheritance:r /grant:r "${User}:R" "SYSTEM:F" "*S-1-5-32-544:F" | Out-Null
  if ($StateDir -eq "") { $serverArgs += @("--remote", "`"$state`"") }
  $serverArgs += @("--host", "127.0.0.1", "--port", "$LocalPort", "--token-file", "`"$tokenFile`"")
}
if (-not $self -and $StateDir -ne "") {
  # the state folder: that user can write it (the service runs as them)
  icacls $StateDir /grant "${User}:(OI)(CI)M" | Out-Null
}

# where the `yoyo` command finds the state (yoyo.cmd reads it)
$home_ = if ($StateDir -ne "") { $StateDir } elseif ($LocalPort -gt 0) { $state } else { "" }
if ($home_ -ne "") { [IO.File]::WriteAllText((Join-Path $Dir "home.txt"), $home_) } else { Remove-Item (Join-Path $Dir "home.txt") -ErrorAction SilentlyContinue }

$action = New-ScheduledTaskAction -Execute (Join-Path $Dir "yoyo-control.exe") -Argument ($serverArgs -join " ") -WorkingDirectory $Dir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
# Highest: input reaches elevated windows too (Windows' UIPI), when the user is an administrator
$level = if ($admin) { "Highest" } else { "Limited" }
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel $level
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

if ($admin) {
  $node = Join-Path $Dir "node.exe"
  Get-NetFirewallRule -DisplayName "Yoyo Control (uu Link)" -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -DisplayName "Yoyo Control (uu Link)" -Direction Inbound -Action Allow -Protocol UDP -Program $node -Profile Any | Out-Null
} else {
  Write-Host "Not an administrator: no firewall rule. Windows asks once whether node.exe may use the network; allow it for private networks, or run this again as administrator."
}

# yoyo.cmd on this user's PATH: `yoyo pair`, `yoyo devices`…
if ($self) {
  $path = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not ($path -split ";" | Where-Object { $_ -ieq $Dir })) { [Environment]::SetEnvironmentVariable("Path", ($path.TrimEnd(";") + ";" + $Dir), "User") }
}

if (-not $NoStart) { Start-ScheduledTask -TaskName $task }
Write-Host "Yoyo Control is installed in $Dir and starts when $User signs in (task `"$task`")."
Write-Host "Pair the iPhone: the Yoyo Control icon in the notification area → Pair iPhone…  (or: yoyo pair)"
