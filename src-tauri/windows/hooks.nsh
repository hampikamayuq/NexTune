; Hooks do instalador NSIS do NexTune (bundle.windows.nsis.installerHooks).
; Só na desinstalação de verdade (não na troca de versão, $UpdateMode = 1), antes de remover os
; arquivos: scripts\desinstalar.ps1 desfaz um Modo Jogo pendente, remove a tarefa de início "NexTune"
; e, se o usuário aceitar, apaga C:\ProgramData\NexTune sem seguir junctions. Nunca mexe em ACLs.
; $DeleteAppDataCheckboxState é a caixa "apagar dados" do próprio desinstalador do Tauri (/DELETEAPPDATA).

!macro NSIS_HOOK_PREUNINSTALL
  ${If} $UpdateMode <> 1
    StrCpy $R9 ""
    ${If} $DeleteAppDataCheckboxState = 1
      StrCpy $R9 "-ApagarDados"
    ${Else}
      MessageBox MB_YESNO|MB_ICONQUESTION "Apagar também a quarentena, os backups e os registros do NexTune (C:\ProgramData\NexTune)?$\r$\n$\r$\nA quarentena pode guardar itens removidos nos últimos 7 dias. Escolha Não para mantê-los." /SD IDYES IDNO +2
      StrCpy $R9 "-ApagarDados"
    ${EndIf}
    ; Sem redirecionamento WOW64: o PowerShell de 64 bits, o mesmo que o app usa.
    ${DisableX64FSRedirection}
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\scripts\desinstalar.ps1" $R9'
    Pop $R8
    ${EnableX64FSRedirection}
  ${EndIf}
!macroend
