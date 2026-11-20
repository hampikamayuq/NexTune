# host.ps1 - processo PowerShell persistente. Le um JSON por linha do stdin, executa as acoes dos
# modulos em runspaces proprios e escreve somente linhas @@PROGRESS/@@LOG/@@RESULT no stdout.
param([int]$OciosoSegundos = 120, [string[]]$AllowlistExtra = @())

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $null = $_ }
. "$PSScriptRoot\common.ps1"

$Allowlist = @('diagnostico', 'limpeza') + @($AllowlistExtra)
$Fila = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$Ativos = New-Object System.Collections.ArrayList
$Relogio = [Diagnostics.Stopwatch]::StartNew()
$UltimaAtividade = [int64]0

# Saida do proprio host (ping, erros, cancelamento) tambem passa pela fila, mantendo a ordem.
$SaidaHost = New-Object PSObject
$SaidaHost | Add-Member -MemberType NoteProperty -Name Fila -Value $Fila
$SaidaHost | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { param($s) $this.Fila.Enqueue([string]$s) }
Set-Saida $SaidaHost

# Corpo executado em cada runspace: recebe Id, Acao, Params, Teste, Fila, caminho do common e do modulo.
$CorpoRunspace = @'
param($Id, $Acao, $Params, $Teste, $Fila, $Common, $Modulo)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. $Common
$w = New-Object PSObject
$w | Add-Member -MemberType NoteProperty -Name Fila -Value $Fila
$w | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { param($s) $this.Fila.Enqueue([string]$s) }
try {
    . $Modulo
    Set-Saida $w
    Invoke-Acao -Id $Id -Acao $Acao -Params $Params -Teste ([bool]$Teste)
} catch {
    Set-Saida $w
    Send-Result $Id $null $false $_.Exception.Message
}
'@

function Invoke-MatarFilho {
    # v1: mata TODOS os processos filhos diretos do host (nao rastreia por acao).
    try {
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID" -ErrorAction Stop |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { $null = $_ }
}

function Remove-Ativo {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Entrada)
    try { $Entrada.Ps.Dispose() } catch { $null = $_ }
    try { $Entrada.Rs.Dispose() } catch { $null = $_ }
    $Ativos.Remove($Entrada)
}

function Start-Acao {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, [string]$Modulo, [string]$Acao, $Params, [bool]$Teste)
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($CorpoRunspace).AddArgument($Id).AddArgument($Acao).AddArgument($Params).
        AddArgument($Teste).AddArgument($Fila).AddArgument("$PSScriptRoot\common.ps1").
        AddArgument("$PSScriptRoot\$Modulo.ps1")
    $handle = $ps.BeginInvoke()
    $null = $Ativos.Add([pscustomobject]@{ Id = $Id; Ps = $ps; Rs = $rs; Handle = $handle; Inicio = $Relogio.ElapsedMilliseconds })
}

function Stop-AcaoAtiva {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Alvo)
    # Retorna $true se cancelou uma acao ainda em curso.
    $e = @($Ativos | Where-Object { $_.Id -eq $Alvo -and -not $_.Handle.IsCompleted }) | Select-Object -First 1
    if ($null -eq $e) { return $false }
    try { $e.Ps.Stop() } catch { $null = $_ }
    Invoke-MatarFilho
    Remove-Ativo $e
    Send-Result $Alvo $null $false 'cancelado'
    return $true
}

function Invoke-Comando {
    param([string]$Linha)
    $cmd = $null
    try { $cmd = $Linha | ConvertFrom-Json -ErrorAction Stop } catch { $cmd = $null }
    if ($null -eq $cmd -or $cmd -isnot [pscustomobject] -or [string]::IsNullOrEmpty([string]$cmd.id) -or
        [string]::IsNullOrEmpty([string]$cmd.modulo) -or [string]::IsNullOrEmpty([string]$cmd.acao)) {
        Send-Result '' $null $false 'comando inválido'
        return $true
    }
    $id = [string]$cmd.id
    $modulo = [string]$cmd.modulo
    $acao = [string]$cmd.acao
    $teste = [bool]$cmd.teste

    if ($modulo -eq 'host') {
        switch ($acao) {
            'ping' {
                Send-Result $id @{ pid = $PID; versao = $PSVersionTable.PSVersion.ToString(); ocioso = ($Ativos.Count -eq 0) }
            }
            'cancelar' {
                $alvo = ''
                if ($null -ne $cmd.params -and $null -ne $cmd.params.alvo) { $alvo = [string]$cmd.params.alvo }
                $feito = Stop-AcaoAtiva $alvo
                Send-Result $id @{ cancelado = $feito }
            }
            'sair' {
                Send-Result $id $null
                return $false
            }
            default { Send-Result $id $null $false 'acao desconhecida' }
        }
        return $true
    }

    $arquivo = Join-Path $PSScriptRoot "$modulo.ps1"
    if ($modulo -notmatch '^[A-Za-z0-9_]+$' -or $Allowlist -notcontains $modulo -or -not (Test-Path -LiteralPath $arquivo)) {
        Send-Result $id $null $false 'modulo nao permitido'
        return $true
    }
    try { Start-Acao $id $modulo $acao $cmd.params $teste }
    catch { Send-Result $id $null $false $_.Exception.Message }
    return $true
}

function Write-FilaParaSaida {
    $linha = $null
    $escreveu = $false
    while ($Fila.TryDequeue([ref]$linha)) {
        [Console]::Out.WriteLine($linha)
        $escreveu = $true
    }
    if ($escreveu) { [Console]::Out.Flush() }
}

$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
$leitura = $stdin.ReadLineAsync()
$continuar = $true
try {
    while ($continuar) {
        if ($leitura.Wait(50)) {
            $linha = $leitura.Result
            if ($null -eq $linha) { $continuar = $false }   # stdin fechado = sair
            else {
                $UltimaAtividade = $Relogio.ElapsedMilliseconds
                if (-not [string]::IsNullOrWhiteSpace($linha)) {
                    try { $continuar = Invoke-Comando $linha }
                    catch { [Console]::Error.WriteLine("erro ao tratar comando: $($_.Exception.Message)") }
                }
                $leitura = $stdin.ReadLineAsync()
            }
        }
        Write-FilaParaSaida
        foreach ($e in @($Ativos)) {
            if ($e.Handle.IsCompleted) {
                try { $null = $e.Ps.EndInvoke($e.Handle) } catch { [Console]::Error.WriteLine("erro na acao $($e.Id): $($_.Exception.Message)") }
                Remove-Ativo $e
                $UltimaAtividade = $Relogio.ElapsedMilliseconds
            }
        }
        Write-FilaParaSaida
        if ($continuar -and $Ativos.Count -eq 0 -and $Fila.IsEmpty -and
            ($Relogio.ElapsedMilliseconds - $UltimaAtividade) -gt ($OciosoSegundos * 1000)) { $continuar = $false }
    }
} finally {
    foreach ($e in @($Ativos)) {
        try { $e.Ps.Stop() } catch { $null = $_ }
        Remove-Ativo $e
    }
    Write-FilaParaSaida
}
exit 0
