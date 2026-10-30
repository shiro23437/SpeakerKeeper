Option Explicit
Dim shell, fso, root, powerShellPath, cmd, arg
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = Chr(34) & powerShellPath & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -File " & Chr(34) & root & "\SpeakerKeeper-GUI.ps1" & Chr(34)
For Each arg In WScript.Arguments
    If LCase(CStr(arg)) = "--minimized" Then cmd = cmd & " -Minimized"
Next
shell.Run cmd, 0, False
