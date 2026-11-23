# espaco.ps1 - analisador de espaco (so leitura): onde esta o espaco ocupado dentro de uma pasta.
# Acao: analisar {raiz, tetoSegundos?} -> {raiz, totalBytes, incompleto,
#        pastas: [{caminho, nome, bytes, semAcesso, parcial, link}], arquivos: [{caminho, nome, bytes}]}.
# pastas = as 20 maiores do primeiro nivel e arquivos = os 20 maiores da arvore percorrida, do maior para o menor;
# bytes -1 = nao deu para medir. Os arquivos soltos na raiz entram em totalBytes e em arquivos, nao em pastas.
# "Um nivel abaixo" = nova chamada com raiz = a pasta clicada.
# Review Focus 5: junction/link (pasta ou arquivo) nunca e seguido nem somado, em nivel nenhum; um link no primeiro
# nivel aparece com link:true e bytes 0. Pasta do primeiro nivel que nao pode ser listada: bytes -1 (nunca 0), com
# semAcesso so quando e acesso negado (sumiu, caminho longo demais ou outro erro de E/S -> parcial). Subpasta ilegivel
# ou teto estourado no meio marca parcial (bytes = o que foi somado ate ali). Um unico relogio limita a analise
# inteira (tetoSegundos 5..300, padrao 60), conferido tambem na listagem da propria raiz: estourou -> incompleto, e as
# pastas nao alcancadas vem com bytes -1 e parcial. A listagem e em fluxo (EnumerateFileSystemInfos): erro no meio de
# uma pasta guarda o que ja foi lido e marca parcial.
# Nao grava nada (nem log): apagar continua sendo pela Limpeza ou pela quarentena.
# Em modo teste: simular {negarAcesso?: [caminho], sumir?: [caminho], tetoMs?, conferirACada?}. negarAcesso faz a
# listagem dessas pastas falhar como acesso negado (sem mexer em ACL) e sumir como pasta que nao existe mais; tetoMs
# troca o teto, em milissegundos (0 = so a primeira pasta comeca); conferirACada troca de quantas em quantas entradas
# o relogio e conferido dentro de uma pasta. As pastas de teste ficam em %TEMP%\NexTuneTeste\espaco.
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
    $d = 0.0
    try { $d = [double]$v } catch { return @{ segundos = 0; erro = 'tetoSegundos inválido' } }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -ne [math]::Floor($d)) {
        return @{ segundos = 0; erro = 'tetoSegundos precisa ser um número inteiro' }
    }
    if ($d -lt $Script:TetoMinSegundos -or $d -gt $Script:TetoMaxSegundos) {
        return @{ segundos = 0; erro = ('tetoSegundos fora do intervalo {0}..{1}' -f $Script:TetoMinSegundos, $Script:TetoMaxSegundos) }
    }
    return @{ segundos = [int]$d; erro = $null }
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

function Test-AcessoNegado {
    # Puro: a excecao, ou alguma interna dela (MethodInvocationException e erros da enumeracao vem embrulhados), e
    # falta de permissao? Pasta que sumiu, caminho longo demais e outros erros de E/S nao sao.
    param($Excecao)
    $e = $Excecao
    while ($null -ne $e) {
        if ($e -is [UnauthorizedAccessException] -or $e -is [Security.SecurityException]) { return $true }
        $e = $e.InnerException
    }
    return $false
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

function Assert-PastaSimulada {
    # So modo teste: pasta marcada em simular falha como a listagem real falharia (acesso negado ou pasta que sumiu),
    # sem mexer em ACL. $Falhas: caminho sem barra no fim -> 'negar' | 'sumir' (hashtable, sem diferenciar caixa).
    param([string]$Pasta, $Falhas)
    $tipo = $Falhas[$Pasta.TrimEnd('\')]
    if ($tipo -eq 'negar') { throw (New-Object UnauthorizedAccessException ('acesso negado (simulado): ' + $Pasta)) }
    if ($tipo -eq 'sumir') { throw (New-Object IO.DirectoryNotFoundException ('a pasta sumiu (simulado): ' + $Pasta)) }
}

function Measure-PastaPrimeiroNivel {
    # Soma uma pasta do primeiro nivel com pilha (sem recursao), pulando todo ponto de reparse (junction, link,
    # ponto de montagem) sem somar. Cada pasta e lida em fluxo (EnumerateFileSystemInfos dentro do foreach, que nao
    # junta tudo na memoria). Os arquivos disputam a lista $Maiores. A propria pasta e sempre listada; o relogio global
    # e conferido antes de cada subpasta e a cada $ConferirACada entradas.
    # Erro antes da primeira entrada da propria pasta: bytes -1, com semAcesso (acesso negado) ou parcial (outro erro).
    # Erro depois disso, ou numa subpasta: guarda o que ja foi lido e marca parcial.
    # Devolve @{ bytes; semAcesso; parcial; estourou }.
    param([string]$Pasta, $Relogio, [int64]$TetoMs, $Maiores, $Falhas, [int]$ConferirACada)
    $r = @{ bytes = [int64]0; semAcesso = $false; parcial = $false; estourou = $false }
    $reparse = [IO.FileAttributes]::ReparsePoint
    $max = $Script:MaxItensEspaco
    $simulando = ($null -ne $Falhas -and $Falhas.Count -gt 0)
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($Pasta)
    $primeira = $true
    $n = 0
    while ($pilha.Count -gt 0) {
        if (-not $primeira -and $Relogio.ElapsedMilliseconds -ge $TetoMs) { $r.parcial = $true; $r.estourou = $true; break }
        $dir = $pilha.Pop()
        $propria = $primeira
        $primeira = $false
        $lidas = 0
        try {
            if ($simulando) { Assert-PastaSimulada $dir $Falhas }
            foreach ($f in [IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos()) {
                $lidas++
                $n++
                if (($n % $ConferirACada) -eq 0 -and $Relogio.ElapsedMilliseconds -ge $TetoMs) {
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
        } catch {
            if ($propria -and $lidas -eq 0) {
                $r.bytes = [int64]-1
                if (Test-AcessoNegado $_.Exception) { $r.semAcesso = $true } else { $r.parcial = $true }
                return $r
            }
            $r.parcial = $true
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
    $conferir = $Script:ConferirRelogioACada
    $falhas = @{}
    $sim = Get-Simulacao $Params $Teste
    if ($null -ne $sim) {
        if ($null -ne $sim.tetoMs) { $tetoMs = [int64]$sim.tetoMs }
        if ($null -ne $sim.conferirACada) { $conferir = [math]::Max(1, [int]$sim.conferirACada) }
        foreach ($c in @($sim.negarAcesso)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $falhas[([IO.Path]::GetFullPath([string]$c)).TrimEnd('\')] = 'negar' }
        }
        foreach ($c in @($sim.sumir)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$c)) { $falhas[([IO.Path]::GetFullPath([string]$c)).TrimEnd('\')] = 'sumir' }
        }
    }
    $raiz = $v.caminho
    $max = $Script:MaxItensEspaco
    $reparse = [IO.FileAttributes]::ReparsePoint
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    Send-Progress $Id 0 ('Analisando ' + $raiz)

    # Listagem da propria raiz, em fluxo e sob o mesmo relogio. Arquivos soltos entram no total e na lista de
    # arquivos, nao em pastas. Teto ou erro no meio: o que ja foi lido fica e a analise sai incompleta.
    $total = [int64]0
    $maiores = New-Object System.Collections.Generic.List[object]
    $nivel = New-Object System.Collections.Generic.List[object]
    $incompleto = $false
    $lidas = 0
    try {
        if ($falhas.Count -gt 0) { Assert-PastaSimulada $raiz $falhas }
        foreach ($e in [IO.DirectoryInfo]::new($raiz).EnumerateFileSystemInfos()) {
            $lidas++
            if ($e -is [IO.DirectoryInfo]) {
                $nivel.Add($e)
            } elseif (($e.Attributes -band $reparse) -eq 0) {
                $tam = [int64]$e.Length
                $total += $tam
                if ($maiores.Count -lt $max -or $tam -gt $maiores[0].bytes) {
                    Add-ItemLimitado $maiores ([pscustomobject]@{ caminho = $e.FullName; nome = $e.Name; bytes = $tam }) $max
                }
            }
            if (($lidas % $conferir) -eq 0 -and $relogio.ElapsedMilliseconds -ge $tetoMs) { $incompleto = $true; break }
        }
    } catch {
        if ($lidas -eq 0) {
            $msg = if (Test-AcessoNegado $_.Exception) { 'sem acesso à pasta ' + $raiz } else { 'não foi possível ler a pasta ' + $raiz }
            Send-Result $Id $null $false $msg
            return
        }
        $incompleto = $true
    }

    # Uma caminhada por pasta do primeiro nivel, em ordem de nome (deterministica), todas sob o mesmo relogio.
    $ordenadas = @($nivel | Sort-Object -Property Name)
    $qtd = $ordenadas.Count
    $pastas = New-Object System.Collections.Generic.List[object]
    $comecou = $false
    for ($i = 0; $i -lt $qtd; $i++) {
        $d = $ordenadas[$i]
        $p = [pscustomobject]@{ caminho = $d.FullName; nome = $d.Name; bytes = [int64]0; semAcesso = $false; parcial = $false; link = $false }
        $pastas.Add($p)
        # Link no primeiro nivel: aparece com link:true e 0, nunca e percorrido (nem depois do teto: nao ha o que medir).
        if (($d.Attributes -band $reparse) -ne 0) { $p.link = $true; continue }
        if ($incompleto -or ($comecou -and $relogio.ElapsedMilliseconds -ge $tetoMs)) {
            $incompleto = $true
            $p.bytes = [int64]-1
            $p.parcial = $true
            continue
        }
        $comecou = $true
        Send-Progress $Id ([int][math]::Floor(100 * $i / $qtd)) ('Medindo ' + $d.Name)
        $m = Measure-PastaPrimeiroNivel $d.FullName $relogio $tetoMs $maiores $falhas $conferir
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
