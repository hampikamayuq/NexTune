# host.ps1 - processo PowerShell persistente. Le um JSON por linha do stdin, executa as acoes dos
# modulos em runspaces proprios e escreve somente linhas @@PROGRESS/@@LOG/@@RESULT no stdout.
param([int]$OciosoSegundos = 120, [string[]]$AllowlistExtra = @())

# Antes de qualquer autoload: o host roda elevado e nao pode carregar modulos de pastas que o
# usuario (ou um processo sem elevacao) consegue gravar, como Documentos\WindowsPowerShell\Modules.
# Os runspaces das acoes herdam esta variavel do processo.
$env:PSModulePath = "$PSHOME\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $null = $_ }
. "$PSScriptRoot\common.ps1"

$Allowlist = @('diagnostico', 'limpeza', 'quarentena', 'sistema', 'programas', 'inicializacao', 'ajusteswin') + @($AllowlistExtra)
$Fila = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$Ativos = New-Object System.Collections.ArrayList
# Ids que ja receberam seu @@RESULT final (garante resultado unico por acao).
$Finalizados = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,byte]'
$Relogio = [Diagnostics.Stopwatch]::StartNew()
$UltimaAtividade = [int64]0

# Saida do proprio host (ping, erros, cancelamento) tambem passa pela fila, mantendo a ordem.
$SaidaHost = New-Object PSObject
$SaidaHost | Add-Member -MemberType NoteProperty -Name Fila -Value $Fila
$SaidaHost | Add-Member -MemberType ScriptMethod -Name WriteLine -Value { param($s) $this.Fila.Enqueue([string]$s) }
Set-Saida $SaidaHost

# Corpo executado em cada runspace: recebe Id, Acao, Params, Teste, Fila, caminho do common e do modulo.
$CorpoRunspace = @'
param($Id, $Acao, $Params, $Teste, $Fila, $Finalizados, $Common, $Modulo)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. $Common
$w = New-Object PSObject
$w | Add-Member -MemberType NoteProperty -Name Fila -Value $Fila
$w | Add-Member -MemberType NoteProperty -Name Fin -Value $Finalizados
$w | Add-Member -MemberType NoteProperty -Name AcaoId -Value $Id
$w | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
    param($s)
    if ($s.StartsWith('@@RESULT ') -and -not $this.Fin.TryAdd($this.AcaoId, [byte]1)) { return }
    $this.Fila.Enqueue([string]$s)
}
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
    # Mata os filhos diretos do host criados a partir de $Desde (inicio da acao), exceto conhost.exe
    # (console do proprio host: matar quebra todo comando nativo seguinte).
    param([DateTime]$Desde)
    try {
        Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID" -ErrorAction Stop |
            Where-Object { $_.Name -ne 'conhost.exe' -and $_.CreationDate -ge $Desde } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { $null = $_ }
}

function Send-ResultUnico {
    # Emite o @@RESULT do host para a acao somente se ela ainda nao foi finalizada.
    param([string]$Id, $Dados, [bool]$Ok, [string]$Erro)
    if ($Finalizados.TryAdd($Id, [byte]1)) { Send-Result $Id $Dados $Ok $Erro; return $true }
    return $false
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
    $b = [byte]0
    $null = $Finalizados.TryRemove($Id, [ref]$b)
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($CorpoRunspace).AddArgument($Id).AddArgument($Acao).AddArgument($Params).
        AddArgument($Teste).AddArgument($Fila).AddArgument($Finalizados).AddArgument("$PSScriptRoot\common.ps1").
        AddArgument("$PSScriptRoot\$Modulo.ps1")
    $inicio = Get-Date
    $handle = $ps.BeginInvoke()
    $null = $Ativos.Add([pscustomobject]@{ Id = $Id; Ps = $ps; Rs = $rs; Handle = $handle; Inicio = $inicio; Cancelado = $false })
}

function Stop-AcaoAtiva {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Alvo)
    # Retorna $true se cancelou uma acao ainda em curso.
    $e = @($Ativos | Where-Object { $_.Id -eq $Alvo -and -not $_.Handle.IsCompleted }) | Select-Object -First 1
    if ($null -eq $e) { return $false }
    # 1) reserva o resultado (se a acao ja finalizou, nao ha o que cancelar)
    if (-not (Send-ResultUnico $Alvo $null $false 'cancelado')) { return $false }
    # 2) mata os filhos (destrava acao bloqueada esperando processo) e 3) para sem bloquear o loop
    $e.Cancelado = $true
    Invoke-MatarFilho $e.Inicio
    try { $null = $e.Ps.BeginStop($null, $null) } catch { $null = $_ }
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
                $erro = ''
                try { $null = $e.Ps.EndInvoke($e.Handle) } catch { $erro = $_.Exception.Message }
                if (-not $e.Cancelado) {
                    foreach ($er in @($e.Ps.Streams.Error)) {
                        [Console]::Error.WriteLine("acao $($e.Id): $er")
                        if ([string]::IsNullOrEmpty($erro)) { $erro = [string]$er }
                    }
                    if ([string]::IsNullOrEmpty($erro)) { $erro = 'ação terminou sem resultado' }
                    $null = Send-ResultUnico $e.Id $null $false $erro
                }
                Remove-Ativo $e
                $UltimaAtividade = $Relogio.ElapsedMilliseconds
            }
        }
        Write-FilaParaSaida
        if ($continuar -and $Ativos.Count -eq 0 -and $Fila.IsEmpty -and
            ($Relogio.ElapsedMilliseconds - $UltimaAtividade) -gt ($OciosoSegundos * 1000)) { $continuar = $false }
    }
} finally {
    # Saindo (sair/EOF): finaliza cada acao ainda em curso como cancelada.
    foreach ($e in @($Ativos)) {
        $null = Send-ResultUnico $e.Id $null $false 'cancelado'
        $e.Cancelado = $true
    }
    Write-FilaParaSaida
    foreach ($e in @($Ativos)) {
        Invoke-MatarFilho $e.Inicio
        try { $null = $e.Ps.BeginStop($null, $null) } catch { $null = $_ }
    }
    # Espera (no maximo $EsperaFimMs no total) os finally das acoes rodarem: e ali que a limpeza
    # religa servicos e restaura o registro. Sair antes mataria a thread no meio deles.
    $EsperaFimMs = 10000
    $relogioFim = [Diagnostics.Stopwatch]::StartNew()
    foreach ($e in @($Ativos)) {
        $resta = $EsperaFimMs - [int]$relogioFim.ElapsedMilliseconds
        if ($resta -le 0) { break }
        try { $null = $e.Handle.AsyncWaitHandle.WaitOne($resta) } catch { $null = $_ }
    }
    Write-FilaParaSaida
}
exit 0
