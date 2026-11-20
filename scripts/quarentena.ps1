# quarentena.ps1 - quarentena de arquivos, pastas e chaves de registro removidos pelos outros modulos.
# Acoes: listar {dias?}, restaurar {ids}, purgar {ids, confirmado}, purgarVencidos {dias}.
# Funcoes para outros modulos (dot-source): New-EntradaQuarentena, Add-ItemQuarentena,
# Complete-EntradaQuarentena, Export-ChaveRegistro, Restore-ChaveRegistro.
# Layout: <Quarentena>\<id>\manifesto.json + <Quarentena>\<id>\itens\<n>\<nome> (chave: itens\<n>\chave.reg).
# Nada sai da quarentena antes do prazo sem clique: purgar exige confirmado:true e purgarVencidos
# so remove entradas cuja data + dias ja passou. Toda escrita vai para Write-AppLog.
. "$PSScriptRoot\common.ps1"

$Script:DiasPadrao = 7
$Script:MaxIds = 200
$Script:PrefixoChaveTeste = 'HKCU\Software\NexTuneTeste'
$Script:RegExe = "$env:windir\System32\reg.exe"
$Script:TiposItem = @('arquivo', 'pasta', 'chave')
$Script:RaizRegistro = @{
    HKCU                = 'HKEY_CURRENT_USER'
    HKEY_CURRENT_USER   = 'HKEY_CURRENT_USER'
    HKLM                = 'HKEY_LOCAL_MACHINE'
    HKEY_LOCAL_MACHINE  = 'HKEY_LOCAL_MACHINE'
    HKU                 = 'HKEY_USERS'
    HKEY_USERS          = 'HKEY_USERS'
    HKCR                = 'HKEY_CLASSES_ROOT'
    HKEY_CLASSES_ROOT   = 'HKEY_CLASSES_ROOT'
    HKCC                = 'HKEY_CURRENT_CONFIG'
    HKEY_CURRENT_CONFIG = 'HKEY_CURRENT_CONFIG'
}

function Test-ParamVerdadeiro {
    # Somente o booleano $true vale (a string 'true' NAO vale).
    param($Params, [string]$Nome)
    if ($null -eq $Params) { return $false }
    $v = $Params.$Nome
    return ($v -is [bool] -and $v -eq $true)
}

function Test-IdQuarentena {
    # Puro: id no formato yyyyMMdd-HHmmss-xxxx (4 hex minusculos).
    param($Id)
    return ($Id -is [string] -and $Id -cmatch '^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$')
}

# ---------- registro ----------

function Test-ChaveRegistro {
    # Puro: o texto tem a forma de chave aceita pelo reg.exe (HKCU\..., HKEY_LOCAL_MACHINE\...)?
    param([string]$Chave)
    if ([string]::IsNullOrWhiteSpace($Chave)) { return $false }
    if ($Chave -match '[\r\n"]') { return $false }
    if ($Chave -notmatch '^[A-Za-z_]+\\[^\\]') { return $false }
    $raiz = @($Chave -split '\\', 2)[0]
    return $Script:RaizRegistro.ContainsKey($raiz)
}

function ConvertTo-CaminhoRegistro {
    # 'HKCU\Software\X' (forma do reg.exe) -> 'Registry::HKEY_CURRENT_USER\Software\X' (forma do provedor).
    param([string]$Chave)
    if (-not (Test-ChaveRegistro $Chave)) { throw "chave de registro inválida: $Chave" }
    $partes = @($Chave.TrimEnd('\') -split '\\', 2)
    return ('Registry::' + $Script:RaizRegistro[$partes[0]] + '\' + $partes[1])
}

function Test-ChaveTeste {
    # Puro: a chave esta sob HKCU\Software\NexTuneTeste (unica area permitida em modo teste)?
    param([string]$Chave)
    if (-not (Test-ChaveRegistro $Chave)) { return $false }
    $prefixo = (ConvertTo-CaminhoRegistro $Script:PrefixoChaveTeste) + '\'
    return (ConvertTo-CaminhoRegistro $Chave).StartsWith($prefixo, [StringComparison]::OrdinalIgnoreCase)
}

function Confirm-ChavePermitida {
    # Lanca se a chave for invalida ou, em modo teste, estiver fora de HKCU\Software\NexTuneTeste.
    param([string]$Chave, [bool]$Teste)
    if (-not (Test-ChaveRegistro $Chave)) { throw "chave de registro inválida: $Chave" }
    if ($Teste -and -not (Test-ChaveTeste $Chave)) {
        throw "em modo teste só chaves sob $($Script:PrefixoChaveTeste) são aceitas: $Chave"
    }
}

function Export-ChaveRegistro {
    # Exporta a chave para um .reg (UTF-16 LE com BOM, como o reg.exe gera). Argumentos em lista, nunca string unica.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Chave, [string]$Arquivo, [bool]$Teste = $false)
    Confirm-ChavePermitida $Chave $Teste
    if ([string]::IsNullOrWhiteSpace($Arquivo)) { throw 'arquivo de destino do .reg não informado' }
    $saida = @(& $Script:RegExe export $Chave $Arquivo /y 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "reg.exe export falhou (código ${LASTEXITCODE}): $(($saida -join ' ').Trim())" }
    if (-not (Test-Path -LiteralPath $Arquivo -PathType Leaf)) { throw "reg.exe não gerou o arquivo $Arquivo" }
}

function Test-ConteudoReg {
    # Puro: toda chave nomeada no .reg ([HKEY_...] ou [-HKEY_...]) e a chave esperada ou subchave dela,
    # e ha pelo menos uma? Compara pelo nome longo da raiz, sem diferenciar caixa.
    param([string[]]$Linhas, [string]$Chave)
    $alvo = (ConvertTo-CaminhoRegistro $Chave).Substring('Registry::'.Length)
    $achou = $false
    foreach ($l in @($Linhas)) {
        if ($l -notmatch '^\[-?HKEY_') { continue }
        if ($l -match '^\[-?(HKEY_.*)\]\s*$') { $k = $Matches[1].TrimEnd('\') } else { return $false }
        if (-not ($k.Equals($alvo, [StringComparison]::OrdinalIgnoreCase) -or $k.StartsWith($alvo + '\', [StringComparison]::OrdinalIgnoreCase))) { return $false }
        $achou = $true
    }
    return $achou
}

function Get-LinhaReg {
    # Linhas de um .reg (UTF-16 LE com BOM, como o reg.exe gera; UTF-8 se nao houver BOM).
    param([string]$Arquivo)
    $sr = New-Object System.IO.StreamReader($Arquivo, [System.Text.Encoding]::UTF8, $true)
    try { $texto = $sr.ReadToEnd() } finally { $sr.Dispose() }
    return @($texto -split "`r?`n")
}

function Restore-ChaveRegistro {
    # Reimporta um .reg gerado por Export-ChaveRegistro. -Chave e a origem do manifesto: em modo teste e
    # conferida contra a area de teste e, sempre que informada, o .reg so pode nomear essa chave ou subchaves.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Arquivo, [string]$Chave = '', [bool]$Teste = $false)
    if ($Teste -or -not [string]::IsNullOrEmpty($Chave)) { Confirm-ChavePermitida $Chave $Teste }
    if (-not (Test-Path -LiteralPath $Arquivo -PathType Leaf)) { throw "arquivo .reg não encontrado: $Arquivo" }
    if (-not [string]::IsNullOrEmpty($Chave) -and -not (Test-ConteudoReg (Get-LinhaReg $Arquivo) $Chave)) {
        throw "o arquivo .reg não corresponde à chave $Chave (nomeia outra chave ou nenhuma)"
    }
    $saida = @(& $Script:RegExe import $Arquivo 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0) { throw "reg.exe import falhou (código ${LASTEXITCODE}): $(($saida -join ' ').Trim())" }
}

# ---------- disco ----------

function Remove-PastaSegura {
    # Apaga uma pasta recursivamente sem seguir junctions/links (so o proprio link e removido):
    # Remove-Item -Recurse do PS 5.1 entraria no alvo da junction.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Pasta)
    $item = Get-Item -LiteralPath $Pasta -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop; return }
    if (Test-Reparse $item) { [IO.Directory]::Delete($item.FullName); return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Pasta -Force -ErrorAction Stop)) {
        if ($f.PSIsContainer) {
            if (Test-Reparse $f) { [IO.Directory]::Delete($f.FullName) }
            else { Remove-PastaSegura $f.FullName }
        } else {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
    }
    Remove-Item -LiteralPath $Pasta -Force -ErrorAction Stop
}

function Test-ArvoreSemLink {
    # $true se nenhum descendente da pasta for junction/link. Desce sem seguir links (mesma pilha de
    # Get-PathSize); pasta ilegivel conta como inseguro.
    param([string]$Pasta)
    try {
        $pilha = New-Object System.Collections.Generic.Stack[string]
        $pilha.Push($Pasta)
        while ($pilha.Count -gt 0) {
            foreach ($f in @(Get-ChildItem -LiteralPath $pilha.Pop() -Force -ErrorAction Stop)) {
                if (Test-Reparse $f) { return $false }
                if ($f.PSIsContainer) { $pilha.Push($f.FullName) }
            }
        }
        return $true
    } catch { return $false }
}

function ConvertTo-DataUtc {
    # Aceita string ISO 8601 ou [DateTime] (ConvertFrom-Json pode devolver qualquer dos dois). $null se invalido.
    param($Valor)
    if ($null -eq $Valor) { return $null }
    $dt = [DateTime]::MinValue
    if ($Valor -is [DateTime]) { $dt = $Valor }
    elseif (-not [DateTime]::TryParse([string]$Valor, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dt)) { return $null }
    if ($dt.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
    return $dt.ToUniversalTime()
}

function Write-Manifesto {
    # Grava manifesto.json em UTF-8 sem BOM.
    param([string]$Pasta, $Manifesto)
    $json = $Manifesto | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $Pasta 'manifesto.json'), $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-Manifesto {
    # Le e valida manifesto.json da pasta da entrada; $null se ausente, ilegivel ou sem os campos minimos.
    param([string]$Pasta)
    $arq = Join-Path $Pasta 'manifesto.json'
    if (-not (Test-Path -LiteralPath $arq -PathType Leaf)) { return $null }
    try {
        $m = Get-Content -LiteralPath $arq -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($m -isnot [pscustomobject]) { return $null }
        if ($null -eq $m.itens -or $null -eq (ConvertTo-DataUtc $m.data)) { return $null }
        return $m
    } catch { return $null }
}

function Test-ItemManifesto {
    # Puro: o item do manifesto tem forma segura para montar caminhos? n inteiro; nome e um nome simples
    # (sem separadores, nem . ou ..); origem e chave valida ou caminho absoluto com letra de unidade.
    param($Item)
    if ($null -eq $Item) { return $false }
    $tipo = [string]$Item.tipo
    $nome = [string]$Item.nome
    $origem = [string]$Item.origem
    if ($Script:TiposItem -cnotcontains $tipo) { return $false }
    if (([string]$Item.n) -notmatch '^[0-9]+$') { return $false }
    if ([string]::IsNullOrWhiteSpace($nome) -or $nome -eq '.' -or $nome -eq '..') { return $false }
    try { if ([IO.Path]::GetFileName($nome) -ne $nome) { return $false } } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($origem)) { return $false }
    if ($tipo -eq 'chave') { return (Test-ChaveRegistro $origem) }
    if ($origem -notmatch '^[A-Za-z]:\\' -or $origem -match '[\r\n]') { return $false }
    try { return [IO.Path]::IsPathRooted($origem) } catch { return $false }
}

function Get-FonteItem {
    # Caminho do item dentro da entrada: <pasta>\itens\<n>\<nome>. So para itens ja validados por Test-ItemManifesto.
    param([string]$Pasta, $Item)
    return (Join-Path (Join-Path (Join-Path $Pasta 'itens') ([string]$Item.n)) ([string]$Item.nome))
}

# ---------- entradas (uso pelos outros modulos) ----------

function New-PastaEntrada {
    # Cria <Base>\<id> com id yyyyMMdd-HHmmss-xxxx (4 hex); se ja existir, sorteia de novo. Devolve o id.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Base)
    for ($tent = 0; $tent -lt 50; $tent++) {
        $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + ('{0:x4}' -f (Get-Random -Minimum 0 -Maximum 65536))
        $pasta = Join-Path $Base $id
        if (Test-Path -LiteralPath $pasta) { continue }
        try {
            New-Item -ItemType Directory -Path $pasta -ErrorAction Stop | Out-Null
            return $id
        } catch {
            # Colisao (a pasta surgiu entre o teste e a criacao) sorteia de novo; qualquer outra falha sobe.
            if (-not (Test-Path -LiteralPath $pasta)) { throw }
        }
    }
    throw 'não foi possível reservar um id de quarentena'
}

function New-EntradaQuarentena {
    # Abre uma entrada (pasta reservada + itens vazia). Feche com Complete-EntradaQuarentena.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Modulo, [string]$Descricao = '', [bool]$Teste = $false)
    if ([string]::IsNullOrWhiteSpace($Modulo)) { throw 'módulo da entrada de quarentena não informado' }
    $base = (Get-AppPastas $Teste).Quarentena
    $id = New-PastaEntrada $base
    $pasta = Join-Path $base $id
    New-Item -ItemType Directory -Path (Join-Path $pasta 'itens') -Force -ErrorAction Stop | Out-Null
    return [pscustomobject]@{
        id        = $id
        data      = (Get-Date).ToUniversalTime().ToString('o')
        modulo    = $Modulo
        descricao = [string]$Descricao
        pasta     = $pasta
        teste     = $Teste
        itens     = (New-Object System.Collections.Generic.List[object])
    }
}

function Add-ItemQuarentena {
    # Move um arquivo/pasta (ou exporta e remove uma chave de registro) para a entrada. Lanca em caminho
    # protegido, junction/link, chave fora da area de teste (em teste) ou item inexistente: nada e movido.
    # -Tipo 'chave' forca a leitura como chave; vazio detecta pela forma do caminho.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Entrada, [string]$Caminho, [string]$Tipo = '')
    if ($null -eq $Entrada -or [string]::IsNullOrEmpty([string]$Entrada.pasta)) { throw 'entrada de quarentena inválida' }
    if ([string]::IsNullOrWhiteSpace($Caminho)) { throw 'caminho do item não informado' }
    $teste = [bool]$Entrada.teste
    $ehChave = ($Tipo -eq 'chave') -or ([string]::IsNullOrEmpty($Tipo) -and (Test-ChaveRegistro $Caminho))
    $n = $Entrada.itens.Count + 1
    $destino = Join-Path (Join-Path $Entrada.pasta 'itens') ([string]$n)
    $prov = $null
    if ($ehChave) {
        Confirm-ChavePermitida $Caminho $teste
        $prov = ConvertTo-CaminhoRegistro $Caminho
        if (-not (Test-Path -LiteralPath $prov)) { throw "chave de registro não encontrada: $Caminho" }
        $origem = $Caminho
        $nome = 'chave.reg'
        $tipoFinal = 'chave'
    } else {
        if (Test-ProtectedPath $Caminho) { throw "caminho protegido, não vai para a quarentena: $Caminho" }
        $item = Get-Item -LiteralPath $Caminho -Force -ErrorAction Stop
        $origem = $item.FullName
        if (Test-ProtectedPath $origem) { throw "caminho protegido, não vai para a quarentena: $origem" }
        if (Test-Reparse $item) { throw "link ou junção recusado, não vai para a quarentena: $origem" }
        if (-not (Test-CadeiaSemLink $origem)) { throw "caminho dentro de link ou junção recusado, não vai para a quarentena: $origem" }
        # Move-Item entre volumes vira copia + apagamento e SEGUIRIA junctions dentro da arvore.
        if ($item.PSIsContainer -and -not (Test-ArvoreSemLink $origem)) { throw "pasta com link ou junção dentro recusada, não vai para a quarentena: $origem" }
        $nome = $item.Name
        if ($item.PSIsContainer) { $tipoFinal = 'pasta' } else { $tipoFinal = 'arquivo' }
    }
    New-Item -ItemType Directory -Path $destino -Force -ErrorAction Stop | Out-Null
    $registro = [ordered]@{ n = $n; tipo = $tipoFinal; origem = $origem; nome = $nome }
    try {
        if ($ehChave) {
            Export-ChaveRegistro -Chave $origem -Arquivo (Join-Path $destino $nome) -Teste $teste
            Remove-Item -LiteralPath $prov -Recurse -Force -ErrorAction Stop
        } else {
            # O destino e a pasta itens\<n> (o nome vem do -LiteralPath): nada de curingas no -Destination.
            Move-Item -LiteralPath $origem -Destination $destino -ErrorAction Stop
        }
    } catch {
        $erroOriginal = $_
        if (@(Get-ChildItem -LiteralPath $destino -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            # Nada chegou aqui: descarta a pasta do item e repassa o erro.
            try { Remove-PastaSegura $destino } catch { $null = $_ }
            throw $erroOriginal
        }
        # Algo ja esta aqui (ex.: .reg exportado e chave removida pela metade): e o unico backup, entao o
        # item fica registrado para o manifesto e o erro avisa que foi parcial.
        $Entrada.itens.Add($registro)
        $msg = "item $n parcial na quarentena $($Entrada.id) ($tipoFinal $origem): $($erroOriginal.Exception.Message)"
        Write-AppLog "quarentena $($Entrada.id): $msg" $teste
        throw $msg
    }
    $Entrada.itens.Add($registro)
    Write-AppLog ("quarentena {0}: {1} movido para a quarentena: {2}" -f $Entrada.id, $tipoFinal, $origem) $teste
    return [pscustomobject]$registro
}

function Complete-EntradaQuarentena {
    # Grava o manifesto. Entrada sem itens e apagada e devolve $null; com itens devolve a propria entrada.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Entrada)
    if ($null -eq $Entrada) { return $null }
    $teste = [bool]$Entrada.teste
    if ($Entrada.itens.Count -eq 0) {
        if (Test-Path -LiteralPath $Entrada.pasta) { Remove-PastaSegura $Entrada.pasta }
        return $null
    }
    $m = [ordered]@{
        id        = $Entrada.id
        data      = $Entrada.data
        modulo    = $Entrada.modulo
        descricao = $Entrada.descricao
        itens     = @($Entrada.itens.ToArray())
    }
    Write-Manifesto $Entrada.pasta $m
    Write-AppLog ("quarentena {0}: entrada de '{1}' fechada com {2} item(ns): {3}" -f $Entrada.id, $Entrada.modulo, $Entrada.itens.Count, $Entrada.descricao) $teste
    return $Entrada
}

# ---------- leitura das entradas ----------

function Get-ListaQuarentena {
    # Entradas existentes (so pastas com nome de id), da mais nova para a mais antiga.
    # Manifesto ilegivel: manifesto=$null e a data e a de criacao da pasta.
    param([bool]$Teste)
    $base = (Get-AppPastas $Teste).Quarentena
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-IdQuarentena $d.Name) -or (Test-Reparse $d)) { continue }
        $m = Get-Manifesto $d.FullName
        $dataUtc = $null
        if ($null -ne $m) { $dataUtc = ConvertTo-DataUtc $m.data }
        if ($null -eq $dataUtc) { $dataUtc = $d.CreationTimeUtc }
        $lista.Add([pscustomobject]@{ id = $d.Name; pasta = $d.FullName; manifesto = $m; dataUtc = $dataUtc })
    }
    return @($lista.ToArray() | Sort-Object -Property @{ Expression = 'dataUtc'; Descending = $true }, @{ Expression = 'id'; Descending = $true })
}

function Remove-EntradaQuarentena {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Pasta, [bool]$Teste)
    Remove-PastaSegura $Pasta
    Write-AppLog ("quarentena {0}: entrada apagada" -f (Split-Path -Leaf $Pasta)) $Teste
}

function Get-ConflitoRestauracao {
    # Confere cada item ANTES de mover qualquer um. Devolve problemas: conflito=$true (origem ocupada ou
    # protegida; a entrada fica) ou conflito=$false (falha: manifesto invalido, item ausente na quarentena).
    param([string]$Pasta, $Itens, [bool]$Teste)
    $probl = New-Object System.Collections.Generic.List[object]
    foreach ($it in $Itens) {
        $origem = [string]$it.origem
        $tipo = [string]$it.tipo
        if (-not (Test-ItemManifesto $it)) {
            $probl.Add(@{ conflito = $false; item = $origem; motivo = 'manifesto inválido (item com nome ou origem fora do formato)' })
            continue
        }
        if (-not (Test-Path -LiteralPath (Get-FonteItem $Pasta $it))) {
            $probl.Add(@{ conflito = $false; item = $origem; motivo = "item ausente na quarentena: $($it.nome)" })
            continue
        }
        if ($tipo -eq 'chave') {
            if ($Teste -and -not (Test-ChaveTeste $origem)) { $probl.Add(@{ conflito = $true; item = $origem; motivo = 'chave fora da área de teste' }); continue }
            if (Test-Path -LiteralPath (ConvertTo-CaminhoRegistro $origem)) { $probl.Add(@{ conflito = $true; item = $origem; motivo = 'a chave voltou a existir no registro' }) }
        } else {
            if (Test-ProtectedPath $origem) { $probl.Add(@{ conflito = $true; item = $origem; motivo = 'origem em caminho protegido' }); continue }
            if (-not (Test-CadeiaSemLink $origem)) { $probl.Add(@{ conflito = $true; item = $origem; motivo = 'origem dentro de link ou junção' }); continue }
            if (Test-Path -LiteralPath $origem) { $probl.Add(@{ conflito = $true; item = $origem; motivo = 'já existe algo na origem' }) }
        }
    }
    return $probl.ToArray()
}

function Restore-ItemQuarentena {
    # Devolve UM item a origem (ja conferida por Get-ConflitoRestauracao).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Pasta, $Item, [bool]$Teste)
    $fonte = Get-FonteItem $Pasta $Item
    $origem = [string]$Item.origem
    if ([string]$Item.tipo -eq 'chave') {
        Restore-ChaveRegistro -Arquivo $fonte -Chave $origem -Teste $Teste
        return
    }
    $pai = [IO.Path]::GetDirectoryName($origem)
    if (-not [string]::IsNullOrEmpty($pai) -and -not (Test-Path -LiteralPath $pai)) { $null = [IO.Directory]::CreateDirectory($pai) }
    if (-not [string]::IsNullOrEmpty($pai) -and [IO.Path]::GetFileName($origem) -eq [string]$Item.nome) {
        # Move para a pasta pai (o nome vem do -LiteralPath): nada de curingas no -Destination.
        Move-Item -LiteralPath $fonte -Destination $pai -ErrorAction Stop
    } else {
        Move-Item -LiteralPath $fonte -Destination $origem -ErrorAction Stop
    }
}

# ---------- parametros ----------

function Get-ListaId {
    # Valida params.ids: lista nao vazia de ids no formato certo, sem repeticao, ate 200. Devolve @{ ids; erro }.
    param($Params)
    $vazio = @{ ids = @(); erro = 'nenhuma entrada informada' }
    if ($null -eq $Params -or $null -eq $Params.ids -or $Params.ids -is [string]) { return $vazio }
    $ids = @($Params.ids)
    if ($ids.Count -eq 0) { return $vazio }
    if ($ids.Count -gt $Script:MaxIds) { return @{ ids = @(); erro = "muitas entradas de uma vez (máximo $($Script:MaxIds))" } }
    foreach ($i in $ids) {
        if (-not (Test-IdQuarentena $i)) { return @{ ids = @(); erro = "id de quarentena inválido: $i" } }
    }
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { return @{ ids = @(); erro = 'id de quarentena repetido' } }
    return @{ ids = $ids; erro = $null }
}

function Get-PrazoParam {
    # Valida params.dias (inteiro 1..90). Padrao > 0 = valor usado quando ausente; 0 = obrigatorio. Devolve @{ dias; erro }.
    param($Params, [int]$Padrao = 0)
    $v = $null
    if ($null -ne $Params) { $v = $Params.dias }
    if ($null -eq $v) {
        if ($Padrao -gt 0) { return @{ dias = $Padrao; erro = $null } }
        return @{ dias = 0; erro = 'dias não informado' }
    }
    if ($v -isnot [ValueType] -or $v -is [bool]) { return @{ dias = 0; erro = 'dias inválido' } }
    $n = 0
    try { $n = [int]$v } catch { return @{ dias = 0; erro = 'dias inválido' } }
    if ([double]$v -ne [double]$n -or $n -lt 1 -or $n -gt 90) { return @{ dias = 0; erro = 'dias fora do intervalo 1..90' } }
    return @{ dias = $n; erro = $null }
}

# ---------- acoes ----------

function Invoke-Listar {
    param([string]$Id, $Params, [bool]$Teste)
    $d = Get-PrazoParam $Params $Script:DiasPadrao
    if ($null -ne $d.erro) { Send-Result $Id $null $false $d.erro; return }
    $entradas = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-ListaQuarentena $Teste)) {
        $m = $e.manifesto
        $modulo = ''
        $descricao = '(manifesto ilegível)'
        $qtd = 0
        if ($null -ne $m) {
            $modulo = [string]$m.modulo
            $descricao = [string]$m.descricao
            $qtd = @($m.itens).Count
        }
        $entradas.Add([ordered]@{
            id           = $e.id
            data         = $e.dataUtc.ToString('o')
            modulo       = $modulo
            descricao    = $descricao
            itens        = $qtd
            tamanhoBytes = (Get-PathSize $e.pasta)
            venceEm      = $e.dataUtc.AddDays($d.dias).ToString('o')
        })
    }
    Send-Result $Id ([ordered]@{ entradas = $entradas.ToArray(); diasPadrao = $Script:DiasPadrao })
}

function Invoke-Restaurar {
    param([string]$Id, $Params, [bool]$Teste)
    $v = Get-ListaId $Params
    if ($null -ne $v.erro) { Send-Result $Id $null $false $v.erro; return }
    $base = (Get-AppPastas $Teste).Quarentena
    $restauradas = New-Object System.Collections.Generic.List[object]
    $conflitos = New-Object System.Collections.Generic.List[object]
    $falhas = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($eid in $v.ids) {
        Send-Progress $Id ([int](100 * $i / $v.ids.Count)) "Restaurando $eid"
        $i++
        $pasta = Join-Path $base $eid
        if (-not (Test-Path -LiteralPath $pasta -PathType Container)) {
            $falhas.Add([ordered]@{ id = $eid; erro = 'entrada não encontrada' })
            continue
        }
        $m = Get-Manifesto $pasta
        if ($null -eq $m) {
            $falhas.Add([ordered]@{ id = $eid; erro = 'manifesto ilegível: esta entrada só pode ser apagada' })
            continue
        }
        $itens = @($m.itens)
        if ($itens.Count -eq 0) { $falhas.Add([ordered]@{ id = $eid; erro = 'entrada sem itens' }); continue }

        # 1) Confere TODOS os itens antes de mover qualquer um: com um conflito a entrada inteira fica.
        $probl = @(Get-ConflitoRestauracao $pasta $itens $Teste)
        $fatais = @($probl | Where-Object { -not $_.conflito })
        if ($fatais.Count -gt 0) { $falhas.Add([ordered]@{ id = $eid; erro = $fatais[0].motivo }); continue }
        if ($probl.Count -gt 0) {
            foreach ($p in $probl) {
                $conflitos.Add([ordered]@{ id = $eid; item = $p.item; motivo = $p.motivo })
                Send-Log $Id 'aviso' ("Conflito ao restaurar ${eid}: " + $p.motivo) $p.item
            }
            continue
        }

        # 2) Move tudo de volta; se um item falhar no meio, o manifesto passa a listar so o que ainda esta aqui.
        $erro = $null
        for ($k = 0; $k -lt $itens.Count; $k++) {
            try { Restore-ItemQuarentena $pasta $itens[$k] $Teste }
            catch { $erro = "$($itens[$k].origem): $($_.Exception.Message)"; break }
        }
        if ($null -ne $erro) {
            if ($k -gt 0) {
                $novo = [ordered]@{
                    id        = $eid
                    data      = (ConvertTo-DataUtc $m.data).ToString('o')
                    modulo    = [string]$m.modulo
                    descricao = [string]$m.descricao
                    itens     = @($itens[$k..($itens.Count - 1)])
                }
                Write-Manifesto $pasta $novo
            }
            $falhas.Add([ordered]@{ id = $eid; erro = $erro })
            Send-Log $Id 'aviso' ("Falha ao restaurar ${eid}: " + $erro)
            Write-AppLog "quarentena ${eid}: restauração parcial ($k de $($itens.Count) itens): $erro" $Teste
            continue
        }
        try { Remove-PastaSegura $pasta }
        catch { Send-Log $Id 'aviso' "Itens restaurados, mas a pasta da entrada não pôde ser removida: $($_.Exception.Message)" $pasta }
        $restauradas.Add($eid)
        Write-AppLog "quarentena ${eid}: restaurada ($($itens.Count) itens)" $Teste
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ restauradas = $restauradas.ToArray(); conflitos = $conflitos.ToArray(); falhas = $falhas.ToArray() })
}

function Invoke-Purgar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'apagar da quarentena exige confirmação'; return }
    $v = Get-ListaId $Params
    if ($null -ne $v.erro) { Send-Result $Id $null $false $v.erro; return }
    $base = (Get-AppPastas $Teste).Quarentena
    $removidas = New-Object System.Collections.Generic.List[object]
    $falhas = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($eid in $v.ids) {
        Send-Progress $Id ([int](100 * $i / $v.ids.Count)) "Apagando $eid"
        $i++
        $pasta = Join-Path $base $eid
        if (-not (Test-Path -LiteralPath $pasta -PathType Container)) {
            $falhas.Add([ordered]@{ id = $eid; erro = 'entrada não encontrada' })
            continue
        }
        try {
            Remove-EntradaQuarentena $pasta $Teste
            $removidas.Add($eid)
        } catch {
            $falhas.Add([ordered]@{ id = $eid; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ("Falha ao apagar ${eid}: " + $_.Exception.Message) $pasta
        }
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ removidas = $removidas.ToArray(); falhas = $falhas.ToArray() })
}

function Invoke-PurgarVencidos {
    # So remove entradas cuja data + dias ja passou; as demais ficam intactas.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Id, $Params, [bool]$Teste)
    $d = Get-PrazoParam $Params
    if ($null -ne $d.erro) { Send-Result $Id $null $false $d.erro; return }
    $agora = [DateTime]::UtcNow
    $removidas = New-Object System.Collections.Generic.List[object]
    $lista = @(Get-ListaQuarentena $Teste)
    $i = 0
    foreach ($e in $lista) {
        Send-Progress $Id ([int](100 * $i / [math]::Max(1, $lista.Count))) "Verificando $($e.id)"
        $i++
        if ($e.dataUtc.AddDays($d.dias) -ge $agora) { continue }
        try {
            Remove-EntradaQuarentena $e.pasta $Teste
            $removidas.Add($e.id)
        } catch {
            Send-Log $Id 'aviso' ("Falha ao apagar entrada vencida $($e.id): " + $_.Exception.Message) $e.pasta
            Write-AppLog "quarentena $($e.id): falha ao apagar entrada vencida: $($_.Exception.Message)" $Teste
        }
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ removidas = $removidas.ToArray() })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'restaurar', 'purgar', 'purgarVencidos') -cnotcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-Listar $Id $Params $Teste }
            'restaurar' { Invoke-Restaurar $Id $Params $Teste }
            'purgar' { Invoke-Purgar $Id $Params $Teste }
            'purgarVencidos' { Invoke-PurgarVencidos $Id $Params $Teste }
        }
    } catch {
        $msg = 'quarentena falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
