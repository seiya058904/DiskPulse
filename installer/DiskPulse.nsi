Unicode True
RequestExecutionLevel user
!ifndef PROJECT_ROOT
!define PROJECT_ROOT ".."
!endif
!ifndef OUTPUT_PATH
!define OUTPUT_PATH "${PROJECT_ROOT}\dist"
!endif
Name "DiskPulse"
Caption "DiskPulse Setup"
OutFile "${OUTPUT_PATH}\DiskPulse-Setup.exe"
Icon "${PROJECT_ROOT}\assets\DiskPulse.ico"
UninstallIcon "${PROJECT_ROOT}\assets\DiskPulse.ico"
InstallDir "$LOCALAPPDATA\DiskPulse"
ShowInstDetails show
ShowUninstDetails show

!include "LogicLib.nsh"
!include "MUI2.nsh"

!define MUI_ABORTWARNING
!define MUI_ICON "${PROJECT_ROOT}\assets\DiskPulse.ico"
!define MUI_UNICON "${PROJECT_ROOT}\assets\DiskPulse.ico"
!define MUI_WELCOMEPAGE_TITLE "Welcome to DiskPulse"
!define MUI_FINISHPAGE_RUN "$INSTDIR\DiskPulse.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch DiskPulse"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

VIProductVersion "1.0.0.0"
VIAddVersionKey "ProductName" "DiskPulse"
VIAddVersionKey "FileDescription" "DiskPulse Disk Dashboard"
VIAddVersionKey "FileVersion" "1.0.0"
VIAddVersionKey "LegalCopyright" "DiskPulse"

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
