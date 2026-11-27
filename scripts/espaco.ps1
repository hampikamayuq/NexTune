# espaco.ps1 - analisador de espaco (so leitura: nada aqui apaga, move ou muda permissao).
# Acao: analisar {raiz, simular?} -> {raiz, totalBytes, soltosBytes, parcial,
#        pastas: [{caminho, bytes, semAcesso, parcial}] (as 20 maiores do primeiro nivel),
#        arquivos: [{caminho, bytes}] (os 20 maiores de toda a arvore medida)}.
# Review Focus 5: junction, link simbolico e ponto de montagem nunca sao seguidos nem somados (nem listados);
# pasta que nao da para abrir vem com semAcesso e bytes nulo (nunca "0 B"); cada pasta tem teto de tempo e a analise
# inteira tambem: estourou, a pasta vem com o que deu para somar e parcial = $true, e a acao nunca trava.
# Subpasta interna sem permissao tambem marca parcial (o total e um minimo).
# Nao reaproveita o Get-TamanhoComTeto de programas.ps1: ele devolve -1 tanto para "sem acesso" quanto para "estourou o
# teto" e nao junta os maiores arquivos; aqui um so percurso (DirectoryInfo, bem mais rapido que Get-ChildItem) faz os
# tres. Em modo teste, simular {tetoPastaMs?, tetoTotalMs?} encurta os tetos; a pasta analisada e de verdade.
. "$PSScriptRoot\common.ps1"

$Script:MaxItens = 20
$Script:TetoPastaMs = 20000
$Script:TetoTotalMs = 180000

# ---------- funcoes puras ----------

function Test-RaizValida {
    # Puro: caminho absoluto de unidade local (X:\...), sem curingas, aspas nem segmentos . e ..
    param([string]$Raiz)
    if ([string]::IsNullOrWhiteSpace($Raiz) -or $Raiz.Length -gt 1024) { return $false }
    if ($Raiz -notmatch '^[A-Za-z]:\\') { return $false }
    if ($Raiz.Substring(2).IndexOfAny([char[]]'*?"<>|:/') -ge 0) { return $false }
    foreach ($seg in $Raiz.Substring(3).Split('\')) { if ($seg -eq '.' -or $seg -eq '..') { return $false } }
    return $true
}

function Add-MaiorArquivo {
    # Mantem em $Lista os maiores arquivos (corta de vez em quando para nao ordenar a cada arquivo).
    param([System.Collections.Generic.List[object]]$Lista, [string]$Caminho, [int64]$Bytes, [int]$Max)
    $Lista.Add([pscustomobject]@{ caminho = $Caminho; bytes = $Bytes })
    if ($Lista.Count -ge ($Max * 4)) {
        $manter = @($Lista | Sort-Object -Property bytes -Descending | Select-Object -First $Max)
        $Lista.Clear()
        foreach ($m in $manter) { $Lista.Add($m) }
    }
}

function Select-Maior {
    # Puro: os $Max maiores por bytes; semAcesso (bytes nulo) vai para o fim.
    param($Itens, [int]$Max)
    $com = @($Itens | Where-Object { $null -ne $_.bytes } | Sort-Object -Property bytes -Descending)
    $sem = @($Itens | Where-Object { $null -eq $_.bytes } | Sort-Object -Property caminho)
    return @(($com + $sem) | Select-Object -First $Max)
}

# ---------- percurso ----------

function Test-ItemLink {
    param([IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-FilhosDir {
    # Filhos de uma pasta, ou $null se ela nao puder ser lida (sem permissao, sumiu no meio). A virgula impede que a
    # pasta vazia (@()) chegue como $null e pareca "sem acesso".
    param([string]$Caminho)
    try {
        return , @((New-Object IO.DirectoryInfo $Caminho).EnumerateFileSystemInfos())
    } catch { return $null }
}

function Measure-Pasta {
    # Soma uma pasta sem seguir links, ate o prazo (Stopwatch $Relogio + ms). Devolve {bytes, semAcesso, parcial}.
    param([string]$Caminho, [Diagnostics.Stopwatch]$Relogio, [int64]$PrazoMs, [System.Collections.Generic.List[object]]$Maiores)
    $filhos = Get-FilhosDir $Caminho
    if ($null -eq $filhos) { return [pscustomobject]@{ bytes = $null; semAcesso = $true; parcial = $false } }
    $total = [int64]0
    $parcial = $false
    $pilha = New-Object System.Collections.Generic.Stack[object]
    $pilha.Push($filhos)
    while ($pilha.Count -gt 0) {
        if ($Relogio.ElapsedMilliseconds -gt $PrazoMs) { $parcial = $true; break }
        foreach ($f in $pilha.Pop()) {
            if (Test-ItemLink $f) { continue }
            if ($f -is [IO.DirectoryInfo]) {
                $sub = Get-FilhosDir $f.FullName
                if ($null -eq $sub) { $parcial = $true } else { $pilha.Push($sub) }
            } else {
                $total += $f.Length
                Add-MaiorArquivo $Maiores $f.FullName $f.Length $Script:MaxItens
            }
        }
    }
    return [pscustomobject]@{ bytes = $total; semAcesso = $false; parcial = $parcial }
}

# ---------- acoes ----------

function Invoke-Analisar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $tetoPasta = $Script:TetoPastaMs
    $tetoTotal = $Script:TetoTotalMs
    if ($null -ne $sim) {
        if ($null -ne $sim.tetoPastaMs) { $tetoPasta = [int]$sim.tetoPastaMs }
        if ($null -ne $sim.tetoTotalMs) { $tetoTotal = [int]$sim.tetoTotalMs }
    }
    $bruto = if ($null -ne $Params) { [string]$Params.raiz } else { '' }
    if (-not (Test-RaizValida $bruto)) { Send-Result $Id $null $false 'pasta inválida'; return }
    $raiz = [IO.Path]::GetFullPath($bruto)
    if ($raiz.Length -gt 3) { $raiz = $raiz.TrimEnd('\') }
    if (-not (Test-Path -LiteralPath $raiz -PathType Container)) { Send-Result $Id $null $false 'a pasta não existe'; return }
    if (-not (Test-CadeiaSemLink $raiz)) { Send-Result $Id $null $false 'a pasta é um atalho (junction ou link) para outro lugar'; return }

    Send-Progress $Id 0 'Lendo a pasta'
    $filhos = Get-FilhosDir $raiz
    if ($null -eq $filhos) { Send-Result $Id $null $false 'sem permissão para abrir a pasta'; return }

    $relogio = [Diagnostics.Stopwatch]::StartNew()
    $maiores = New-Object System.Collections.Generic.List[object]
    $soltos = [int64]0
    $dirs = New-Object System.Collections.Generic.List[object]
    foreach ($f in $filhos) {
        if (Test-ItemLink $f) { continue }
        if ($f -is [IO.DirectoryInfo]) { $dirs.Add($f) }
        else {
            $soltos += $f.Length
            Add-MaiorArquivo $maiores $f.FullName $f.Length $Script:MaxItens
        }
    }

    $pastas = New-Object System.Collections.Generic.List[object]
    $parcialGeral = $false
    $i = 0
    foreach ($d in $dirs) {
        $i++
        Send-Progress $Id ([int][math]::Floor(99 * ($i - 1) / [math]::Max(1, $dirs.Count))) ('Medindo ' + $d.Name)
        $resta = $tetoTotal - $relogio.ElapsedMilliseconds
        if ($resta -le 0) {
            # Sem tempo para medir: aparece, marcada como parcial, com o que der para ver (nada).
            $pastas.Add([pscustomobject]@{ caminho = $d.FullName; bytes = [int64]0; semAcesso = $false; parcial = $true })
            $parcialGeral = $true
            continue
        }
        $prazo = $relogio.ElapsedMilliseconds + [math]::Min($tetoPasta, $resta)
        $m = Measure-Pasta $d.FullName $relogio $prazo $maiores
        if ($m.parcial -or $m.semAcesso) { $parcialGeral = $true }
        $pastas.Add([pscustomobject]@{ caminho = $d.FullName; bytes = $m.bytes; semAcesso = $m.semAcesso; parcial = $m.parcial })
    }

    $total = $soltos
    foreach ($p in $pastas) { if ($null -ne $p.bytes) { $total += [int64]$p.bytes } }
    $saidaPastas = @(Select-Maior $pastas $Script:MaxItens | ForEach-Object {
            [ordered]@{ caminho = $_.caminho; bytes = $_.bytes; semAcesso = [bool]$_.semAcesso; parcial = [bool]$_.parcial }
        })
    $saidaArquivos = @($maiores | Sort-Object -Property bytes -Descending | Select-Object -First $Script:MaxItens | ForEach-Object {
            [ordered]@{ caminho = $_.caminho; bytes = [int64]$_.bytes }
        })
    Write-AppLog ('espaco: analisar ' + $raiz + ' -> ' + $total + ' bytes em ' + $relogio.ElapsedMilliseconds + ' ms' + $(if ($parcialGeral) { ' (parcial)' } else { '' })) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{
            raiz = $raiz; totalBytes = $total; soltosBytes = $soltos; parcial = $parcialGeral
            pastas = $saidaPastas; arquivos = $saidaArquivos
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
        $msg = 'analisador de espaço falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
