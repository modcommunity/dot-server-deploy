@echo off
rem A shim, as setup.bat is: `deploy` is the same word on both platforms, and
rem double-clicking works. The real script is deploy.ps1. -ExecutionPolicy Bypass
rem applies to this invocation only and changes no machine setting.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
