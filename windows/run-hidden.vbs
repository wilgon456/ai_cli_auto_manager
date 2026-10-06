' Runs the given command without a console window and returns its exit code.
' The scheduled tasks start PowerShell through this, so no window flashes on screen while you work.
Option Explicit
Dim shell, i, a, cmd
Set shell = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
  a = WScript.Arguments(i)
  If InStr(a, " ") > 0 Or a = "" Then a = Chr(34) & a & Chr(34)
  cmd = cmd & " " & a
Next
WScript.Quit shell.Run(Trim(cmd), 0, True)
