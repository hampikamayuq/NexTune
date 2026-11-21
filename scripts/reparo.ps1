# reparo.ps1 - explica falhas do winget/instalador e repara produtos do Windows Installer orfaos
# (sem a copia local do .msi em C:\Windows\Installer e sem origem acessivel: o Windows nao consegue
# atualizar nem desinstalar e responde 1603/1612). Reparar so remove o REGISTRO do produto, depois de
# exportar as chaves para a quarentena; nunca apaga arquivos de programas nem do cache do instalador.
# Acoes: diagnosticar {simular?}, reparar {ids:[{GUID}], confirmado}.
# Logica de deteccao baseada em Unregister-MissingMSIs.ps1 (MIT, heaths/BrentHumphreys), reescrita sem o
# modulo MSI da internet.
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\quarentena.ps1"

function ConvertTo-GuidCompactado {
    # {8-4-4-4-12} -> forma compactada do Windows Installer (3 primeiros grupos invertidos, resto com nibbles trocados).
    param([string]$Guid)
    if ($Guid -notmatch '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') { throw "GUID inválido: $Guid" }
    $x = $Guid.Trim('{', '}').Replace('-', '').ToUpperInvariant()
    $inverter = { param([string]$s) $a = $s.ToCharArray(); [array]::Reverse($a); -join $a }
    $resto = for ($i = 16; $i -lt 32; $i += 2) { & $inverter $x.Substring($i, 2) }
    return ((& $inverter $x.Substring(0, 8)) + (& $inverter $x.Substring(8, 4)) + (& $inverter $x.Substring(12, 4)) + ($resto -join ''))
}

function Test-ProdutoOrfao {
    # $Produto = @{ localPackage; packageName; origens = @() }. Orfao: a copia local nao existe E nenhuma
    # origem registrada tem <origem>\<packageName>. Nunca lanca por campo vazio ou nulo.
    param($Produto)
    $local = [string]$Produto.localPackage
    # [IO.File]::Exists nao lanca para drive inexistente (W:) nem para caminho invalido: devolve $false.
    if (-not [string]::IsNullOrWhiteSpace($local) -and [IO.File]::Exists($local)) { return $false }
    $nome = [string]$Produto.packageName
    if (-not [string]::IsNullOrWhiteSpace($nome)) {
        foreach ($o in @($Produto.origens)) {
            if ([string]::IsNullOrWhiteSpace([string]$o)) { continue }
            try { if ([IO.File]::Exists([IO.Path]::Combine([string]$o, $nome))) { return $false } } catch { $null = $_ }
        }
    }
    return $true
}

function ConvertFrom-GuidCompactado {
    # Inverso de ConvertTo-GuidCompactado (a operacao e uma involucao): 32 hex -> {8-4-4-4-12}.
    param([string]$Compactado)
    if ($Compactado -notmatch '^[0-9A-Fa-f]{32}$') { throw "GUID compactado inválido: $Compactado" }
    $c = ConvertTo-GuidCompactado ('{' + $Compactado.Substring(0, 8) + '-' + $Compactado.Substring(8, 4) + '-' + $Compactado.Substring(12, 4) + '-' + $Compactado.Substring(16, 4) + '-' + $Compactado.Substring(20, 12) + '}')
    return ('{' + $c.Substring(0, 8) + '-' + $c.Substring(8, 4) + '-' + $c.Substring(12, 4) + '-' + $c.Substring(16, 4) + '-' + $c.Substring(20, 12) + '}')
}

# ---------- leitura ----------

$Script:RaizProdutos = 'HKLM:\SOFTWARE\Classes\Installer\Products'
$Script:RaizPropriedades = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'
$Script:MaxProdutos = 200

function Get-ValorRegistro {
    # Valor de texto ou $null (chave ausente, valor ausente ou sem acesso).
    param([string]$Chave, [string]$Nome)
    try { return [string](Get-ItemProperty -LiteralPath $Chave -Name $Nome -ErrorAction Stop).$Nome } catch { return $null }
}

function Get-ProdutosMsi {
    # Produtos de maquina (S-1-5-18) do Windows Installer: @{ codigo; nome; versao; editor; localPackage; packageName; origens }.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($k in @(Get-ChildItem -LiteralPath $Script:RaizProdutos -ErrorAction SilentlyContinue)) {
        try {
            $compactado = $k.PSChildName
            $codigo = ConvertFrom-GuidCompactado $compactado
            $prop = Join-Path (Join-Path $Script:RaizPropriedades $compactado) 'InstallProperties'
            $origens = @()
            $net = Join-Path (Join-Path $k.PSPath 'SourceList') 'Net'
            if (Test-Path -LiteralPath $net) {
                $item = Get-ItemProperty -LiteralPath $net -ErrorAction SilentlyContinue
                if ($null -ne $item) { $origens = @($item.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object { [string]$_.Value }) }
            }
            $nome = Get-ValorRegistro $k.PSPath 'ProductName'
            if ([string]::IsNullOrWhiteSpace($nome)) { $nome = Get-ValorRegistro $prop 'DisplayName' }
            $lista.Add(@{
                    codigo       = $codigo
                    nome         = [string]$nome
                    versao       = [string](Get-ValorRegistro $prop 'DisplayVersion')
                    editor       = [string](Get-ValorRegistro $prop 'Publisher')
                    localPackage = [string](Get-ValorRegistro $prop 'LocalPackage')
                    packageName  = [string](Get-ValorRegistro (Join-Path $k.PSPath 'SourceList') 'PackageName')
                    origens      = $origens
                })
        } catch { $null = $_ }
    }
    return $lista.ToArray()
}

function Get-MotivoNaoReparar {
    # Motivo (texto) de o produto nao poder ser reparado por aqui, ou $null. Fonte: data\reparo.json (naoReparar).
    param([string]$Nome, [string]$Editor)
    $dados = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'reparo.json')
    foreach ($e in @($dados.naoReparar)) {
        if ($Nome -match [string]$e.padrao -or $Editor -match [string]$e.padrao) { return [string]$e.motivo }
    }
    return $null
}

function Get-DiagnosticoMsi {
    # Orfaos (e so eles) com o motivo de nao reparavel quando for o caso. $Simulados substitui a leitura do registro.
    param($Simulados = $null)
    $produtos = if ($null -ne $Simulados) { @($Simulados) } else { @(Get-ProdutosMsi) }
    $saida = New-Object System.Collections.Generic.List[object]
    foreach ($p in $produtos) {
        if (-not (Test-ProdutoOrfao $p)) { continue }
        $motivo = Get-MotivoNaoReparar ([string]$p.nome) ([string]$p.editor)
        $saida.Add([ordered]@{
                codigo       = [string]$p.codigo
                nome         = [string]$p.nome
                versao       = [string]$p.versao
                editor       = [string]$p.editor
                localPackage = [string]$p.localPackage
                origens      = @($p.origens)
                reparavel    = ($null -eq $motivo)
                motivo       = $motivo
            })
    }
    return @($saida | Sort-Object { $_.nome } | Select-Object -First $Script:MaxProdutos)
}

function Invoke-Diagnosticar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $simulados = if ($null -ne $sim -and $null -ne $sim.produtos) { @($sim.produtos) } else { $null }
    if ($Teste -and $null -eq $simulados) { $simulados = @() }
    Send-Progress $Id 10 'Procurando instalações com registro quebrado'
    $lista = @(Get-DiagnosticoMsi $simulados)
    Write-AppLog ('reparo: diagnóstico achou ' + $lista.Count + ' produto(s) quebrado(s)') $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ produtos = $lista })
}

# ---------- reparar ----------

function Get-ChaveProduto {
    # As 5 chaves (forma do reg.exe) que registram o produto. Em teste, tudo sob HKCU\Software\NexTuneTeste\Reparo.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Guid, [bool]$Teste)
    $c = ConvertTo-GuidCompactado $Guid
    $raiz = if ($Teste) { 'HKCU\Software\NexTuneTeste\Reparo' } else { 'HKLM\SOFTWARE' }
    $uni = 'Microsoft\Windows\CurrentVersion'
    return @(
        "$raiz\Classes\Installer\Products\$c",
        "$raiz\Classes\Installer\Features\$c",
        "$raiz\$uni\Installer\UserData\S-1-5-18\Products\$c",
        "$raiz\$uni\Uninstall\$Guid",
        "$raiz\WOW6432Node\$uni\Uninstall\$Guid"
    )
}

function Save-ChaveQuarentena {
    # So exporta a chave para a entrada (itens\<n>\chave.reg) e registra o item; quem remove e o chamador, depois
    # que TODOS os backups do produto existirem. Mesmo formato de item de Add-ItemQuarentena (restauravel).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Entrada, [string]$Chave, $Sim = $null)
    $teste = [bool]$Entrada.teste
    if ($teste -and $null -ne $Sim -and $Sim.falharBackup -eq $true) { throw 'backup simulado falhou' }
    $n = $Entrada.itens.Count + 1
    $destino = Join-Path (Join-Path $Entrada.pasta 'itens') ([string]$n)
    New-Item -ItemType Directory -Path $destino -Force -ErrorAction Stop | Out-Null
    try { Export-ChaveRegistro -Chave $Chave -Arquivo (Join-Path $destino 'chave.reg') -Teste $teste }
    catch { try { Remove-PastaSegura $destino } catch { $null = $_ }; throw }
    $Entrada.itens.Add([ordered]@{ n = $n; tipo = 'chave'; origem = $Chave; nome = 'chave.reg' })
}

function Invoke-Reparar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $ids = @(Get-IdsParam $Params)
    if ($ids.Count -eq 0) { Send-Result $Id $null $false 'nenhum produto informado'; return }
    $sim = Get-Simulacao $Params $Teste
    $simulados = if ($null -ne $sim -and $null -ne $sim.produtos) { @($sim.produtos) } else { $null }
    if ($Teste -and $null -eq $simulados) { $simulados = @() }
    # Relê o diagnostico agora: a UI pode estar velha e o produto pode ter deixado de ser orfao.
    $atuais = @{}
    foreach ($p in @(Get-DiagnosticoMsi $simulados)) { $atuais[([string]$p.codigo).ToUpperInvariant()] = $p }
    $entrada = New-EntradaQuarentena 'reparo' 'Registro do instalador removido pelo Reparo' $Teste
    $reparados = New-Object System.Collections.Generic.List[string]
    $falhas = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($guid in $ids) {
        Send-Progress $Id ([int](100 * $i / $ids.Count)) "Reparando $guid"
        $i++
        try {
            $null = ConvertTo-GuidCompactado $guid   # recusa texto que nao seja GUID antes de montar qualquer chave
            $p = $atuais[([string]$guid).ToUpperInvariant()]
            if ($null -eq $p) { throw 'já não está quebrado (ou não existe): nada a fazer' }
            if (-not $p.reparavel) { throw ([string]$p.motivo) }
            $existentes = @(Get-ChaveProduto $guid $Teste | Where-Object { Test-Path -LiteralPath (ConvertTo-CaminhoRegistro $_) })
            # Fase 1: todos os backups. Se qualquer um falhar, nada deste produto e removido.
            $antes = $entrada.itens.Count
            try { foreach ($k in $existentes) { Save-ChaveQuarentena $entrada $k $sim } }
            catch { while ($entrada.itens.Count -gt $antes) { $entrada.itens.RemoveAt($entrada.itens.Count - 1) }; throw }
            # Fase 2: remove o registro (o backup ja esta na quarentena e restaura tudo).
            foreach ($k in $existentes) { Remove-Item -LiteralPath (ConvertTo-CaminhoRegistro $k) -Recurse -Force -ErrorAction Stop }
            $reparados.Add($guid)
            Write-AppLog ("reparo: registro de {0} ({1}) removido; backup na quarentena {2}" -f $guid, $p.nome, $entrada.id) $Teste
        } catch {
            $falhas.Add([ordered]@{ id = [string]$guid; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ("Falha em ${guid}: " + $_.Exception.Message)
            Write-AppLog ("reparo: {0} falhou: {1}" -f $guid, $_.Exception.Message) $Teste
        }
    }
    $fechada = Complete-EntradaQuarentena $entrada
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ reparados = $reparados.ToArray(); falhas = $falhas.ToArray(); entrada = $(if ($null -ne $fechada) { $fechada.id } else { $null }) })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('diagnosticar', 'reparar') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'diagnosticar' { Invoke-Diagnosticar $Id $Params $Teste }
            'reparar' { Invoke-Reparar $Id $Params $Teste }
        }
    } catch {
        $msg = 'reparo falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
