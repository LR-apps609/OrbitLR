; OrbitLR per Windows · clic destro su un file o una cartella → «Apri con OrbitLR»
; (solo per l'utente che installa; tolto alla disinstallazione)

!macro NSIS_HOOK_POSTINSTALL
  WriteRegStr HKCU "Software\Classes\*\shell\OrbitLR" "" "Apri con OrbitLR"
  WriteRegStr HKCU "Software\Classes\*\shell\OrbitLR" "Icon" "$INSTDIR\${MAINBINARYNAME}.exe,0"
  WriteRegStr HKCU "Software\Classes\*\shell\OrbitLR" "MultiSelectModel" "Player"
  WriteRegStr HKCU "Software\Classes\*\shell\OrbitLR\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
  WriteRegStr HKCU "Software\Classes\Directory\shell\OrbitLR" "" "Apri con OrbitLR"
  WriteRegStr HKCU "Software\Classes\Directory\shell\OrbitLR" "Icon" "$INSTDIR\${MAINBINARYNAME}.exe,0"
  WriteRegStr HKCU "Software\Classes\Directory\shell\OrbitLR\command" "" '"$INSTDIR\${MAINBINARYNAME}.exe" "%1"'
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  DeleteRegKey HKCU "Software\Classes\*\shell\OrbitLR"
  DeleteRegKey HKCU "Software\Classes\Directory\shell\OrbitLR"
!macroend
