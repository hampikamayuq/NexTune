; Hooks do instalador NSIS do NexTune (bundle.windows.nsis.installerHooks).
; Só na desinstalação de verdade (não na troca de versão, $UpdateMode = 1), antes de remover os
; arquivos: scripts\desinstalar.ps1 desfaz um Modo Jogo pendente, remove a tarefa de início "NexTune"
; e, se o usuário aceitar, apaga C:\ProgramData\NexTune sem seguir junctions. Nunca mexe em ACLs.
; $DeleteAppDataCheckboxState é a caixa "apagar dados" do próprio desinstalador do Tauri (/DELETEAPPDATA).

!macro NSIS_HOOK_PREUNINSTALL
  ${If} $UpdateMode <> 1
    ; Primeiro o app precisa estar fechado (o template só confere isso depois do hook).
    !insertmacro CheckIfAppIsRunning "$INSTDIR\${MAINBINARYNAME}.exe" "${PRODUCTNAME}"
    StrCpy $R9 ""
    ${If} $DeleteAppDataCheckboxState = 1
      StrCpy $R9 "-ApagarDados"
    ${Else}
      MessageBox MB_YESNO|MB_ICONQUESTION "Apagar também a quarentena, os backups e os registros do NexTune (C:\ProgramData\NexTune)?$\r$\n$\r$\nA quarentena pode guardar itens removidos nos últimos 7 dias. Escolha Não para mantê-los." /SD IDYES IDNO +2
      StrCpy $R9 "-ApagarDados"
    ${EndIf}
    ; O desinstalador roda elevado com o ambiente do usuário (HKCU\Environment, gravável sem elevação):
    ; estas variáveis fariam o .NET do PowerShell carregar uma DLL do usuário antes da primeira linha.
    System::Call 'kernel32::SetEnvironmentVariable(t "COR_ENABLE_PROFILING", t "0")'
    System::Call 'kernel32::SetEnvironmentVariable(t "COR_PROFILER", p 0)'
    System::Call 'kernel32::SetEnvironmentVariable(t "COR_PROFILER_PATH", p 0)'
    System::Call 'kernel32::SetEnvironmentVariable(t "COR_PROFILER_PATH_64", p 0)'
    System::Call 'kernel32::SetEnvironmentVariable(t "PSModulePath", p 0)'
    ; Sem redirecionamento WOW64: o PowerShell de 64 bits, o mesmo que o app usa.
    ${DisableX64FSRedirection}
    nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\scripts\desinstalar.ps1" $R9'
    Pop $R8
    ${EnableX64FSRedirection}
    ${If} $R8 != 0
      DetailPrint "desinstalar.ps1 terminou com código $R8"
    ${EndIf}
  ${EndIf}
!macroend
