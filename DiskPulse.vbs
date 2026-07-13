' DiskPulse silent launcher
' Runs check.bat in the background with no visible window.
' On success: opens the report in the default browser (handled by check.bat).
' On failure: shows a single error dialog pointing to the log file.

Option Explicit

Dim shell, fso, root, batPath, exitCode, logPath
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

root = fso.GetParentFolderName(WScript.ScriptFullName)
batPath = fso.BuildPath(root, "check.bat")
logPath = fso.BuildPath(fso.BuildPath(root, "runtime"), "last-run.log")

If Not fso.FileExists(batPath) Then
    MsgBox "Cannot find check.bat in:" & vbCrLf & batPath, _
        vbCritical, "DiskPulse"
    WScript.Quit 2
End If

shell.CurrentDirectory = root
shell.Environment("PROCESS")("DISKPULSE_SILENT") = "1"

exitCode = shell.Run(Chr(34) & batPath & Chr(34), 0, True)

If exitCode <> 0 Then
    Dim message
    message = "DiskPulse scan failed (exit code " & exitCode & ")."

    If fso.FileExists(logPath) Then
        message = message & vbCrLf & vbCrLf & _
            "See log for details:" & vbCrLf & logPath
    Else
        message = message & vbCrLf & vbCrLf & _
            "No log generated. Run check.bat directly to see the error."
    End If

    MsgBox message, vbCritical, "DiskPulse"
End If

WScript.Quit exitCode
