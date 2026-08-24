@echo off
REM Tunnels PC port 9750 -^> phone port 9750 over USB cable.
REM Requires iproxy.exe (libimobiledevice Windows build) in this folder,
REM and Apple Devices app / iTunes installed for USB drivers.

if not exist "%~dp0iproxy.exe" (
  echo [!] iproxy.exe not found next to this script.
  echo     Download: https://github.com/libimobiledevice-win32/imobiledevice-net/releases
  echo     ^(or any libimobiledevice Windows build^) and copy iproxy.exe here.
  pause
  exit /b 1
)

echo [*] Forwarding tcp://127.0.0.1:9750 -^> iPhone:9750 ...
"%~dp0iproxy.exe" 9750 9750
