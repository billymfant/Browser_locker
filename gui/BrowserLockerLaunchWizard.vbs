' Starts the setup wizard with no console window behind it.
' PowerShell's -WindowStyle Hidden still flashes a console briefly; running it
' from wscript with window style 0 means the wizard is the first thing seen.
Option Explicit

Dim shell, fso, guiDir, appDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

guiDir = fso.GetParentFolderName(WScript.ScriptFullName)
appDir = fso.GetParentFolderName(guiDir)

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
          guiDir & "\BrowserLockerWizard.ps1"""

shell.Run command, 0, False
