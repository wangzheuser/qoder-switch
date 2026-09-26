@echo off
rem Launcher for build.ps1 from cmd.exe. Keep this file ASCII-only on purpose:
rem cmd reads batch files in the OEM codepage (936 here), so UTF-8 Chinese in a
rem line gets split as GBK double-byte pairs and swallows the following ASCII
rem byte, which breaks parsing. The Chinese docs for this live in build.ps1 and README.
rem cmd cannot run .ps1 directly, and bare "build.ps1" depends on the machine's
rem file association plus execution policy, so start an explicit PowerShell host.
rem Usage: build.bat [deps icons test web debug release all]  (default: all)
rem In cmd use "build.bat" or ".\build.bat"; "./build.bat" is cmd-syntax invalid.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
exit /b %ERRORLEVEL%
