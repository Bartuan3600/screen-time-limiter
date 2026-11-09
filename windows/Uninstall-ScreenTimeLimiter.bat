@echo off
rem Startet die Deinstallation mit Administratorrechten.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Uninstall-ScreenTimeLimiter.ps1\"'"
