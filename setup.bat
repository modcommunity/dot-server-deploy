@echo off
rem A shim, so double-clicking works and so `setup` is the same word on both
rem platforms. The real script is setup.ps1 -- PowerShell is what can make a
rem directory junction, generate a password from a real CSPRNG, and write a file
rem without a byte order mark, and a .bat that tried would be a worse version of
rem all three.
rem
rem -ExecutionPolicy Bypass applies to this invocation only. It does not change
rem any machine setting, and it is what stops a default Windows install refusing
rem to run a script it just downloaded.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
