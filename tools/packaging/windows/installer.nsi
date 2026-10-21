; The Windows installer of No Hero Needed (NSIS 3). tools/package.sh runs:
;   makensis -DVERSION=x.y.z -DSRC=<dir with the exe and its dll> -DICON=<icon.ico> -DOUT=<setup.exe> installer.nsi
; Installs for all users into Program Files, with Start menu and desktop
; shortcuts and an entry in "Apps & features" to remove it.
Unicode true
!include "MUI2.nsh"

!define APP "No Hero Needed"
!define EXE "noheroneeds.exe"
!define KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\NoHeroNeeded"

Name "${APP} ${VERSION}"
OutFile "${OUT}"
InstallDir "$PROGRAMFILES64\${APP}"
InstallDirRegKey HKLM "${KEY}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APP} setup"
VIAddVersionKey "LegalCopyright" "No Hero Needed contributors"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${EXE}"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "Russian"
!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetShellVarContext all
  SetOutPath "$INSTDIR"
  File /r "${SRC}/*"
  File "/oname=icon.ico" "${ICON}"
  WriteUninstaller "$INSTDIR\uninstall.exe"
  CreateDirectory "$SMPROGRAMS\${APP}"
  CreateShortcut "$SMPROGRAMS\${APP}\${APP}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\icon.ico"
  CreateShortcut "$SMPROGRAMS\${APP}\Удалить ${APP}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\${APP}.lnk" "$INSTDIR\${EXE}" "" "$INSTDIR\icon.ico"
  WriteRegStr HKLM "${KEY}" "DisplayName" "${APP}"
  WriteRegStr HKLM "${KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${KEY}" "Publisher" "No Hero Needed contributors"
  WriteRegStr HKLM "${KEY}" "DisplayIcon" "$INSTDIR\icon.ico"
  WriteRegStr HKLM "${KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${KEY}" "URLInfoAbout" "https://github.com/mirivlad/noheroneeds"
  WriteRegDWORD HKLM "${KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  Delete "$DESKTOP\${APP}.lnk"
  RMDir /r "$SMPROGRAMS\${APP}"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "${KEY}"
SectionEnd
