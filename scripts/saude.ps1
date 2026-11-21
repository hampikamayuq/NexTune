# saude.ps1 - saude do Windows: verificar a imagem (so leitura) e reparar (DISM /RestoreHealth e depois sfc /scannow).
# Acoes: verificar {simular?} -> {estado: ok|reparavel|irreparavel, detalhe};
#        reparar {confirmado, simular?} -> {dism: {codigo, estado}, sfc: {codigo, estado}, precisaReiniciar, detalhe}.
# Review Focus 3: nada vem do texto da tela (localizado). verificar le o enum ImageHealthState do
# Repair-WindowsImage -CheckHealth (o Dism.exe /CheckHealth sai com 0 tanto para saudavel quanto para reparavel e o
# dism.log nao grava o estado); reparar usa os codigos de saida e as linhas [SR] do CBS.log desde o inicio do sfc
# (o CBS grava em ingles em qualquer idioma do Windows). Da tela so sai a porcentagem, que nao e localizada.
# Cancelar: o host mata os processos filhos (Dism.exe, sfc.exe); esta acao nao grava estado nenhum no caminho.
# Em modo teste nada roda: simular {saude?, dism?: {codigo, saida?}, sfc?: {codigo, saida?, cbs?, desde?},
# demorarSegundos?} e marcadores em %TEMP%\NexTuneTeste\saude\. demorarSegundos roda um PING.EXE no lugar do
# DISM, so para o teste de cancelar matar um filho de verdade.
. "$PSScriptRoot\common.ps1"

# Codigos do DISM tratados como "sem fonte de reparo": CBS_E_SOURCE_MISSING (0x800F081F), CBS_E_DOWNLOAD_FAILURE
# (0x800F0906) e CBS_E_GROUPPOLICY_DISALLOWED (0x800F0907). 3010 = ERROR_SUCCESS_REBOOT_REQUIRED.
$Script:DismSemFonte = @(0x800F081FL, 0x800F0906L, 0x800F0907L)
$Script:ReinicioPedido = 3010
# Teto da leitura do fim do CBS.log: uma sessao inteira do sfc cabe com folga.
$Script:MaxBytesCbs = 16MB

# ---------- funcoes puras ----------

function ConvertTo-CodigoSemSinal {
    # ExitCode chega como Int32 (0x800F081F = -2146498529); compara sempre na forma sem sinal.
    param([int64]$Codigo)
    if ($Codigo -lt 0) { return $Codigo + 4294967296L }
    return $Codigo
}

function Format-Codigo {
    param([int64]$Codigo)
    $c = ConvertTo-CodigoSemSinal $Codigo
    if ($c -gt 0xFFFF) { return ('0x{0:X8}' -f $c) }
    return [string]$c
}

function Get-EstadoVerificacao {
    # Puro: ImageHealthState -> ok | reparavel | irreparavel; qualquer outro valor -> $null.
    param([string]$Saude)
    switch ($Saude) {
        'Healthy' { return 'ok' }
        'Repairable' { return 'reparavel' }
        'NonRepairable' { return 'irreparavel' }
    }
    return $null
}

function Get-EstadoDism {
    # Puro: codigo de saida do DISM /RestoreHealth -> ok | semFonte | desconhecido.
    param([int64]$Codigo)
    $c = ConvertTo-CodigoSemSinal $Codigo
    if ($c -eq 0 -or $c -eq $Script:ReinicioPedido) { return 'ok' }
    if ($Script:DismSemFonte -contains $c) { return 'semFonte' }
    return 'desconhecido'
}

function Get-PctLinha {
    # Puro: porcentagem (0..100) de uma linha de saida, ou $null. Tira os nulos do UTF-16 do sfc lido como bytes.
    param([string]$Linha)
    if ([string]::IsNullOrEmpty($Linha)) { return $null }
    $m = [regex]::Match($Linha.Replace([string][char]0, ''), '(\d{1,3})(?:[.,]\d+)?\s*%')
    if (-not $m.Success) { return $null }
    $n = [int]$m.Groups[1].Value
    if ($n -gt 100) { return $null }
    return $n
}

function Select-LinhaSr {
    # Puro: linhas [SR] do CBS.log com data a partir de $Desde (a sessao do sfc que acabou de rodar).
    param([string[]]$Linhas, [datetime]$Desde)
    $saida = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($Linhas)) {
        if ([string]::IsNullOrEmpty($l) -or $l.Length -lt 19 -or $l.IndexOf('[SR]') -lt 0) { continue }
        $quando = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($l.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$quando)) { continue }
        if ($quando -ge $Desde) { $saida.Add($l) }
    }
    return $saida.ToArray()
}

function Get-EstadoSfc {
    # Puro: semProblemas | reparado | naoReparado | desconhecido pelas linhas [SR] da sessao e pelo codigo de saida.
    # "Repairing 0 components" e "Repair complete" aparecem em toda execucao e nao contam como reparo.
    param([int64]$Codigo, [string[]]$LinhasSr)
    $sr = @($LinhasSr | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($sr.Count -eq 0) { return 'desconhecido' }
    $texto = $sr -join "`n"
    if ($texto -match '\[SR\] (Cannot repair|Could not reproject|Unable to repair)') { return 'naoReparado' }
    if ($texto -match '\[SR\] (Repairing corrupted file|Repaired file|Repairing [1-9]\d* components)') { return 'reparado' }
    if ($Codigo -eq 0) { return 'semProblemas' }
    return 'desconhecido'
}

function Get-DetalheReparo {
    # Puro: frase pt-BR do resultado de reparar.
    param($Dism, $Sfc, [bool]$Reiniciar)
    $d = switch ($Dism.estado) {
        'ok' { 'O DISM terminou sem erro: a imagem do Windows está íntegra.' }
        'semFonte' { 'O DISM não conseguiu os arquivos de reparo (sem internet ou bloqueado pelo Windows Update).' }
        default { 'O DISM terminou com o código ' + (Format-Codigo $Dism.codigo) + '.' }
    }
    $s = switch ($Sfc.estado) {
        'semProblemas' { 'O SFC não encontrou arquivos do sistema corrompidos.' }
        'reparado' { 'O SFC reparou arquivos do sistema corrompidos.' }
        'naoReparado' { 'O SFC achou arquivos do sistema que não conseguiu reparar.' }
        default { 'Não foi possível ler o resultado do SFC (código ' + (Format-Codigo $Sfc.codigo) + ').' }
    }
    $r = if ($Reiniciar) { ' Reinicie o PC para concluir.' } else { '' }
    return ($d + ' ' + $s + $r)
}

# ---------- leitura e execucao ----------

function Get-PastaSaudeTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'saude'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-MarcadorSaude {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Texto)
    [IO.File]::WriteAllText((Join-Path (Get-PastaSaudeTeste) $Nome), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

function Read-CbsLog {
    # Linhas do fim do CBS.log (ate $MaxBytesCbs), lidas sem travar o arquivo; ilegivel -> lista vazia.
    $arq = Join-Path $env:windir 'Logs\CBS\CBS.log'
    try {
        $fs = New-Object IO.FileStream($arq, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($fs.Length -gt $Script:MaxBytesCbs) { $null = $fs.Seek(-$Script:MaxBytesCbs, [IO.SeekOrigin]::End) }
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            return @($sr.ReadToEnd() -split "`r?`n")
        } finally { $fs.Dispose() }
    } catch { return @() }
}

function Invoke-Ferramenta {
    # Roda o exe como filho direto do host (o cancelar o mata) e le a saida so para tirar a porcentagem.
    # Devolve o codigo de saida.
    param([string]$Exe, [string]$Argumentos, [scriptblock]$AoPct)
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Argumentos
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
        while ($null -ne ($linha = $p.StandardOutput.ReadLine())) {
            $pct = Get-PctLinha $linha
            if ($null -ne $pct) { & $AoPct $pct }
        }
        $p.WaitForExit()
        return $p.ExitCode
    } finally { $p.Dispose() }
}

function Invoke-Etapa {
    # Uma ferramenta (real ou simulada) com o progresso dela levado para a faixa [$De, $Ate] do total. $aoPct roda
    # dentro de Invoke-Ferramenta e enxerga $De/$faixa/$Id/$Msg pelo escopo dinamico (sem GetNewClosure, que perde as
    # funcoes do script).
    param([string]$Id, [string]$Msg, [int]$De, [int]$Ate, [string]$Exe, [string]$Argumentos, $Sim, [string]$Marcador, [bool]$Teste)
    $ultimo = @{ pct = -1 }
    $faixa = $Ate - $De
    $aoPct = {
        param($n)
        $total = $De + [int][math]::Floor($faixa * $n / 100)
        if ($total -ne $ultimo.pct) { $ultimo.pct = $total; Send-Progress $Id $total $Msg }
    }
    Send-Progress $Id $De $Msg
    if (-not $Teste) { return (Invoke-Ferramenta $Exe $Argumentos $aoPct) }
    Write-MarcadorSaude $Marcador ($Exe + ' ' + $Argumentos)
    foreach ($l in @($Sim.saida)) { $pct = Get-PctLinha ([string]$l); if ($null -ne $pct) { & $aoPct $pct } }
    if ($null -eq $Sim -or $null -eq $Sim.codigo) { return 0 }
    return [int64]$Sim.codigo
}

# ---------- acoes ----------

function Invoke-Verificar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 10 'Verificando a imagem do Windows'
    if ($Teste) {
        $saude = if ($null -ne $sim -and $null -ne $sim.saude) { [string]$sim.saude } else { 'Healthy' }
    } else {
        $saude = [string](Repair-WindowsImage -Online -CheckHealth -NoRestart -ErrorAction Stop).ImageHealthState
    }
    $estado = Get-EstadoVerificacao $saude
    if ($null -eq $estado) { throw "resultado inesperado do DISM: $saude" }
    $detalhe = switch ($estado) {
        'ok' { 'Nenhuma corrupção registrada na imagem do Windows.' }
        'reparavel' { 'A imagem do Windows tem corrupção que dá para reparar.' }
        default { 'A imagem do Windows tem corrupção que o DISM não consegue reparar.' }
    }
    Write-AppLog ('saude: verificar -> ' + $saude) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ estado = $estado; detalhe = $detalhe })
}

function Invoke-Reparar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $sim = Get-Simulacao $Params $Teste
    $sys = Join-Path $env:windir 'System32'
    $dismExe = Join-Path $sys 'Dism.exe'
    $dismArgs = '/Online /Cleanup-Image /RestoreHealth'
    $simDism = if ($null -ne $sim) { $sim.dism } else { $null }
    if ($Teste -and $null -ne $sim -and $null -ne $sim.demorarSegundos) {
        # So no teste de cancelar: um filho de verdade que demora, no papel do DISM.
        Send-Progress $Id 0 'Reparando a imagem do Windows'
        $codDism = Invoke-Ferramenta (Join-Path $sys 'PING.EXE') ('-n ' + ([int]$sim.demorarSegundos + 1) + ' 127.0.0.1') { param($n) $null = $n }
    } else {
        $codDism = Invoke-Etapa $Id 'Reparando a imagem do Windows (pode baixar arquivos do Windows Update)' 0 60 $dismExe $dismArgs $simDism 'dism-restorehealth.txt' $Teste
    }
    $dism = [ordered]@{ codigo = [int64]$codDism; estado = (Get-EstadoDism $codDism) }
    Write-AppLog ('saude: DISM /RestoreHealth terminou com ' + (Format-Codigo $codDism)) $Teste

    $simSfc = if ($null -ne $sim) { $sim.sfc } else { $null }
    # CBS.log tem resolucao de segundos: a sessao comeca no segundo cheio antes de chamar o sfc.
    $agora = Get-Date
    $desde = $agora.AddTicks(- ($agora.Ticks % [TimeSpan]::TicksPerSecond))
    $codSfc = Invoke-Etapa $Id 'Reparando arquivos do sistema' 60 99 (Join-Path $sys 'sfc.exe') '/scannow' $simSfc 'sfc-scannow.txt' $Teste
    if ($Teste) {
        $cbs = if ($null -ne $simSfc) { @($simSfc.cbs) } else { @() }
        $desde = if ($null -ne $simSfc -and $null -ne $simSfc.desde) { [datetime]$simSfc.desde } else { [datetime]::MinValue }
    } else {
        $cbs = Read-CbsLog
    }
    $sfc = [ordered]@{ codigo = [int64]$codSfc; estado = (Get-EstadoSfc $codSfc (Select-LinhaSr $cbs $desde)) }
    Write-AppLog ('saude: sfc /scannow terminou com ' + (Format-Codigo $codSfc) + ' (' + $sfc.estado + ')') $Teste

    $reiniciar = ((ConvertTo-CodigoSemSinal $codDism) -eq $Script:ReinicioPedido) -or ($sfc.estado -eq 'reparado')
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ dism = $dism; sfc = $sfc; precisaReiniciar = $reiniciar; detalhe = (Get-DetalheReparo $dism $sfc $reiniciar) })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('verificar', 'reparar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'verificar' { Invoke-Verificar $Id $Params $Teste }
            'reparar' { Invoke-Reparar $Id $Params $Teste }
        }
    } catch {
        $msg = 'saúde do Windows falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
