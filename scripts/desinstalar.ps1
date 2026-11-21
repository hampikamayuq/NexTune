# desinstalar.ps1 - roda no desinstalador NSIS (hook PREUNINSTALL), antes de os arquivos serem removidos:
# 1) se houver estado do Modo Jogo, volta tudo como estava (plano de energia, servicos, notificacoes,
#    programas fechados); 2) remove a tarefa de inicio com o Windows "NexTune"; 3) com -ApagarDados, apaga
# %ProgramData%\NexTune (quarentena, backups, logs, estado) sem seguir junctions.
# -Teste usa as pastas de teste (%TEMP%\NexTuneTeste) e grava marcadores em vez de chamar schtasks.
param([switch]$ApagarDados, [switch]$Teste)
$ErrorActionPreference = 'Continue'

# Este processo roda elevado e herda o ambiente do usuario, que um processo sem elevacao altera em
# HKCU\Environment. Antes de carregar qualquer modulo: pastas pela API (SHGetFolderPath) e PSModulePath
# so com pastas do sistema, como faz o host.ps1. TEMP fica como esta (em -Teste e a base dos testes).
$pastaWin = [Environment]::GetFolderPath('Windows')
$env:windir = $pastaWin
$env:SystemRoot = $pastaWin
$env:SystemDrive = $pastaWin.Substring(0, 2)
$env:ProgramFiles = [Environment]::GetFolderPath('ProgramFiles')
${env:ProgramFiles(x86)} = [Environment]::GetFolderPath('ProgramFilesX86')
$env:ProgramData = [Environment]::GetFolderPath('CommonApplicationData')
$env:APPDATA = [Environment]::GetFolderPath('ApplicationData')
$env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData')
$env:USERPROFILE = [Environment]::GetFolderPath('UserProfile')
$env:PSModulePath = "$PSHOME\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"

. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\modojogo.ps1"

# Get-AppPastas recusa (throw) a pasta de dados quando ela e um link/junction: nesse caso nada e tocado.
try { $pastas = Get-AppPastas $Teste }
catch { Write-Linha ('desinstalar: ' + $_.Exception.Message); exit 1 }

$lido = Read-EstadoJogo $Teste
if ($lido.existe -and -not $lido.ilegivel) {
    # Sem reabrir programas: na desinstalacao nao ha valor nisso, e os .exe gravados ficam em pastas do usuario.
    $estado = $lido.estado | Select-Object -Property * -ExcludeProperty fechados
    $r = Restore-EstadoAnterior $estado $Teste
    Remove-Item -LiteralPath (Get-ArquivoEstado $Teste) -Force -ErrorAction SilentlyContinue
    Write-AppLog ('desinstalar: Modo Jogo desfeito (falhas: ' + @($r.falhas).Count + ')') $Teste
}

if ($Teste) { Write-MarcadorJogo 'schtasks-delete.txt' 'schtasks /Delete /TN NexTune /F' }
else { & "$pastaWin\System32\schtasks.exe" /Delete /TN NexTune /F 2>$null | Out-Null }

if ($ApagarDados) {
    try { Remove-PastaSegura $pastas.Base }
    catch { Write-Linha ('desinstalar: nao foi possivel apagar ' + $pastas.Base + ': ' + $_.Exception.Message) }
}
