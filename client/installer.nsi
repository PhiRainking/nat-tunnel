; NatTunnel Setup Script
!include "MUI2.nsh"

Name "NatTunnel"
OutFile "NatTunnel-Setup.exe"
InstallDir "$LOCALAPPDATA\NatTunnel"
RequestExecutionLevel user

!define MUI_ABORTWARNING

; Pages
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "license.txt"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Section "!NatTunnel (required)" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "dist\win-unpacked\*.*"
  
  CreateShortCut "$DESKTOP\NatTunnel.lnk" "$INSTDIR\NatTunnel.exe"
  CreateDirectory "$SMPROGRAMS\NatTunnel"
  CreateShortCut "$SMPROGRAMS\NatTunnel\NatTunnel.lnk" "$INSTDIR\NatTunnel.exe"
  CreateShortCut "$SMPROGRAMS\NatTunnel\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
  
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "DisplayName" "NatTunnel"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "DisplayIcon" '"$INSTDIR\NatTunnel.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "Publisher" "RainKing"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "DisplayVersion" "1.0.0"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel" "NoRepair" 1
SectionEnd

Section "Desktop Shortcut" SecDesktop
  CreateShortCut "$DESKTOP\NatTunnel.lnk" "$INSTDIR\NatTunnel.exe"
SectionEnd

Section "Start Menu Shortcuts" SecStartMenu
  CreateDirectory "$SMPROGRAMS\NatTunnel"
  CreateShortCut "$SMPROGRAMS\NatTunnel\NatTunnel.lnk" "$INSTDIR\NatTunnel.exe"
  CreateShortCut "$SMPROGRAMS\NatTunnel\Uninstall.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\*.*"
  RMDir /r "$INSTDIR"
  Delete "$DESKTOP\NatTunnel.lnk"
  RMDir /r "$SMPROGRAMS\NatTunnel"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\NatTunnel"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "NatTunnel main program (required)"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "Create shortcut on Desktop"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStartMenu} "Create shortcuts in Start Menu"
!insertmacro MUI_FUNCTION_DESCRIPTION_END
