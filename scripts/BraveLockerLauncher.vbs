' Starts the Brave Locker launcher with no console window.
' PowerShell's -WindowStyle Hidden still flashes a console briefly; running it
' from wscript with window style 0 avoids that, so the passphrase popup is the
' first and only thing the user sees.
Option Explicit

Dim shell, fso, scriptDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & _
          scriptDir & "\Start-BraveLocked.ps1"""

shell.Run command, 0, False
