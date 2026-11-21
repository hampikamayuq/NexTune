# desinstalar.ps1 - roda no desinstalador NSIS (hook PREUNINSTALL), antes de os arquivos serem removidos:
# 1) se houver estado do Modo Jogo, volta tudo como estava (plano de energia, servicos, notificacoes,
#    programas fechados); 2) remove a tarefa de inicio com o Windows "NexTune"; 3) com -ApagarDados, apaga
# %ProgramData%\NexTune (quarentena, backups, logs, estado) sem seguir junctions.
# -Teste usa as pastas de teste (%TEMP%\NexTuneTeste) e grava marcadores em vez de chamar schtasks.
param([switch]$ApagarDados, [switch]$Teste)
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\modojogo.ps1"

$lido = Read-EstadoJogo $Teste
if ($lido.existe -and -not $lido.ilegivel) {
    $r = Restore-EstadoAnterior $lido.estado $Teste
    Remove-Item -LiteralPath (Get-ArquivoEstado $Teste) -Force -ErrorAction SilentlyContinue
    Write-AppLog ('desinstalar: Modo Jogo desfeito (falhas: ' + @($r.falhas).Count + ')') $Teste
}

if ($Teste) { Write-MarcadorJogo 'schtasks-delete.txt' 'schtasks /Delete /TN NexTune /F' }
else {
    # Pasta do Windows pela API (nao por $env:windir): o desinstalador roda elevado.
    $schtasks = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\schtasks.exe'
    & $schtasks /Delete /TN NexTune /F 2>$null | Out-Null
}

if ($ApagarDados) {
    $base = (Get-AppPastas $Teste).Base
    try { Remove-PastaSegura $base }
    catch { Write-Linha ('desinstalar: nao foi possivel apagar ' + $base + ': ' + $_.Exception.Message) }
}
