@echo off
rem Startet den Bildschirmzeit-Limiter ohne Konsolenfenster.
cd /d "%~dp0"
where pythonw >nul 2>nul && (start "" pythonw main.py & exit /b)
where pyw >nul 2>nul && (start "" pyw main.py & exit /b)
python main.py
