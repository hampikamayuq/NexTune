# atualizacoes.ps1 - Windows Update (COM Microsoft.Update.Session) e programas (winget upgrade).
# Acoes: listar {avancado?}, instalar {ids, confirmado, avancado?}, atualizarProgramas {ids, confirmado}.
# Regras (spec 8.7): criterio "IsInstalled=0 and IsHidden=0 and Type='Software'" (drivers ficam fora);
# Upgrades (atualizacao de versao do Windows) nunca instalam, so aparecem no avancado, travadas; Preview
# so aparece e so instala com avancado:true. winget sempre com --accept-source-agreements e
# --disable-interactivity; o id ja chegou validado pelo Rust e vai como argumento de lista.
# winget ausente ou erro COM nao derrubam listar: a outra metade vem e o erro fica no campo.
# Em modo teste: simular {windows [...], windowsErro?, wingetLinhas [string], wingetAusente?, falharIds?}
# substitui COM e winget; marcadores em %TEMP%\NexTuneTeste\atualizacoes\.
. "$PSScriptRoot\common.ps1"

$Script:CriterioWu = "IsInstalled=0 and IsHidden=0 and Type='Software'"
$Script:CategoriaUpgrades = '3689BDC8-B205-4AF4-8D4A-A63924C5E9D5'
# Ordem de prioridade: uma atualizacao em mais de uma categoria recebe a primeira que casar.
$Script:TiposPorCategoria = @(
    @{ id = '0FA1201D-4330-4FA8-8AE9-B877473B6441'; tipo = 'seguranca' },
    @{ id = 'E6CF1350-C01B-414D-A61F-263D14D133B4'; tipo = 'critica' },
    @{ id = 'E0789628-CE08-4437-BE74-2495B842F43B'; tipo = 'definicao' },
    @{ id = 'CD5FFD1E-E932-4E3A-BF74-18BF0B1BBD83'; tipo = 'qualidade' }
)
$Script:RePreview = 'Preview|Prévia|Visualização'
$Script:ArgsWinget = @('--accept-source-agreements', '--disable-interactivity')
$Script:ErroWingetAusente = 'winget não encontrado neste PC (instale o "Instalador de Aplicativo" pela Microsoft Store)'

# ---------- funcoes puras ----------

function Get-TipoAtualizacao {
    # Puro: 'seguranca' | 'critica' | 'definicao' | 'qualidade' | 'outro' pelas categorias [{ id; nome }].
    param($Categorias)
    $ids = @(@($Categorias) | ForEach-Object { ([string]$_.id).ToUpperInvariant() })
    foreach ($t in $Script:TiposPorCategoria) { if ($ids -contains $t.id) { return $t.tipo } }
    return 'outro'
}

function Test-Excluida {
    # Puro: 'upgrade' (categoria Upgrades), 'preview' (titulo) ou $null.
    param([string]$Titulo, $Categorias)
    foreach ($c in @($Categorias)) {
        if (([string]$c.id).ToUpperInvariant() -eq $Script:CategoriaUpgrades -or [string]$c.nome -eq 'Upgrades') { return 'upgrade' }
    }
    if ($Titulo -match $Script:RePreview) { return 'preview' }
    return $null
}

function Get-IniciosColunas {
    # Puro: posicoes onde o cabecalho tem palavra precedida de >= 2 espacos (ou coluna 0).
    param([string]$Cabecalho)
    $inicios = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Cabecalho.Length; $i++) {
        if ($Cabecalho[$i] -eq ' ') { continue }
        if ($i -eq 0 -or ($Cabecalho[$i - 1] -eq ' ' -and ($i -lt 2 -or $Cabecalho[$i - 2] -eq ' '))) { $inicios.Add($i) }
    }
    return $inicios.ToArray()
}

function ConvertFrom-TabelaWinget {
    # Puro: linhas de 'winget upgrade' -> @{ id; nome; versaoAtual; versaoNova; origem }. Colunas pelas
    # posicoes do cabecalho (ordem fixa Nome, Id, Versao, Disponivel, Origem; os titulos variam por idioma).
    # Para na primeira linha vazia, curta demais ou de rodape ("N ..."); a segunda tabela fica fora.
    param([string[]]$Linhas)
    $saida = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Linhas) { return $saida.ToArray() }
    # Spinner: apaga backspaces e fica com o que o terminal mostraria depois do ultimo retorno de carro.
    $limpas = @($Linhas | ForEach-Object { ((([string]$_) -replace "`b", '') -split "`r")[-1].TrimEnd() })
    $sep = -1
    for ($i = 1; $i -lt $limpas.Count; $i++) { if ($limpas[$i] -match '^-{10,}$') { $sep = $i; break } }
    if ($sep -lt 1) { return $saida.ToArray() }
    $inicios = @(Get-IniciosColunas $limpas[$sep - 1])
    if ($inicios.Count -lt 2) { return $saida.ToArray() }
    for ($j = $sep + 1; $j -lt $limpas.Count; $j++) {
        $l = $limpas[$j]
        if ($l.Length -le $inicios[1] -or $l -match '^\d+ ') { break }
        $campos = New-Object System.Collections.Generic.List[string]
        for ($k = 0; $k -lt $inicios.Count; $k++) {
            $ini = $inicios[$k]
            $fim = if ($k + 1 -lt $inicios.Count) { [math]::Min($inicios[$k + 1], $l.Length) } else { $l.Length }
            $campos.Add($(if ($ini -ge $l.Length) { '' } else { $l.Substring($ini, $fim - $ini).Trim() }))
        }
        while ($campos.Count -lt 5) { $campos.Add('') }
        if ([string]::IsNullOrEmpty($campos[1])) { continue }
        $saida.Add([ordered]@{ id = $campos[1]; nome = $campos[0]; versaoAtual = $campos[2]; versaoNova = $campos[3]; origem = $campos[4] })
    }
    return $saida.ToArray()
}

function New-ItemWu {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, [string]$Titulo, $Kb, [int64]$TamanhoBytes, $Categorias, [bool]$ExigeReinicio)
    $cats = @(@($Categorias) | ForEach-Object { [ordered]@{ id = [string]$_.id; nome = [string]$_.nome } })
    return [ordered]@{
        id            = $Id
        titulo        = $Titulo
        kb            = $(if ([string]::IsNullOrEmpty([string]$Kb)) { $null } else { [string]$Kb })
        tamanhoBytes  = $TamanhoBytes
        categorias    = @($cats | ForEach-Object { [string]$_.nome })
        tipo          = Get-TipoAtualizacao $cats
        exigeReinicio = $ExigeReinicio
        excluido      = Test-Excluida $Titulo $cats
    }
}

# ---------- Windows Update (COM) ----------

function Get-SessaoWu { return (New-Object -ComObject Microsoft.Update.Session) }

function Get-AtualizacoesWu {
    # Objetos COM IUpdate que casam o criterio (so fora do teste).
    param($Sessao)
    $busca = $Sessao.CreateUpdateSearcher().Search($Script:CriterioWu)
    $lista = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $busca.Updates.Count; $i++) { $lista.Add($busca.Updates.Item($i)) }
    return $lista.ToArray()
}

function ConvertFrom-UpdateCom {
    param($U)
    $cats = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $U.Categories.Count; $i++) { $c = $U.Categories.Item($i); $cats.Add(@{ id = [string]$c.CategoryID; nome = [string]$c.Name }) }
    $kb = $null
    if ($U.KBArticleIDs.Count -gt 0) { $kb = 'KB' + [string]$U.KBArticleIDs.Item(0) }
    $reinicio = $false
    try { $reinicio = ([int]$U.InstallationBehavior.RebootBehavior -ne 0) } catch { $reinicio = $false }
    return (New-ItemWu ([string]$U.Identity.UpdateID) ([string]$U.Title) $kb ([int64]$U.MaxDownloadSize) $cats.ToArray() $reinicio)
}

function ConvertFrom-UpdateSimulado {
    param($S)
    return (New-ItemWu ([string]$S.id) ([string]$S.titulo) $S.kb ([int64]$S.tamanhoBytes) @($S.categorias) ($S.exigeReinicio -eq $true))
}

function Get-ItensWindows {
    # @{ itens = [item]; erro = string|$null }. Erro COM vira texto, nunca excecao.
    param([bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -ne $Sim -and -not [string]::IsNullOrEmpty([string]$Sim.windowsErro)) { return @{ itens = @(); erro = [string]$Sim.windowsErro } }
        $lista = @()
        if ($null -ne $Sim -and $null -ne $Sim.windows) { $lista = @(@($Sim.windows) | ForEach-Object { ConvertFrom-UpdateSimulado $_ }) }
        return @{ itens = $lista; erro = $null }
    }
    try {
        $itens = @(@(Get-AtualizacoesWu (Get-SessaoWu)) | ForEach-Object { ConvertFrom-UpdateCom $_ })
        return @{ itens = $itens; erro = $null }
    } catch { return @{ itens = @(); erro = $_.Exception.Message } }
}

# ---------- winget ----------

function Test-WingetConfiavel {
    # O host roda elevado: so aceita winget.exe dentro de %ProgramFiles%\WindowsApps (pasta que o usuario
    # nao grava) e com assinatura Authenticode valida. Nunca pelo PATH nem por %LOCALAPPDATA%.
    param([string]$Caminho)
    if ([string]::IsNullOrEmpty($Caminho) -or -not (Test-Path -LiteralPath $Caminho -PathType Leaf)) { return $false }
    $raiz = (Join-Path $env:ProgramFiles 'WindowsApps').TrimEnd('\').ToLowerInvariant() + '\'
    if (-not ([IO.Path]::GetFullPath($Caminho)).ToLowerInvariant().StartsWith($raiz)) { return $false }
    try { return ((Get-AuthenticodeSignature -LiteralPath $Caminho -ErrorAction Stop).Status -eq 'Valid') } catch { return $false }
}

function Get-ComandoWinget {
    $candidatos = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($pk in @(Get-AppxPackage Microsoft.DesktopAppInstaller -ErrorAction Stop | Sort-Object Version -Descending)) {
            $candidatos.Add((Join-Path ([string]$pk.InstallLocation) 'winget.exe'))
        }
    } catch { $null = $_ }
    $raiz = Join-Path $env:ProgramFiles 'WindowsApps'
    foreach ($d in @(Get-ChildItem -LiteralPath $raiz -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $candidatos.Add((Join-Path $d.FullName 'winget.exe'))
    }
    foreach ($c in $candidatos) { if (Test-WingetConfiavel $c) { return $c } }
    return $null
}

function Get-ItensWinget {
    # @{ itens; disponivel; erro }. Em teste: wingetAusente / wingetLinhas da simulacao.
    param([bool]$Teste, $Sim)
    if ($Teste) {
        if ($null -ne $Sim -and $Sim.wingetAusente -eq $true) { return @{ itens = @(); disponivel = $false; erro = $Script:ErroWingetAusente } }
        $linhas = @()
        if ($null -ne $Sim -and $null -ne $Sim.wingetLinhas) { $linhas = @($Sim.wingetLinhas | ForEach-Object { [string]$_ }) }
        return @{ itens = @(ConvertFrom-TabelaWinget $linhas); disponivel = $true; erro = $null }
    }
    $cmd = Get-ComandoWinget
    if ($null -eq $cmd) { return @{ itens = @(); disponivel = $false; erro = $Script:ErroWingetAusente } }
    try {
        $saida = @(& $cmd upgrade --include-unknown @($Script:ArgsWinget) 2>$null | ForEach-Object { [string]$_ })
        return @{ itens = @(ConvertFrom-TabelaWinget $saida); disponivel = $true; erro = $null }
    } catch { return @{ itens = @(); disponivel = $true; erro = $_.Exception.Message } }
}

# ---------- marcadores de teste ----------

function Get-PastaAtuTeste {
    $p = Join-Path (Get-AppPastas $true).Base 'atualizacoes'
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    return $p
}

function Write-Marcador {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Nome, [string]$Texto)
    [IO.File]::WriteAllText((Join-Path (Get-PastaAtuTeste) $Nome), $Texto, (New-Object System.Text.UTF8Encoding $false))
}

# ---------- acoes ----------

function Invoke-Listar {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    Send-Progress $Id 10 'Consultando o Windows Update (pode levar um minuto)'
    $win = Get-ItensWindows $Teste $sim
    $windows = @($win.itens | Where-Object { $avancado -or $null -eq $_.excluido })
    Send-Progress $Id 60 'Consultando o winget'
    $wg = Get-ItensWinget $Teste $sim
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{
        windows     = $windows
        windowsErro = $win.erro
        programas   = @($wg.itens)
        winget      = [ordered]@{ disponivel = [bool]$wg.disponivel; erro = $wg.erro }
    })
}

function Get-MotivoRecusa {
    # Puro: por que um item nao pode ser instalado agora, ou $null.
    param($Item, [bool]$Avancado)
    if ($Item.excluido -eq 'upgrade') { return 'atualização de versão do Windows fica fora do NexTune: use Configurações › Windows Update' }
    if ($Item.excluido -eq 'preview' -and -not $Avancado) { return 'atualização Preview só no modo avançado' }
    return $null
}

function Invoke-InstalarCom {
    # Baixa e instala a colecao; devolve @{ resultados = @(@{ id; ok; erro }); reiniciar }.
    param([string]$Id, $Sessao, $Aceitos)
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($a in $Aceitos) {
        if (-not $a.com.EulaAccepted) { $a.com.AcceptEula() }
        $null = $coll.Add($a.com)
    }
    Send-Progress $Id 30 ("Baixando {0} atualizações" -f $coll.Count)
    $dl = $Sessao.CreateUpdateDownloader()
    $dl.Updates = $coll
    $null = $dl.Download()
    Send-Progress $Id 70 'Instalando'
    $inst = $Sessao.CreateUpdateInstaller()
    $inst.Updates = $coll
    $ri = $inst.Install()
    $resultados = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $r = $ri.GetUpdateResult($i)
        $ok = ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3)
        $erro = $null
        if (-not $ok) { $erro = ('código {0} (HResult 0x{1:X8})' -f [int]$r.ResultCode, [int64]$r.HResult) }
        $resultados.Add(@{ id = $Aceitos[$i].item.id; ok = $ok; erro = $erro })
    }
    return @{ resultados = $resultados.ToArray(); reiniciar = [bool]$ri.RebootRequired }
}

function Invoke-Instalar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $ids = Get-IdsParam $Params
    if ($ids.Count -eq 0) { Send-Result $Id $null $false 'nenhuma atualização informada'; return }
    $sim = Get-Simulacao $Params $Teste
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    Send-Progress $Id 10 'Procurando as atualizações'
    $sessao = $null
    $catalogo = New-Object System.Collections.Generic.List[object]   # @{ item; com }
    if ($Teste) {
        foreach ($s in @($sim.windows)) { $catalogo.Add(@{ item = (ConvertFrom-UpdateSimulado $s); com = $null }) }
    } else {
        $sessao = Get-SessaoWu
        foreach ($u in @(Get-AtualizacoesWu $sessao)) { $catalogo.Add(@{ item = (ConvertFrom-UpdateCom $u); com = $u }) }
    }
    $falharIds = @()
    if ($Teste -and $null -ne $sim -and $null -ne $sim.falharIds) { $falharIds = @($sim.falharIds | ForEach-Object { [string]$_ }) }
    $instalados = New-Object System.Collections.Generic.List[string]
    $falhas = New-Object System.Collections.Generic.List[object]
    $aceitos = New-Object System.Collections.Generic.List[object]
    foreach ($idAtu in $ids) {
        $e = @($catalogo | Where-Object { [string]::Equals($_.item.id, $idAtu, [StringComparison]::OrdinalIgnoreCase) })
        if ($e.Count -eq 0) { $falhas.Add([ordered]@{ id = $idAtu; erro = 'atualização não está mais disponível' }); continue }
        $motivo = Get-MotivoRecusa $e[0].item $avancado
        if ($null -ne $motivo) { $falhas.Add([ordered]@{ id = $idAtu; erro = $motivo }); continue }
        if ($falharIds -contains $idAtu) { $falhas.Add([ordered]@{ id = $idAtu; erro = 'falha simulada' }); continue }
        $aceitos.Add($e[0])
    }
    $reiniciar = $false
    if ($aceitos.Count -gt 0) {
        if ($Teste) {
            foreach ($a in $aceitos) {
                Write-Marcador ('instalar-' + $a.item.id + '.txt') $a.item.titulo
                $instalados.Add($a.item.id)
                if ($a.item.exigeReinicio) { $reiniciar = $true }
            }
        } else {
            try {
                $r = Invoke-InstalarCom $Id $sessao $aceitos.ToArray()
                foreach ($x in $r.resultados) { if ($x.ok) { $instalados.Add($x.id) } else { $falhas.Add([ordered]@{ id = $x.id; erro = $x.erro }) } }
                $reiniciar = $r.reiniciar
            } catch {
                foreach ($a in $aceitos) { $falhas.Add([ordered]@{ id = $a.item.id; erro = $_.Exception.Message }) }
            }
        }
    }
    foreach ($f in $falhas) { Send-Log $Id 'aviso' ("Falha em {0}: {1}" -f $f.id, $f.erro) }
    Write-AppLog ("atualizacoes: instalar instalados={0} falhas={1} reiniciar={2}" -f $instalados.Count, $falhas.Count, $reiniciar) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ instalados = $instalados.ToArray(); falhas = $falhas.ToArray(); precisaReiniciar = $reiniciar })
}

function Invoke-AtualizarProgramas {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'ação exige confirmação'; return }
    $ids = Get-IdsParam $Params
    if ($ids.Count -eq 0) { Send-Result $Id $null $false 'nenhum programa informado'; return }
    $sim = Get-Simulacao $Params $Teste
    $cmd = $null
    if ($Teste) { if ($null -ne $sim -and $sim.wingetAusente -eq $true) { Send-Result $Id $null $false $Script:ErroWingetAusente; return } }
    else { $cmd = Get-ComandoWinget; if ($null -eq $cmd) { Send-Result $Id $null $false $Script:ErroWingetAusente; return } }
    $atualizados = New-Object System.Collections.Generic.List[string]
    $falhas = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($idProg in $ids) {
        Send-Progress $Id ([int](100 * $i / $ids.Count)) "Atualizando $idProg"
        $i++
        try {
            if ($Teste) { Write-Marcador ('winget-' + $idProg + '.txt') 'upgrade' }
            else {
                & $cmd upgrade --id $idProg --exact --silent --accept-package-agreements @($Script:ArgsWinget) | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "winget terminou com código $LASTEXITCODE" }
            }
            $atualizados.Add($idProg)
            Write-AppLog ("atualizacoes: winget upgrade {0} ok" -f $idProg) $Teste
        } catch {
            $falhas.Add([ordered]@{ id = $idProg; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ("Falha em ${idProg}: " + $_.Exception.Message)
            Write-AppLog ("atualizacoes: winget upgrade {0} falhou: {1}" -f $idProg, $_.Exception.Message) $Teste
        }
    }
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ atualizados = $atualizados.ToArray(); falhas = $falhas.ToArray() })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'instalar', 'atualizarProgramas') -notcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-Listar $Id $Params $Teste }
            'instalar' { Invoke-Instalar $Id $Params $Teste }
            'atualizarProgramas' { Invoke-AtualizarProgramas $Id $Params $Teste }
        }
    } catch {
        $msg = 'atualizações falharam: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
