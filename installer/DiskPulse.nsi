Unicode True
RequestExecutionLevel user
!ifndef PROJECT_ROOT
!define PROJECT_ROOT ".."
!endif
!ifndef OUTPUT_PATH
!define OUTPUT_PATH "${PROJECT_ROOT}\dist"
!endif
Name "DiskPulse"
Caption "DiskPulse 安装程序"
OutFile "${OUTPUT_PATH}\DiskPulse-Setup.exe"
Icon "${PROJECT_ROOT}\assets\DiskPulse.ico"
UninstallIcon "${PROJECT_ROOT}\assets\DiskPulse.ico"
InstallDir "$LOCALAPPDATA\DiskPulse"
ShowInstDetails show
ShowUninstDetails show

!include "LogicLib.nsh"

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "DiskPulse"
VIAddVersionKey "FileDescription" "DiskPulse 磁盘看板"
VIAddVersionKey "FileVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "DiskPulse"

PageEx directory
PageExEnd
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "DiskPulse"
    SetShellVarContext current
    SetOutPath "$INSTDIR"
    File "${PROJECT_ROOT}\dist\DiskPulse.exe"

    CreateDirectory "$LOCALAPPDATA\DiskPulse\data\runtime"
    ${If} ${FileExists} "$EXEDIR\runtime\*.*"
        FileOpen $0 "$LOCALAPPDATA\DiskPulse\data\migration-sources.txt" w
        FileWrite $0 "$EXEDIR\runtime$\r$\n"
        FileClose $0
    ${EndIf}

    CreateDirectory "$SMPROGRAMS\DiskPulse"
    CreateShortCut "$DESKTOP\DiskPulse.lnk" "$INSTDIR\DiskPulse.exe"
    CreateShortCut "$SMPROGRAMS\DiskPulse\DiskPulse.lnk" "$INSTDIR\DiskPulse.exe"

    WriteUninstaller "$INSTDIR\Uninstall.exe"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "DisplayName" "DiskPulse"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "DisplayVersion" "1.0.0"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "Publisher" "DiskPulse"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "InstallLocation" "$INSTDIR"
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "UninstallString" "$INSTDIR\Uninstall.exe"
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "NoModify" 1
    WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse" "NoRepair" 1
SectionEnd

Section "Uninstall"
    SetShellVarContext current
    Delete "$DESKTOP\DiskPulse.lnk"
    Delete "$SMPROGRAMS\DiskPulse\DiskPulse.lnk"
    RMDir "$SMPROGRAMS\DiskPulse"
    Delete "$INSTDIR\DiskPulse.exe"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir "$INSTDIR"
    DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DiskPulse"
SectionEnd
