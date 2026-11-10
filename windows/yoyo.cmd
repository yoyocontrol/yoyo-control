@echo off
rem yoyo pair | devices | remove <id> | disconnect | status | account [leave]: talks to the running service
rem (windows/README.md). The state folder: home.txt beside this file (install.ps1 -StateDir), else %LOCALAPPDATA%\YoyoControl.
setlocal
set "YH=%LOCALAPPDATA%\YoyoControl"
if exist "%~dp0home.txt" set /p YH=<"%~dp0home.txt"
set "NODE=%~dp0node.exe"
if not exist "%NODE%" set "NODE=node"
"%NODE%" "%~dp0server.mjs" %* --remote "%YH%"
