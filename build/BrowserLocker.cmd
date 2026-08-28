@echo off
REM Launches the Brave Locker setup wizard with no console window.
REM The wizard self-elevates, so this does not need to run as administrator.
start "" wscript.exe "%~dp0gui\BrowserLockerLaunchWizard.vbs"
