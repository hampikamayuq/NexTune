# espaco.ps1 - analisador de espaco (so leitura): onde esta o espaco ocupado dentro de uma pasta.
# Acao: analisar {raiz, tetoSegundos?} -> {raiz, totalBytes, incompleto,
#        pastas: [{caminho, nome, bytes, semAcesso, parcial}], arquivos: [{caminho, nome, bytes}]}.
# pastas = as 20 maiores do primeiro nivel e arquivos = os 20 maiores da arvore percorrida, do maior para o menor;
# bytes -1 = nao deu para medir. Os arquivos soltos na raiz entram em totalBytes e em arquivos, nao em pastas.
# "Um nivel abaixo" = nova chamada com raiz = a pasta clicada.
# Review Focus 5: junction/link (pasta ou arquivo) nunca e seguido nem somado, em nivel nenhum; um link no primeiro
# nivel aparece com bytes 0. Pasta do primeiro nivel que nao pode ser listada vem com semAcesso e bytes -1 (nunca 0);
# subpasta ilegivel ou teto estourado no meio marca parcial. Um unico relogio limita a analise inteira (tetoSegundos
# 5..300, padrao 60): estourou -> incompleto, e as pastas nao alcancadas vem com bytes -1 e parcial.
# Nao grava nada (nem log): apagar continua sendo pela Limpeza ou pela quarentena.
# Em modo teste: simular {negarAcesso?: [caminho], tetoMs?}. negarAcesso faz a listagem dessas pastas falhar como
# "acesso negado" (sem mexer em ACL); tetoMs troca o teto, em milissegundos (0 = so a primeira pasta comeca).
# As pastas de teste ficam em %TEMP%\NexTuneTeste\espaco.
. "$PSScriptRoot\common.ps1"

$Script:MaxItensEspaco = 20
$Script:TetoPadraoSegundos = 60
$Script:TetoMinSegundos = 5
$Script:TetoMaxSegundos = 300
$Script:MaxCaminhoRaiz = 260
# De quantas em quantas entradas de uma mesma pasta o relogio e conferido (pasta com milhoes de arquivos).
$Script:ConferirRelogioACada = 4096

# ---------- funcoes puras ----------

function Get-TetoParam {
    # Valida params.tetoSegundos (inteiro 5..300; ausente = 60). Devolve @{ segundos; erro }.
    param($Params)
    $v = $null
    if ($null -ne $Params) { $v = $Params.tetoSegundos }
    if ($null -eq $v) { return @{ segundos = $Script:TetoPadraoSegundos; erro = $null } }
    if ($v -isnot [ValueType] -or $v -is [bool]) { return @{ segundos = 0; erro = 'tetoSegundos inválido' } }
    $n = 0
    try { $n = [int]$v } catch { return @{ segundos = 0; erro = 'tetoSegundos inválido' } }
    if ([double]$v -ne [double]$n -or $n -lt $Script:TetoMinSegundos -or $n -gt $Script:TetoMaxSegundos) {
        return @{ segundos = 0; erro = ('tetoSegundos fora do intervalo {0}..{1}' -f $Script:TetoMinSegundos, $Script:TetoMaxSegundos) }
    }
    return @{ segundos = $n; erro = $null }
}

function Add-ItemLimitado {
    # Lista em ordem crescente de .bytes que guarda so os $Max maiores: cada arquivo custa uma comparacao com o menor
    # guardado (sem ordenar a arvore inteira). Empate com o menor, com a lista cheia, fica de fora.
    param($Lista, $Item, [int]$Max)
    if ($Lista.Count -ge $Max) {
        if ($Item.bytes -le $Lista[0].bytes) { return }
        $Lista.RemoveAt(0)
    }
    $i = 0
    while ($i -lt $Lista.Count -and $Lista[$i].bytes -lt $Item.bytes) { $i++ }
    $Lista.Insert($i, $Item)
}

# ---------- leitura ----------

function Get-RaizAnalise {
    # Valida a raiz: caminho absoluto de pasta (^[A-Za-z]:\), ate 260 caracteres, existente e sem link na cadeia.
    # Devolve @{ caminho (normalizado, sem barra no fim exceto na raiz da unidade); erro }.
    param($Raiz)
    if ($Raiz -isnot [string] -or [string]::IsNullOrWhiteSpace($Raiz)) { return @{ caminho = $null; erro = 'raiz não informada' } }
    if ($Raiz.Length -gt $Script:MaxCaminhoRaiz) {
        return @{ caminho = $null; erro = ('caminho longo demais (máximo de {0} caracteres)' -f $Script:MaxCaminhoRaiz) }
    }
    if ($Raiz -notmatch '^[A-Za-z]:\\' -or $Raiz -match '[\x00-\x1F"*?<>|]') {
        return @{ caminho = $null; erro = 'a raiz precisa ser o caminho completo de uma pasta (por exemplo C:\Users)' }
    }
    try { $cheio = [IO.Path]::GetFullPath($Raiz) } catch { return @{ caminho = $null; erro = 'caminho inválido' } }
    if ($cheio -notmatch '^[A-Za-z]:\\' -or $cheio.Length -gt $Script:MaxCaminhoRaiz) { return @{ caminho = $null; erro = 'caminho inválido' } }
    if ($cheio.Length -gt 3) { $cheio = $cheio.TrimEnd('\') }
    if (Test-Path -LiteralPath $cheio -PathType Leaf) { return @{ caminho = $null; erro = 'a raiz é um arquivo, não uma pasta' } }
    if (-not (Test-Path -LiteralPath $cheio -PathType Container)) { return @{ caminho = $null; erro = 'a pasta não existe' } }
    if (-not (Test-CadeiaSemLink $cheio)) { return @{ caminho = $null; erro = 'a pasta é um link ou junção, ou fica dentro de um: recusada' } }
    return @{ caminho = $cheio; erro = $null }
}

function Get-FilhoPasta {
    # Entradas de uma pasta (arquivos e subpastas, ocultos inclusive), lidas de uma vez pelo .NET e sem seguir nada.
    # Lanca quando a pasta nao pode ser listada, o que separa "sem acesso" de "vazia" (array vazio).
    # $Negadas (so modo teste): pastas que respondem como acesso negado, sem mexer em ACL.
    param([string]$Pasta, [string[]]$Negadas)
    if ($null -ne $Negadas -and $Negadas.Count -gt 0) {
        $n = $Pasta.TrimEnd('\')
        foreach ($x in $Negadas) {
            if ([string]::Equals($n, $x, [StringComparison]::OrdinalIgnoreCase)) {
                throw (New-Object UnauthorizedAccessException ('acesso negado (simulado): ' + $Pasta))
            }
        }
    }
    $entradas = (New-Object IO.DirectoryInfo $Pasta).GetFileSystemInfos()
    return , $entradas
}

function Measure-PastaPrimeiroNivel {
    # Soma uma pasta do primeiro nivel com pilha (sem recursao), pulando todo ponto de reparse (junction, link,
    # ponto de montagem) sem somar. Os arquivos disputam a lista $Maiores. A propria pasta e sempre listada; o relogio
    # global e conferido antes de cada subpasta (e a cada $ConferirRelogioACada entradas).
    # Devolve @{ bytes; semAcesso; parcial; estourou }: semAcesso = a propria pasta nao pode ser listada (bytes -1).
    param([string]$Pasta, $Relogio, [int64]$TetoMs, $Maiores, [string[]]$Negadas)
    $r = @{ bytes = [int64]0; semAcesso = $false; parcial = $false; estourou = $false }
    $reparse = [IO.FileAttributes]::ReparsePoint
    $max = $Script:MaxItensEspaco
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($Pasta)
    $primeira = $true
    $n = 0
    while ($pilha.Count -gt 0) {
        if (-not $primeira -and $Relogio.ElapsedMilliseconds -ge $TetoMs) { $r.parcial = $true; $r.estourou = $true; break }
        $dir = $pilha.Pop()
        $filhos = $null
        try { $filhos = Get-FilhoPasta $dir $Negadas }
        catch {
            if ($primeira) { $r.bytes = [int64]-1; $r.semAcesso = $true; return $r }
            $r.parcial = $true
        }
        $primeira = $false
        if ($null -eq $filhos) { continue }
        foreach ($f in $filhos) {
            $n++
            if (($n % $Script:ConferirRelogioACada) -eq 0 -and $Relogio.ElapsedMilliseconds -ge $TetoMs) {
                $r.parcial = $true; $r.estourou = $true; return $r
            }
            # Test-Reparse em linha: uma chamada de funcao por arquivo pesa em arvores grandes.
            if (($f.Attributes -band $reparse) -ne 0) { continue }
            if ($f -is [IO.DirectoryInfo]) { $pilha.Push($f.FullName); continue }
            $tam = [int64]$f.Length
            $r.bytes += $tam
            if ($Maiores.Count -lt $max -or $tam -gt $Maiores[0].bytes) {
                Add-ItemLimitado $Maiores ([pscustomobject]@{ caminho = $f.FullName; nome = $f.Name; bytes = $tam }) $max
            }
        }
    }
    return $r
}

# ---------- acoes ----------

function Invoke-Analisar {
    param([string]$Id, $Params, [bool]$Teste)
    $raizParam = $null
    if ($null -ne $Params) { $raizParam = $Params.raiz }
    $v = Get-RaizAnalise $raizParam
    if ($null -ne $v.erro) { Send-Result $Id $null $false $v.erro; return }
    $t = Get-TetoParam $Params
    if ($null -ne $t.erro) { Send-Result $Id $null $false $t.erro; return }
    $tetoMs = [int64]$t.segundos * 1000
    $negadas = @()
    $sim = Get-Simulacao $Params $Teste
    if ($null -ne $sim) {
        if ($null -ne $sim.tetoMs) { $tetoMs = [int64]$sim.tetoMs }
        if ($null -ne $sim.negarAcesso) {
            $negadas = @(@($sim.negarAcesso) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    ForEach-Object { ([IO.Path]::GetFullPath([string]$_)).TrimEnd('\') })
        }
    }
    $raiz = $v.caminho
    $max = $Script:MaxItensEspaco
    $reparse = [IO.FileAttributes]::ReparsePoint
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    Send-Progress $Id 0 ('Analisando ' + $raiz)

    $entradas = $null
    try { $entradas = Get-FilhoPasta $raiz $negadas }
    catch { Send-Result $Id $null $false ('sem acesso à pasta ' + $raiz); return }

    # Arquivos soltos na raiz: entram no total e na lista de arquivos, nao em pastas.
    $total = [int64]0
    $maiores = New-Object System.Collections.Generic.List[object]
    $nivel = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entradas) {
        if ($e -is [IO.DirectoryInfo]) { $nivel.Add($e); continue }
        if (($e.Attributes -band $reparse) -ne 0) { continue }
        $tam = [int64]$e.Length
        $total += $tam
        if ($maiores.Count -lt $max -or $tam -gt $maiores[0].bytes) {
            Add-ItemLimitado $maiores ([pscustomobject]@{ caminho = $e.FullName; nome = $e.Name; bytes = $tam }) $max
        }
    }

    # Uma caminhada por pasta do primeiro nivel, em ordem de nome (deterministica), todas sob o mesmo relogio.
    $ordenadas = @($nivel | Sort-Object -Property Name)
    $qtd = $ordenadas.Count
    $pastas = New-Object System.Collections.Generic.List[object]
    $incompleto = $false
    $comecou = $false
    for ($i = 0; $i -lt $qtd; $i++) {
        $d = $ordenadas[$i]
        $p = [pscustomobject]@{ caminho = $d.FullName; nome = $d.Name; bytes = [int64]0; semAcesso = $false; parcial = $false }
        $pastas.Add($p)
        # Link no primeiro nivel: aparece com 0 e nao entra na soma (nem depois do teto: nao ha o que medir).
        if (($d.Attributes -band $reparse) -ne 0) { continue }
        if ($incompleto -or ($comecou -and $relogio.ElapsedMilliseconds -ge $tetoMs)) {
            $incompleto = $true
            $p.bytes = [int64]-1
            $p.parcial = $true
            continue
        }
        $comecou = $true
        Send-Progress $Id ([int][math]::Floor(100 * $i / $qtd)) ('Medindo ' + $d.Name)
        $m = Measure-PastaPrimeiroNivel $d.FullName $relogio $tetoMs $maiores $negadas
        $p.bytes = [int64]$m.bytes
        $p.semAcesso = [bool]$m.semAcesso
        $p.parcial = [bool]$m.parcial
        if ($m.estourou) { $incompleto = $true }
        if ($m.bytes -gt 0) { $total += [int64]$m.bytes }
    }

    $top = @($pastas | Sort-Object -Property @{ Expression = 'bytes'; Descending = $true }, @{ Expression = 'nome'; Descending = $false } |
            Select-Object -First $max)
    $arquivos = $maiores.ToArray()
    [Array]::Reverse($arquivos)
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{
            raiz       = $raiz
            totalBytes = [int64]$total
            incompleto = $incompleto
            pastas     = $top
            arquivos   = @($arquivos)
        })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if ($Acao -ne 'analisar') {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        Invoke-Analisar $Id $Params $Teste
    } catch {
        Send-Result $Id $null $false ('análise de espaço falhou: ' + $_.Exception.Message)
    }
}
