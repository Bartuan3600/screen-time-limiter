@echo off
rem Startet die Installation mit Administratorrechten (Windows fragt nach dem Administrator-Passwort).
rem Optional: Install-ScreenTimeLimiter.bat -ChildAccount Max -Preset wochenende2h  (PIN/Passwort wird immer interaktiv abgefragt)
set "STL_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$a=@('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','\"%~dp0Install-ScreenTimeLimiter.ps1\"'); if ($env:STL_ARGS) { $a += ($env:STL_ARGS -split ' ' | Where-Object { $_ }) }; Start-Process powershell.exe -Verb RunAs -ArgumentList $a"
