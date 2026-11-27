# programas.ps1 - programas instalados (classicos e Store): listar, desinstalar em silencio, restos para a quarentena.
# Acoes: listar {}, desinstalar {id, confirmado, avancado?, desprovisionar?}, restos {id, nome, editor?, local?},
# limparRestos {itens:[{tipo, caminho}], confirmado, nome?}, restosAntigos {} (so leitura; limpar usa limparRestos).
# restosAntigos: baseado em residuos.ps1 do RetroLimpia (MIT, Retropunk94)
# Dados: data\bloatware.json e data\protegidos.json na pasta 'data' ao lado de 'scripts' (repositorio e bundle).
# Classificacao, nesta ordem: protegidos.json (nome/editor/packageFamilyName) -> InstallLocation sob
# Test-ProtectedPath (so classicos; a Store mora em WindowsApps) -> Store com SignatureKind 'System' ou
# NonRemovable -> bloatware.json (primeira entrada
# que casa vence; 'editor' da entrada so e exigido quando o programa informa editor). Fora das listas: cor $null.
# Store em bloatware.json casa por igualdade (sem diferenciar caixa) do PackageFamilyName.
# Tamanho: EstimatedSize (KB) quando houver; senao Get-TamanhoComTeto do InstallLocation (10 s por programa,
# -1 se estourar, se a raiz nao puder ser lida ou se nao houver pasta). Servicos e RAM so fora do modo teste.
# Ids: cl:<hive>:<nomeDaChave> (hklm64|hklm32|hkcu) e st:<PackageFullName>. O id NUNCA vira caminho: e
# resolvido contra a lista que este script gera (Get-ProgramaPorId).
# Desinstalar: nunca monta uma unica string de comando. Executavel e argumentos separados (Split-UninstallString),
# Start-Process com lista de argumentos, limite de 10 min (arvore morta e codigo $null se estourar).
# Modo teste: Uninstall falso em HKCU\Software\NexTuneTeste\Uninstall\<hive>\<chave>; Get-AppxPackage NUNCA e chamado
# (Store vem de simular.store); so executa desinstaladores sob %TEMP%\NexTuneTeste; simular.tipoInstalador forca
# o tipo detectado; raizes de restos em %TEMP%\NexTuneTeste\restos\{LocalAppData,AppData,ProgramData,Desktop,Menu}
# e chaves sob HKCU\Software\NexTuneTeste\Restos\{HKCU,HKLM}; raizes de restosAntigos em
# %TEMP%\NexTuneTeste\restosAntigos\{ProgramFiles,ProgramFilesX86,ProgramData,AppData,LocalAppData,Menu}.
# restosAntigos: pastas do primeiro nivel de Program Files (64 e 32), ProgramData, AppData e LocalAppData (e o segundo
# nivel dentro da pasta de um editor com programa instalado, nunca o terceiro) sem programa instalado correspondente,
# e atalhos .lnk quebrados dos dois Menus Iniciar. So raizes locais em disco fixo (redirecionadas para a rede: nao).
# Nunca aparece: caminho protegido, link/juncao (na pasta, acima ou dentro), programa ou script
# ($Script:ExtensoesProgramaResto) alterado ou criado ha menos de 30 dias, nome de protegidos.json ou de
# $Script:PastasNuncaResto,
# pasta de programa instalado (mesmo nome limpo ou cru, local de instalacao, pasta do desinstalador, do icone, do
# executavel de servico ou do destino de atalho valido). A pasta de um editor instalado so serve para descer.
# A regra de 'seguro' e do NexTune (o RetroLimpia so pontua candidatos de um programa): so em Program Files e
# ProgramData, so quando o nome nao casa com nenhum instalado (igual ou contido, nos dois sentidos, nome ou editor),
# nem com exe/subpasta do InstallLocation, icone, servico ou destino de atalho (por igualdade), nem com
# protegidos.json, e a pasta nao tem programas, jogos salvos, chaves ou licencas nem foi alterada em 30 dias. Se a
# Store ou os servicos nao puderem ser lidos, nada e 'seguro'. Teto: 10 s por pasta (estourou: fica de fora) e
# 120 s no total (resultado com incompleto:true).
. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\quarentena.ps1"

$Script:Tabelas = $null
$Script:ErroStore = $null
$Script:Hives = @('hklm64', 'hklm32', 'hkcu')
$Script:TiposSilenciosos = @('msi', 'inno', 'nsis', 'installshield')
$Script:TiposInstalador = @('msi', 'inno', 'nsis', 'installshield', 'quiet', 'loja', 'desconhecido')
$Script:TiposResto = @('pasta', 'arquivo', 'atalho', 'chave')
$Script:ExtensoesExecutaveis = @('.exe', '.dll', '.sys')
$Script:DiasResto = 30
$Script:TetoTamanhoMs = 10000
$Script:TetoDesinstalarMs = 600000
$Script:MaxItensRestos = 500
$Script:PadraoGuid = '\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}'
$Script:PadraoAtualizacao = '^(Security Update|Update|Hotfix) for|KB\d{6,}'
# Segmentos de chave de registro (abaixo de HKCU\Software ou HKLM\SOFTWARE) que nunca viram candidato a resto.
$Script:SegmentosProibidos = @('microsoft', 'classes', 'policies', 'wow6432node', 'clients', 'registeredapplications', 'odbc', 'windows', 'windows nt')
# restosAntigos: nomes de pasta que nunca sao oferecidos, mesmo sem programa instalado correspondente: Windows,
# Microsoft, runtimes e drivers comuns, caches de instalador e pastas do sistema dentro de ProgramData/AppData.
# Comparacao com -like, sem diferenciar caixa ('*' = qualquer sequencia). Programas que continuam instalados
# (ex.: Mozilla Firefox) ja ficam de fora pela comparacao com a lista de instalados, sem precisar estar aqui.
$Script:PastasNuncaResto = @(
    'Microsoft*', 'Windows*', 'Common Files', 'WindowsApps', 'ModifiableWindowsApps', 'Internet Explorer',
    'Reference Assemblies', 'MSBuild', 'dotnet', 'PowerShell', 'IIS', 'IIS Express', 'Hyper-V', 'rempl',
    'Package Cache', 'Packages', 'regid.*', 'Uninstall Information', 'InstallShield Installation Information',
    'Intel', 'Intel *', 'Intel(R)*', 'NVIDIA*', 'AMD', 'AMD *', 'ATI', 'ATI Technologies', 'Realtek', 'Realtek *',
    'Temp', 'Tmp', 'Programs', '*nextune*', 'Apps', 'Deployment',
    'FLEXnet', 'Flexera*', 'Macrovision*', 'CodeMeter', 'SafeNet*', 'Sentinel*', 'gnupg', 'gcloud',
    'Application Data', 'Desktop', 'Documents', 'Favorites', 'History', 'Start Menu', 'Templates', 'Temporary Internet Files',
    'Comms', 'ConnectedDevicesPlatform', 'CrashDumps', 'D3DSCache', 'Diagnosis', 'dbg', 'IsolatedStorage', 'PeerDistRepub',
    'PlaceholderTileLogoFolder', 'Publishers', 'SoftwareDistribution', 'ssh', 'USOPrivate', 'USOShared', 'VirtualStore',
    'chocolatey', 'npm', '.*', '$*'
)
$Script:MinCompararNome = 3   # nome compacto menor que isto so casa por igualdade (e a pasta nunca e 'segura')
# restosAntigos: extensoes de programa ou script (pasta com uma delas nunca e 'segura'; recente, nem aparece),
# subpastas e arquivos de dados que nao voltam (jogos salvos, chaves, licencas), teto total e cache de unidades.
$Script:ExtensoesProgramaResto = @('.exe', '.dll', '.sys', '.jar', '.msi', '.bat', '.cmd', '.ps1', '.vbs', '.node', '.pyd', '.ocx', '.cpl', '.com', '.scr', '.drv')
$Script:PastasDadoUsuario = @('Saved', 'SaveGames', 'Saves', 'savegame')
$Script:ArquivosDadoUsuario = @('*.sav', '*.kbx', '*.gpg', '*.key', '*.pem', '*.lic', '*.ulf', '*tsf.data')
$Script:TetoTotalRestoMs = 120000
$Script:TiposUnidade = @{}

# ---------- dados ----------

function Get-TabelaClassificacao {
    # Carrega bloatware.json e protegidos.json uma vez por runspace. Devolve @{ protegidos; store; classicos }.
    if ($null -ne $Script:Tabelas) { return $Script:Tabelas }
    $bl = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'bloatware.json')
    $pr = Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'protegidos.json')
    $protegidos = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($pr.programas)) {
        $rx = New-RegexLista $e.padrao
        if ($null -eq $rx) { continue }
        $protegidos.Add(@{ regex = $rx; motivo = [string]$e.motivo })
    }
    $store = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($bl.store)) {
        $pfn = [string]$e.packageFamilyName
        if ([string]::IsNullOrWhiteSpace($pfn)) { continue }
        $store.Add(@{ pfn = $pfn.Trim(); cor = [string]$e.cor; motivo = [string]$e.motivo; site = [string]$e.siteReinstalar; productId = [string]$e.productId })
    }
    $classicos = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($bl.classicos)) {
        $rx = New-RegexLista $e.padrao
        if ($null -eq $rx) { continue }
        $rxEditor = New-RegexLista $e.editor
        $classicos.Add(@{ regex = $rx; regexEditor = $rxEditor; cor = [string]$e.cor; motivo = [string]$e.motivo; site = [string]$e.siteReinstalar })
    }
    $Script:Tabelas = @{ protegidos = $protegidos.ToArray(); store = $store.ToArray(); classicos = $classicos.ToArray() }
    return $Script:Tabelas
}

function Get-MotivoProtegido {
    # Motivo da primeira entrada de protegidos.json que casa com nome, editor ou packageFamilyName; $null se nenhuma.
    param([string]$Nome, [string]$Editor, [string]$PackageFamilyName)
    $t = Get-TabelaClassificacao
    foreach ($e in $t.protegidos) {
        foreach ($texto in @($Nome, $Editor, $PackageFamilyName)) {
            if ([string]::IsNullOrEmpty($texto)) { continue }
            if ($e.regex.IsMatch($texto)) { return $e.motivo }
        }
    }
    return $null
}

function Get-Classificacao {
    # Puro (le so as tabelas): cor, motivos, protegido, siteReinstalar e productId de um programa.
    param([string]$Nome, [string]$Editor, [string]$PackageFamilyName, [string]$Local, [string]$Tipo,
        [string]$SignatureKind = '', [bool]$NonRemovable = $false)
    $r = @{ cor = $null; motivoCor = ''; protegido = $false; motivoProtegido = ''; siteReinstalar = $null; productId = $null }
    $motivo = Get-MotivoProtegido $Nome $Editor $PackageFamilyName
    # Apps da Store moram em Program Files\WindowsApps (sempre protegida): para elas valem so protegidos.json,
    # SignatureKind e NonRemovable; a regra da pasta e so para programas classicos.
    if ($null -eq $motivo -and $Tipo -ne 'store' -and -not [string]::IsNullOrWhiteSpace($Local) -and (Test-ProtectedPath $Local)) {
        $motivo = 'Instalado numa pasta protegida do Windows: faz parte do sistema ou de componentes compartilhados.'
    }
    if ($null -eq $motivo -and $Tipo -eq 'store' -and ($SignatureKind -eq 'System' -or $NonRemovable)) {
        $motivo = 'Pacote de sistema do Windows: não pode ser removido.'
    }
    if ($null -ne $motivo) {
        $r.cor = 'vermelho'
        $r.motivoCor = $motivo
        $r.protegido = $true
        $r.motivoProtegido = $motivo
        return $r
    }
    $t = Get-TabelaClassificacao
    if ($Tipo -eq 'store') {
        if (-not [string]::IsNullOrEmpty($PackageFamilyName)) {
            foreach ($e in $t.store) {
                if ([string]::Equals($e.pfn, $PackageFamilyName, [StringComparison]::OrdinalIgnoreCase)) {
                    $r.cor = $e.cor
                    $r.motivoCor = $e.motivo
                    if (-not [string]::IsNullOrEmpty($e.site)) { $r.siteReinstalar = $e.site }
                    if (-not [string]::IsNullOrEmpty($e.productId)) { $r.productId = $e.productId }
                    break
                }
            }
        }
        return $r
    }
    foreach ($e in $t.classicos) {
        if ([string]::IsNullOrEmpty($Nome) -or -not $e.regex.IsMatch($Nome)) { continue }
        if ($null -ne $e.regexEditor -and -not [string]::IsNullOrWhiteSpace($Editor) -and -not $e.regexEditor.IsMatch($Editor)) { continue }
        $r.cor = $e.cor
        $r.motivoCor = $e.motivo
        if (-not [string]::IsNullOrEmpty($e.site)) { $r.siteReinstalar = $e.site }
        break
    }
    return $r
}

# ---------- funcoes puras de desinstalacao ----------

function Get-Folha {
    # Nome do arquivo de um caminho; '' se o caminho tiver caracteres invalidos.
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return '' }
    try { return [IO.Path]::GetFileName($Caminho) } catch { return '' }
}

function Split-UninstallString {
    # Separa a UninstallString em executavel + argumentos (+ guid, se houver). Executavel entre aspas pode ter
    # espacos; sem aspas, o caminho vai ate o primeiro '.exe'. MsiExec vira exe 'msiexec.exe' (resolvido na execucao).
    param([string]$Texto)
    $r = [ordered]@{ exe = ''; args = ''; guid = $null }
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $r }
    $t = $Texto.Trim()
    if ($t.StartsWith('"')) {
        $fim = $t.IndexOf('"', 1)
        if ($fim -gt 0) {
            $r.exe = $t.Substring(1, $fim - 1).Trim()
            $r.args = $t.Substring($fim + 1).Trim()
        } else {
            $r.exe = $t.Trim('"').Trim()
        }
    } else {
        $m = [regex]::Match($t, '^(.+?\.exe)(\s+(.*))?$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) {
            $r.exe = $m.Groups[1].Value.Trim()
            $r.args = $m.Groups[3].Value.Trim()
        } else {
            $m2 = [regex]::Match($t, '^(\S+)(\s+(.*))?$')
            $r.exe = $m2.Groups[1].Value
            $r.args = $m2.Groups[3].Value.Trim()
        }
    }
    if ((Get-Folha $r.exe) -match '^msiexec(\.exe)?$') { $r.exe = 'msiexec.exe' }
    $g = [regex]::Match($t, $Script:PadraoGuid)
    if ($g.Success) { $r.guid = $g.Value }
    return $r
}

function Test-MarcaNullsoft {
    # O arquivo existe e seus primeiros 512 KB contem 'Nullsoft'?
    param([string]$Arquivo)
    if ([string]::IsNullOrWhiteSpace($Arquivo) -or $Arquivo -notmatch '^[A-Za-z]:\\') { return $false }   # nunca UNC ou \\.\pipe
    if (-not (Test-Path -LiteralPath $Arquivo -PathType Leaf)) { return $false }
    $fs = $null
    try {
        $fs = [IO.File]::OpenRead($Arquivo)
        $buf = New-Object byte[] 524288
        $lidos = $fs.Read($buf, 0, $buf.Length)
        if ($lidos -le 0) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buf, 0, $lidos).IndexOf('Nullsoft', [StringComparison]::Ordinal) -ge 0)
    } catch { return $false }
    finally { if ($null -ne $fs) { $fs.Dispose() } }
}

function Get-TipoInstalador {
    # msi | inno | nsis | installshield | quiet | loja | desconhecido.
    param([string]$UninstallString = '', [string]$QuietUninstallString = '', $WindowsInstaller = $null, [string]$Tipo = 'classico')
    if ($Tipo -eq 'store') { return 'loja' }
    if (-not [string]::IsNullOrWhiteSpace($QuietUninstallString)) { return 'quiet' }
    if ([string]::IsNullOrWhiteSpace($UninstallString)) { return 'desconhecido' }
    $s = Split-UninstallString $UninstallString
    $folha = Get-Folha $s.exe
    $ehMsi = ($null -ne $WindowsInstaller -and ([string]$WindowsInstaller) -eq '1')
    if ($null -ne $s.guid -and ($s.exe -eq 'msiexec.exe' -or $ehMsi)) { return 'msi' }
    if ($folha -match '^unins\d+\.exe$') { return 'inno' }
    if ($folha -match '^(uninst(all)?|un_a)\.exe$') { return 'nsis' }
    if ($UninstallString -match 'InstallShield|setup\.exe\s+-runfromtemp' -or $UninstallString -match ($Script:PadraoGuid + '\\setup\.exe')) { return 'installshield' }
    if (Test-MarcaNullsoft $s.exe) { return 'nsis' }
    return 'desconhecido'
}

function Add-ArgumentoAusente {
    # Acrescenta o token ao FINAL dos argumentos se ele ainda nao estiver la (token inteiro, nao trecho).
    param([string]$Argumentos, [string]$Token, [bool]$DiferenciaCaixa = $false)
    $padrao = '(^|\s)' + [regex]::Escape($Token) + '(\s|$)'
    if ($DiferenciaCaixa) { $tem = $Argumentos -cmatch $padrao } else { $tem = $Argumentos -imatch $padrao }
    if ($tem) { return $Argumentos }
    if ([string]::IsNullOrEmpty($Argumentos)) { return $Token }
    return ($Argumentos + ' ' + $Token)
}

function Get-ArgumentosSilenciosos {
    # Argumentos com as opcoes silenciosas do tipo, acrescentadas no fim e sem duplicar as ja presentes.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Tipo, [string]$Argumentos = '')
    $a = ([string]$Argumentos).Trim()
    switch ($Tipo) {
        'inno' {
            foreach ($t in @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')) { $a = Add-ArgumentoAusente $a $t $false }
        }
        'nsis' { $a = Add-ArgumentoAusente $a '/S' $true }
        'installshield' {
            if ($a -inotmatch '(^|\s)/s(\s|$)') { $a = Add-ArgumentoAusente $a '/s' $true }
            if ($a -inotmatch '(^|\s)/v') { $a = Add-ArgumentoAusente $a '/v"/qn"' $true }
        }
        'msi' {
            $a = [regex]::Replace($a, '(^|\s)/[Ii](?=\s*\{)', '$1/X')
            if ($a -inotmatch '(^|\s)/q') { $a = Add-ArgumentoAusente $a '/qn' $false }
            $a = Add-ArgumentoAusente $a '/norestart' $false
        }
    }
    return $a.Trim()
}

# ---------- tamanho com teto ----------

function Get-TamanhoComTeto {
    # Soma os arquivos sem seguir junctions/links, parando no teto de tempo. -1 = desconhecido (estourou o teto,
    # caminho vazio/inexistente, raiz e um link ou nao pode ser lida).
    param([string]$Path, [int]$TetoMs = 10000)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return [int64]-1 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (Test-Reparse $item)) { return [int64]-1 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $total = [int64]0
    $raiz = $item.FullName
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($raiz)
    while ($pilha.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -gt $TetoMs) { return [int64]-1 }
        $dir = $pilha.Pop()
        $erros = @()
        $filhos = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable erros)
        if ($dir -eq $raiz -and $erros.Count -gt 0 -and $filhos.Count -eq 0) { return [int64]-1 }
        foreach ($f in $filhos) {
            if (Test-Reparse $f) { continue }
            if ($f.PSIsContainer) { $pilha.Push($f.FullName) } else { $total += $f.Length }
        }
    }
    return $total
}

function Get-ResumoPasta {
    # Percorre a pasta sem seguir links: @{ ok; temExecutavel; maisRecente } (maisRecente inclui a propria pasta).
    param([string]$Path)
    $r = @{ ok = $false; temExecutavel = $false; maisRecente = [DateTime]::MinValue }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer -or (Test-Reparse $item)) { return $r }
    $r.ok = $true
    $r.maisRecente = $item.LastWriteTime
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($item.FullName)
    while ($pilha.Count -gt 0) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pilha.Pop() -Force -ErrorAction SilentlyContinue)) {
            if (Test-Reparse $f) { continue }
            if ($f.LastWriteTime -gt $r.maisRecente) { $r.maisRecente = $f.LastWriteTime }
            if ($f.PSIsContainer) { $pilha.Push($f.FullName); continue }
            if ($Script:ExtensoesExecutaveis -contains $f.Extension.ToLowerInvariant()) { $r.temExecutavel = $true }
        }
    }
    return $r
}

function Get-ArquivoSemLink {
    # Arquivos com a extensao pedida sob a raiz, sem seguir junctions/links.
    param([string]$Raiz, [string]$Extensao)
    $lista = New-Object System.Collections.Generic.List[object]
    $item = Get-Item -LiteralPath $Raiz -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer -or (Test-Reparse $item)) { return @() }
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($item.FullName)
    while ($pilha.Count -gt 0) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pilha.Pop() -Force -ErrorAction SilentlyContinue)) {
            if (Test-Reparse $f) { continue }
            if ($f.PSIsContainer) { $pilha.Push($f.FullName); continue }
            if ($f.Extension -eq $Extensao) { $lista.Add($f) }
        }
    }
    return $lista.ToArray()
}

# ---------- programas ----------

function ConvertTo-DataInstalacao {
    # 'yyyyMMdd' -> 'yyyy-MM-dd' (ISO 8601); $null se vazio ou ilegivel.
    param($Valor)
    if ($null -eq $Valor) { return $null }
    $s = ([string]$Valor).Trim()
    if ($s -notmatch '^\d{8}$') { return $null }
    $d = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact($s, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)
    if (-not $ok) { return $null }
    return $d.ToString('yyyy-MM-dd')
}

function Get-EditorDoCertificado {
    # 'CN=Microsoft Corporation, O=...' -> 'Microsoft Corporation'; texto sem CN= volta como esta.
    param([string]$Publisher)
    if ([string]::IsNullOrWhiteSpace($Publisher)) { return '' }
    $m = [regex]::Match($Publisher, 'CN="([^"]+)"|CN=([^,]+)')
    if ($m.Success) {
        if ($m.Groups[1].Success) { return $m.Groups[1].Value.Trim() }
        return $m.Groups[2].Value.Trim()
    }
    return $Publisher.Trim()
}

function Get-LocalNormalizado {
    # InstallLocation sem aspas nem barra final; vazio quando e raiz de unidade ou uma pasta-base do sistema
    # (Program Files, ProgramData, AppData...), que nunca identificam um programa.
    param([string]$Local)
    $l = ([string]$Local).Trim().Trim('"').TrimEnd('\')
    if ($l.Length -le 3) { return '' }
    foreach ($raiz in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:LOCALAPPDATA, $env:APPDATA, $env:USERPROFILE)) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        if ([string]::Equals($l, $raiz.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return '' }
    }
    return $l
}

function New-Programa {
    # Registro interno de um programa (ja classificado). Tamanho -1 = ainda desconhecido (medido em listar).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, [string]$Tipo, [string]$Nome, [string]$Versao = '', [string]$Editor = '', [string]$Local = '',
        [string]$UninstallString = '', [string]$QuietUninstallString = '', $WindowsInstaller = $null, $EstimatedSizeKb = $null,
        $InstallDate = $null, [string]$PackageFullName = '', [string]$PackageFamilyName = '', [string]$SignatureKind = '', [bool]$NonRemovable = $false)
    $local = Get-LocalNormalizado $Local
    $tam = [int64]-1
    if ($null -ne $EstimatedSizeKb) {
        try { $tam = [int64]$EstimatedSizeKb * 1024 } catch { $tam = [int64]-1 }
    }
    $c = Get-Classificacao $Nome $Editor $PackageFamilyName $local $Tipo $SignatureKind $NonRemovable
    $instalador = Get-TipoInstalador -UninstallString $UninstallString -QuietUninstallString $QuietUninstallString -WindowsInstaller $WindowsInstaller -Tipo $Tipo
    return [ordered]@{
        id                   = $Id
        nome                 = $Nome
        versao               = ([string]$Versao).Trim()
        editor               = ([string]$Editor).Trim()
        tipo                 = $Tipo
        tamanhoBytes         = $tam
        instaladoEm          = (ConvertTo-DataInstalacao $InstallDate)
        local                = $local
        cor                  = $c.cor
        motivoCor            = $c.motivoCor
        protegido            = [bool]$c.protegido
        motivoProtegido      = $c.motivoProtegido
        instalador           = $instalador
        servicos             = @()
        ramBytes             = [int64]0
        packageFamilyName    = $PackageFamilyName
        packageFullName      = $PackageFullName
        productId            = $c.productId
        siteReinstalar       = $c.siteReinstalar
        uninstallString      = ([string]$UninstallString).Trim()
        quietUninstallString = ([string]$QuietUninstallString).Trim()
    }
}

function Get-ChaveUninstall {
    param([string]$Hive, [bool]$Teste)
    if ($Teste) { return "HKCU:\Software\NexTuneTeste\Uninstall\$Hive" }
    switch ($Hive) {
        'hklm64' { return 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
        'hklm32' { return 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
        'hkcu' { return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' }
    }
    throw "hive desconhecida: $Hive"
}

function Test-ValorUm {
    param($Valor)
    if ($null -eq $Valor) { return $false }
    return (([string]$Valor) -eq '1')
}

function Get-ProgramaClassico {
    # Programas de uma hive do Uninstall. Ignora SystemComponent=1, sem DisplayName, com ParentKeyName e atualizacoes KB.
    param([string]$Hive, [bool]$Teste)
    $lista = New-Object System.Collections.Generic.List[object]
    $base = Get-ChaveUninstall $Hive $Teste
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $v = $null
        try { $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { $v = $null }
        if ($null -eq $v) { continue }
        $nome = ([string]$v.DisplayName).Trim()
        if ([string]::IsNullOrWhiteSpace($nome)) { continue }
        if (Test-ValorUm $v.SystemComponent) { continue }
        if (-not [string]::IsNullOrWhiteSpace([string]$v.ParentKeyName)) { continue }
        if ($nome -match $Script:PadraoAtualizacao) { continue }
        $campos = @{
            Id                   = 'cl:' + $Hive + ':' + $k.PSChildName
            Tipo                 = 'classico'
            Nome                 = $nome
            Versao               = [string]$v.DisplayVersion
            Editor               = [string]$v.Publisher
            Local                = [string]$v.InstallLocation
            UninstallString      = [string]$v.UninstallString
            QuietUninstallString = [string]$v.QuietUninstallString
            WindowsInstaller     = $v.WindowsInstaller
            EstimatedSizeKb      = $v.EstimatedSize
            InstallDate          = $v.InstallDate
        }
        $lista.Add((New-Programa @campos))
    }
    return $lista.ToArray()
}

function Get-PacoteStore {
    # Pacotes brutos da Store: Get-AppxPackage -AllUsers fora do teste; simular.store em teste (nunca Get-AppxPackage);
    # simular.erroStore em teste faz de conta que a Store nao pode ser lida.
    param([bool]$Teste, $Simulacao)
    if ($Teste) {
        if ($null -ne $Simulacao -and $null -ne $Simulacao.erroStore) {
            $Script:ErroStore = [string]$Simulacao.erroStore   # simula a Store ilegivel
            return @()
        }
        if ($null -eq $Simulacao -or $null -eq $Simulacao.store) { return @() }
        return @($Simulacao.store)
    }
    try { return @(Get-AppxPackage -AllUsers -ErrorAction Stop) }
    catch {
        $Script:ErroStore = $_.Exception.Message
        return @()
    }
}

function Get-ProgramaStore {
    # Apps da Store sem frameworks, sem SignatureKind 'System' e sem NonRemovable. Id st:<PackageFullName>.
    param([bool]$Teste, $Simulacao)
    $lista = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-PacoteStore $Teste $Simulacao)) {
        if ($null -eq $p) { continue }
        $full = [string]$p.PackageFullName
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        if ([bool]$p.IsFramework) { continue }
        $assinatura = [string]$p.SignatureKind
        $naoRemovivel = $false
        if ($null -ne $p.NonRemovable) { $naoRemovivel = [bool]$p.NonRemovable }
        if ($assinatura -eq 'System' -or $naoRemovivel) { continue }
        $campos = @{
            Id                = 'st:' + $full
            Tipo              = 'store'
            Nome              = [string]$p.Name
            Versao            = [string]$p.Version
            Editor            = Get-EditorDoCertificado ([string]$p.Publisher)
            Local             = [string]$p.InstallLocation
            PackageFullName   = $full
            PackageFamilyName = [string]$p.PackageFamilyName
            SignatureKind     = $assinatura
            NonRemovable      = $naoRemovivel
        }
        $lista.Add((New-Programa @campos))
    }
    return $lista.ToArray()
}

function Get-ProgramaPorId {
    # Resolve o id contra a lista gerada aqui (so a fonte necessaria). $null se nao existir. O id nunca vira caminho.
    param([string]$Id, [bool]$Teste, $Simulacao = $null)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    $lista = @()
    if ($Id -match '^cl:(hklm64|hklm32|hkcu):.') { $lista = @(Get-ProgramaClassico $Matches[1] $Teste) }
    elseif ($Id -match '^st:.') { $lista = @(Get-ProgramaStore $Teste $Simulacao) }
    else { return $null }
    foreach ($p in $lista) { if ($p.id -eq $Id) { return $p } }
    return $null
}

function Test-SobLocal {
    # O caminho (de servico/processo) esta dentro de $Local?
    param([string]$Caminho, [string]$Local)
    if ([string]::IsNullOrWhiteSpace($Caminho) -or [string]::IsNullOrWhiteSpace($Local)) { return $false }
    $c = $Caminho.Trim().TrimStart('"')
    return $c.StartsWith($Local.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Add-Enriquecimento {
    # Tamanhos (com teto), servicos (Win32_Service uma vez) e RAM (Get-Process uma vez). Servicos/RAM so fora do teste.
    param([string]$Id, $Lista, [bool]$Teste)
    $servicos = @()
    $processos = @()
    if (-not $Teste) {
        try { $servicos = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { -not [string]::IsNullOrEmpty($_.PathName) }) } catch { $servicos = @() }
        try { $processos = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrEmpty($_.Path) }) } catch { $processos = @() }
    }
    $n = [math]::Max(1, [int]$Lista.Count)   # @($Lista) sobre List[object] de [ordered] lança no PS 5.1 (19041)
    $i = 0
    foreach ($p in $Lista) {
        if (($i % 10) -eq 0) { Send-Progress $Id (70 + [int](30 * $i / $n)) "Medindo $($p.nome)" }
        $i++
        if ([string]::IsNullOrEmpty($p.local)) { continue }
        if ($p.tamanhoBytes -lt 0) { $p.tamanhoBytes = Get-TamanhoComTeto $p.local $Script:TetoTamanhoMs }
        if ($Teste) { continue }
        $nomes = New-Object System.Collections.Generic.List[string]
        foreach ($s in $servicos) { if (Test-SobLocal ([string]$s.PathName) $p.local) { $nomes.Add([string]$s.Name) } }
        $p.servicos = @($nomes.ToArray())
        $ram = [int64]0
        foreach ($pr in $processos) { if (Test-SobLocal ([string]$pr.Path) $p.local) { $ram += [int64]$pr.WorkingSet64 } }
        $p.ramBytes = $ram
    }
}

function ConvertTo-ProgramaSaida {
    # Forma do contrato (sem as UninstallStrings internas).
    param($P)
    return [ordered]@{
        id                = $P.id
        nome              = $P.nome
        versao            = $P.versao
        editor            = $P.editor
        tipo              = $P.tipo
        tamanhoBytes      = [int64]$P.tamanhoBytes
        instaladoEm       = $P.instaladoEm
        local             = $P.local
        cor               = $P.cor
        motivoCor         = $P.motivoCor
        protegido         = [bool]$P.protegido
        motivoProtegido   = $P.motivoProtegido
        instalador        = $P.instalador
        servicos          = @($P.servicos)
        ramBytes          = [int64]$P.ramBytes
        packageFamilyName = $P.packageFamilyName
        productId         = $P.productId
        siteReinstalar    = $P.siteReinstalar
    }
}

# ---------- restos ----------

function Get-RaizResto {
    # Raizes onde restos sao procurados. Em teste, tudo sob %TEMP%\NexTuneTeste\restos e HKCU\Software\NexTuneTeste\Restos.
    param([bool]$Teste)
    if ($Teste) {
        $b = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'restos'
        return @{
            dados    = @((Join-Path $b 'LocalAppData'), (Join-Path $b 'AppData'), (Join-Path $b 'ProgramData'))
            atalhos  = @((Join-Path $b 'Menu'), (Join-Path $b 'Desktop'))
            registro = @('HKCU\Software\NexTuneTeste\Restos\HKCU', 'HKCU\Software\NexTuneTeste\Restos\HKLM')
        }
    }
    $atalhos = New-Object System.Collections.Generic.List[string]
    foreach ($par in @(@($env:APPDATA, 'Microsoft\Windows\Start Menu\Programs'), @($env:ProgramData, 'Microsoft\Windows\Start Menu\Programs'),
            @($env:USERPROFILE, 'Desktop'), @($env:PUBLIC, 'Desktop'))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$par[0])) { $atalhos.Add((Join-Path $par[0] $par[1])) }
    }
    return @{
        dados    = @($env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData)
        atalhos  = @($atalhos.ToArray())
        registro = @('HKCU\Software', 'HKLM\SOFTWARE')
    }
}

function Get-SegmentoSeguro {
    # Nome/editor como UM segmento de caminho ou de chave: sem caracteres invalidos, sem '.'/'..'; '' se nada sobrar.
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $t = $Texto.Trim()
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $t = $t.Replace([string]$c, '') }
    $t = $t.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($t) -or $t -eq '.' -or $t -eq '..') { return '' }
    return $t
}

function Get-SubcaminhoResto {
    # '<editor>\<nome>' (se houver editor) e '<nome>', ja saneados.
    param([string]$Nome, [string]$Editor)
    $n = Get-SegmentoSeguro $Nome
    if ($n -eq '') { return @() }
    $lista = New-Object System.Collections.Generic.List[string]
    $e = Get-SegmentoSeguro $Editor
    if ($e -ne '' -and -not [string]::Equals($e, $n, [StringComparison]::OrdinalIgnoreCase)) { $lista.Add($e + '\' + $n) }
    $lista.Add($n)
    return $lista.ToArray()
}

function Add-Candidato {
    # Acrescenta um candidato, recusando caminho protegido (nunca sob Test-ProtectedPath) e repetidos.
    param($Lista, [string]$Tipo, [string]$Caminho, [int64]$Tamanho, [string]$Motivo)
    if ($Tipo -ne 'chave' -and (Test-ProtectedPath $Caminho)) { return }
    foreach ($c in $Lista) {
        if ($c.tipo -eq $Tipo -and [string]::Equals($c.caminho, $Caminho, [StringComparison]::OrdinalIgnoreCase)) { return }
    }
    $Lista.Add([ordered]@{ tipo = $Tipo; caminho = $Caminho; tamanhoBytes = $Tamanho; motivo = $Motivo; confianca = 'media' })
}

function Test-PastaCandidata {
    # Pasta existente, sem link/juncao nela, acima dela ou dentro dela (Add-ItemQuarentena recusaria), sem
    # .exe/.dll/.sys e (se $ExigirIdade) sem alteracao ha 30 dias.
    param([string]$Caminho, [bool]$ExigirIdade)
    if (Test-ProtectedPath $Caminho) { return $false }
    if (-not (Test-CadeiaSemLink $Caminho) -or -not (Test-ArvoreSemLink $Caminho)) { return $false }
    $r = Get-ResumoPasta $Caminho
    if (-not $r.ok -or $r.temExecutavel) { return $false }
    if ($ExigirIdade -and $r.maisRecente -gt (Get-Date).AddDays(-$Script:DiasResto)) { return $false }
    return $true
}

function Test-ContemNome {
    param([string]$Texto, [string]$Nome)
    if ([string]::IsNullOrEmpty($Texto) -or [string]::IsNullOrEmpty($Nome)) { return $false }
    return ($Texto.IndexOf($Nome, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-SubchaveProibida {
    # Puro: algum segmento do subcaminho ('<editor>\<nome>' ou o resto de uma chave) e area que nunca vira
    # candidato (Microsoft, Classes, Policies, Windows...)?
    param([string]$Sub)
    foreach ($seg in @($Sub -split '\\')) {
        if ($Script:SegmentosProibidos -contains $seg.Trim().ToLowerInvariant()) { return $true }
    }
    return $false
}

function Test-ChaveRestoPermitida {
    # Puro: chave que pode ser resto: raiz HKCU\Software ou HKLM\SOFTWARE (sem diferenciar caixa), pelo menos
    # 3 segmentos e nenhum segmento abaixo da raiz proibido. Vale fora e dentro do modo teste.
    param([string]$Chave)
    if (-not (Test-ChaveRegistro $Chave)) { return $false }
    $partes = @($Chave.TrimEnd('\') -split '\\')
    if ($partes.Count -lt 3) { return $false }
    $raiz = $partes[0].ToLowerInvariant()
    if ($raiz -ne 'hkcu' -and $raiz -ne 'hkey_current_user' -and $raiz -ne 'hklm' -and $raiz -ne 'hkey_local_machine') { return $false }
    if ($partes[1].ToLowerInvariant() -ne 'software') { return $false }
    return (-not (Test-SubchaveProibida ($partes[2..($partes.Count - 1)] -join '\')))
}

function Get-CandidatoResto {
    # Candidatos a resto de um programa: local, pastas de dados, atalhos quebrados e chaves (so se ja nao esta na lista).
    param([string]$Nome, [string]$Editor = '', [string]$Local = '', [bool]$AindaInstalado = $false, [bool]$Teste = $false)
    $lista = New-Object System.Collections.Generic.List[object]
    $nome = ([string]$Nome).Trim()
    if ([string]::IsNullOrWhiteSpace($nome)) { return @() }
    if ($null -ne (Get-MotivoProtegido $nome $Editor '')) { return @() }
    $raizes = Get-RaizResto $Teste

    # A pasta de instalacao so e resto quando o programa ja nao esta na lista (spec: "sem programa instalado correspondente").
    $local = ([string]$Local).Trim().Trim('"').TrimEnd('\')
    if (-not $AindaInstalado -and -not [string]::IsNullOrWhiteSpace($local) -and $local -match '^[A-Za-z]:\\.' -and (Test-Path -LiteralPath $local -PathType Container)) {
        if (Test-PastaCandidata $local $false) {
            Add-Candidato $lista 'pasta' ([IO.Path]::GetFullPath($local)) (Get-PathSize $local) 'Pasta de instalação que ficou depois da desinstalação (sem programas dentro).'
        }
    }

    $subs = @(Get-SubcaminhoResto $nome $Editor)
    foreach ($raiz in $raizes.dados) {
        if ([string]::IsNullOrWhiteSpace($raiz) -or -not (Test-Path -LiteralPath $raiz -PathType Container)) { continue }
        $raizFull = [IO.Path]::GetFullPath($raiz).TrimEnd('\')
        foreach ($sub in $subs) {
            $cand = $null
            try { $cand = [IO.Path]::GetFullPath((Join-Path $raizFull $sub)) } catch { $cand = $null }
            if ($null -eq $cand -or -not $cand.StartsWith($raizFull + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not (Test-Path -LiteralPath $cand -PathType Container)) { continue }
            if (Test-PastaCandidata $cand $true) {
                Add-Candidato $lista 'pasta' $cand (Get-PathSize $cand) 'Dados de um programa sem alteração há mais de 30 dias.'
            }
        }
    }

    foreach ($raiz in $raizes.atalhos) {
        if ($nome.Length -lt 3) { break }   # nome curto casaria com atalhos de qualquer programa
        if ([string]::IsNullOrWhiteSpace($raiz) -or -not (Test-Path -LiteralPath $raiz -PathType Container)) { continue }
        $raizFull = [IO.Path]::GetFullPath($raiz).TrimEnd('\')
        foreach ($lnk in @(Get-ArquivoSemLink $raizFull '.lnk')) {
            $relativo = $lnk.FullName.Substring([math]::Min($raizFull.Length, $lnk.FullName.Length))
            $alvo = Get-AlvoAtalho $lnk.FullName
            if ([string]::IsNullOrWhiteSpace($alvo)) { continue }
            if (-not (Test-ContemNome $relativo $nome) -and -not (Test-ContemNome $alvo $nome)) { continue }
            if (Test-Path -LiteralPath $alvo) { continue }
            Add-Candidato $lista 'atalho' $lnk.FullName ([int64]$lnk.Length) "Atalho cujo destino não existe mais: $alvo"
        }
    }

    if (-not $AindaInstalado) {
        foreach ($raiz in $raizes.registro) {
            foreach ($sub in $subs) {
                $chave = $raiz + '\' + $sub
                if (-not (Test-ChaveRestoPermitida $chave)) { continue }
                if ($Teste -and -not (Test-ChaveTeste $chave)) { continue }
                $prov = $null
                try { $prov = ConvertTo-CaminhoRegistro $chave } catch { $prov = $null }
                if ($null -eq $prov -or -not (Test-Path -LiteralPath $prov)) { continue }
                Add-Candidato $lista 'chave' $chave ([int64]0) 'Configurações no registro de um programa que não está mais instalado.'
            }
        }
    }
    return $lista.ToArray()
}

# ---------- restos antigos (programas ja desinstalados) ----------
# Porta de residuos.ps1 do RetroLimpia (MIT, Retropunk94): limpeza do nome (Get-CleanName) e comparacao por nome.
# O RetroLimpia so pontua candidatos de UM programa que acabou de sair; a busca global, os sinais extras de
# "instalado" e a regra de 'seguro' abaixo sao do NexTune (na duvida, nunca 'seguro').

function Get-NomeLimpo {
    # Puro: nome sem (R)/(TM)/marcas, parenteses e colchetes, sufixo ' - ...', arquitetura (x64, 64-bit...), versao
    # (1.2, v3.4.5) e sufixos de empresa no fim (Inc, LLC, Ltd, Ltda, GmbH, S.A., Corporation...). '' se nada sobrar.
    param([string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return '' }
    $n = $Nome -replace '[\u00AE\u2122\u00A9]', ' '
    $n = $n -replace '\(.*?\)|\[.*?\]', ' '
    $n = $n -replace '\s+-\s+.*$', ''
    $n = $n -replace '(?i)\b(x86_64|x64|x86|amd64|arm64|win64|64-bit|32-bit|64 bits|32 bits|version|versão|versión)\b', ' '
    $n = $n -replace '(?i)\bv?\d+(\.\d+)+\b', ' '
    $sufixo = '(?i)[\s,]+(inc|incorporated|llc|ltd|ltda|limited|gmbh|ag|co|corp|corporation|pty|ab|s\.?\s?a|s\.?r\.?l|b\.?v)\.?\s*$'
    while ($true) {
        $novo = $n -replace $sufixo, ''
        if ($novo -eq $n) { break }
        $n = $novo
    }
    $n = $n -replace '\s{2,}', ' '
    return $n.Trim([char[]]@(' ', '-', '_', '.', ',')).Trim()
}

function Test-TextoUnicode {
    # Puro: o texto nao tem surrogate solto (String.Normalize lancaria com ele).
    param([string]$Texto)
    if ($null -eq $Texto) { return $true }
    $i = 0
    while ($i -lt $Texto.Length) {
        if ([char]::IsHighSurrogate($Texto[$i])) {
            if ($i + 1 -ge $Texto.Length -or -not [char]::IsLowSurrogate($Texto[$i + 1])) { return $false }
            $i += 2
            continue
        }
        if ([char]::IsLowSurrogate($Texto[$i])) { return $false }
        $i++
    }
    return $true
}

function ConvertTo-Compacto {
    # Puro: minusculas, sem acentos, so letras e digitos. '' quando o texto e Unicode invalido (surrogate solto)
    # ou a normalizacao falha: nome '' nunca e 'seguro'.
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto) -or -not (Test-TextoUnicode $Texto)) { return '' }
    $t = ''
    try { $t = $Texto.ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD) } catch { return '' }
    return ($t -replace '[^\p{L}\p{Nd}]', '')
}

function ConvertTo-NomeCompacto {
    # Puro: nome limpo compacto ('OBS Studio 30.0 (64-bit)' e 'obs-studio' -> 'obsstudio').
    param([string]$Nome)
    return (ConvertTo-Compacto (Get-NomeLimpo $Nome))
}

function Get-CompactoNome {
    # Puro: formas compactas de um nome para comparar: a do nome limpo e a do nome cru (sem vazias nem repetidas).
    param([string]$Nome)
    $r = New-Object System.Collections.Generic.List[string]
    foreach ($x in @((ConvertTo-NomeCompacto $Nome), (ConvertTo-Compacto $Nome))) {
        if ($x -ne '' -and -not $r.Contains($x)) { $r.Add($x) }
    }
    return $r.ToArray()
}

function Test-NomeParecido {
    # Puro: um nome compacto contem o outro (nos dois sentidos). O lado contido precisa de $Script:MinCompararNome
    # caracteres: 'r' ou 'go' casariam com quase tudo.
    param([string]$A, [string]$B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    if ($B.Length -ge $Script:MinCompararNome -and $A.Contains($B)) { return $true }
    if ($A.Length -ge $Script:MinCompararNome -and $B.Contains($A)) { return $true }
    return $false
}

function Test-NomeNuncaResto {
    # Puro: nome de pasta que nunca vira resto ($Script:PastasNuncaResto).
    param([string]$Nome)
    if ([string]::IsNullOrWhiteSpace($Nome)) { return $true }
    foreach ($p in $Script:PastasNuncaResto) { if ($Nome -like $p) { return $true } }
    return $false
}

function Get-TipoUnidade {
    # 'fixa', 'removivel' (pronta mas nao fixa: USB, CD, RAM), 'rede' ou 'ausente' (letra sem disco ou sem midia).
    # Unidade de rede nunca e consultada alem do tipo (nada e acessado pela rede). Cache por execucao.
    param([string]$Caminho)
    if ([string]::IsNullOrEmpty($Caminho) -or $Caminho -notmatch '^[A-Za-z]:') { return 'ausente' }
    $k = $Caminho.Substring(0, 1).ToUpperInvariant()
    if ($Script:TiposUnidade.ContainsKey($k)) { return $Script:TiposUnidade[$k] }
    $t = 'ausente'
    try {
        $d = New-Object System.IO.DriveInfo -ArgumentList $k
        if ($d.DriveType -eq [IO.DriveType]::Network) { $t = 'rede' }
        elseif ($d.DriveType -eq [IO.DriveType]::NoRootDirectory -or -not $d.IsReady) { $t = 'ausente' }
        elseif ($d.DriveType -eq [IO.DriveType]::Fixed) { $t = 'fixa' }
        else { $t = 'removivel' }
    } catch { $t = 'ausente' }
    $Script:TiposUnidade[$k] = $t
    return $t
}

function Get-CaminhoLongoResto {
    # Caminho absoluto com variaveis de ambiente expandidas e nomes 8.3 expandidos no ancestral existente mais
    # proximo (como Test-ProtectedPath), sem barra final. '' se nao for caminho com letra de unidade. Fora de disco
    # fixo o caminho volta so expandido (nada e consultado em disco de rede ou removivel).
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return '' }
    $c = [Environment]::ExpandEnvironmentVariables($Caminho.Trim().Trim('"').Trim())
    if ($c -notmatch '^[A-Za-z]:\\') { return '' }
    try { $c = [IO.Path]::GetFullPath($c).TrimEnd('\') } catch { return '' }
    if ((Get-TipoUnidade $c) -ne 'fixa') { return $c }
    $existente = $c
    $resto = ''
    while ($existente.Length -gt 3 -and -not (Test-Path -LiteralPath $existente)) {
        $resto = '\' + [IO.Path]::GetFileName($existente) + $resto
        $existente = [IO.Path]::GetDirectoryName($existente)
        if ([string]::IsNullOrEmpty($existente)) { return $c }
    }
    if ($existente.Length -le 3) { return $c }
    try {
        if ($null -eq $Script:Fso) { $Script:Fso = New-Object -ComObject Scripting.FileSystemObject }
        if (Test-Path -LiteralPath $existente -PathType Container) { $exp = [string]$Script:Fso.GetFolder($existente).Path }
        else { $exp = [string]$Script:Fso.GetFile($existente).Path }
        return $exp.TrimEnd('\') + $resto
    } catch { return $c }
}

function Get-PastaDeComando {
    # Pasta do executavel de uma UninstallString ou, com $Icone, de um DisplayIcon ('"C:\X\app.exe",0'), com
    # variaveis expandidas. '' quando nao e caminho absoluto com letra de unidade (msiexec, rundll32 solto, UNC).
    param([string]$Texto, [bool]$Icone = $false)
    $exe = Get-ExecutavelDeComando $Texto $Icone
    if ($exe -eq '') { return '' }
    try { return [string][IO.Path]::GetDirectoryName($exe) } catch { return '' }
}

function Get-ExecutavelDeComando {
    # Caminho completo do executavel de uma UninstallString/ImagePath ou (com $Icone) de um DisplayIcon; '' se nao der.
    param([string]$Texto, [bool]$Icone = $false)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return '' }
    $t = [Environment]::ExpandEnvironmentVariables($Texto.Trim())
    if ($Icone) { $exe = ($t -replace ',\s*-?\d+\s*$', '').Trim().Trim('"').Trim() }
    else { $exe = (Split-UninstallString $t).exe }
    if ($exe -notmatch '^[A-Za-z]:\\.') { return '' }
    try { return [IO.Path]::GetFullPath($exe) } catch { return '' }
}

function Get-ImagemServico {
    # ImagePath de servico -> caminho completo do executavel ('\??\', '\SystemRoot\' e 'system32\...' resolvidos).
    param([string]$Imagem)
    $t = ([string]$Imagem).Trim()
    if ($t -eq '') { return '' }
    $t = $t -replace '^\\\?\?\\', ''
    if ($t -match '^(?i)\\SystemRoot\\(.*)$') { $t = Join-Path $env:windir $Matches[1] }
    elseif ($t -match '^(?i)(system32|syswow64)\\') { $t = Join-Path $env:windir $t }
    return (Get-ExecutavelDeComando $t)
}

function Get-RaizValida {
    # Raiz de busca em forma longa, ou '' (com log) quando nao e caminho local num disco fixo (AppData ou Menu
    # Iniciar redirecionados para a rede nunca sao percorridos), nao existe ou tem link na cadeia.
    param([string]$Id, [string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return '' }
    if ($Caminho -notmatch '^[A-Za-z]:\\' -or (Get-TipoUnidade $Caminho) -ne 'fixa') {
        Send-Log $Id 'info' 'Pasta fora de um disco local deste PC (rede ou redirecionada): não é percorrida.' $Caminho
        return ''
    }
    $c = Get-CaminhoLongoResto $Caminho
    if ($c -eq '' -or -not (Test-Path -LiteralPath $c -PathType Container)) { return '' }
    if (-not (Test-CadeiaSemLink $c)) {
        Send-Log $Id 'info' 'Pasta com link ou junção no caminho: não é percorrida.' $c
        return ''
    }
    return $c
}

function Get-RaizRestoAntigo {
    # @{ pastas = @(@{ caminho; usuario }); atalhos = @(caminho) } ainda sem validar. usuario = AppData/LocalAppData:
    # dados do usuario, nunca 'seguro'. Em teste, tudo sob %TEMP%\NexTuneTeste\restosAntigos.
    param([bool]$Teste)
    if ($Teste) {
        $b = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'restosAntigos'
        return @{
            pastas  = @(
                @{ caminho = (Join-Path $b 'ProgramFiles'); usuario = $false },
                @{ caminho = (Join-Path $b 'ProgramFilesX86'); usuario = $false },
                @{ caminho = (Join-Path $b 'ProgramData'); usuario = $false },
                @{ caminho = (Join-Path $b 'AppData'); usuario = $true },
                @{ caminho = (Join-Path $b 'LocalAppData'); usuario = $true }
            )
            atalhos = @((Join-Path $b 'Menu'))
        }
    }
    $atalhos = New-Object System.Collections.Generic.List[string]
    foreach ($base in @($env:APPDATA, $env:ProgramData)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) { $atalhos.Add((Join-Path $base 'Microsoft\Windows\Start Menu\Programs')) }
    }
    return @{
        pastas  = @(
            @{ caminho = $env:ProgramFiles; usuario = $false },
            @{ caminho = ${env:ProgramFiles(x86)}; usuario = $false },
            @{ caminho = $env:ProgramData; usuario = $false },
            @{ caminho = $env:APPDATA; usuario = $true },
            @{ caminho = $env:LOCALAPPDATA; usuario = $true }
        )
        atalhos = $atalhos.ToArray()
    }
}

function Get-PastaReferencia {
    # Pasta que identifica um programa: forma longa, nao e raiz de unidade nem pasta-base do sistema e nao e raiz de
    # busca nem fica acima de uma (ex.: desinstalador solto em AppData). '' se nao servir.
    param($Contexto, [string]$Caminho)
    $n = Get-CaminhoLongoResto $Caminho
    if ($n -eq '') { return '' }
    $n = Get-LocalNormalizado $n
    if ($n -notmatch '^[A-Za-z]:\\.') { return '' }
    foreach ($r in $Contexto.raizes) {
        if ([string]::Equals($r, $n, [StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($n + '\', [StringComparison]::OrdinalIgnoreCase)) { return '' }
    }
    return $n
}

function Add-ReferenciaInstalada {
    # Acrescenta um instalado: rotulo, nome e editor (originais e formas compactas) e as pastas que ocupa.
    param($Contexto, [string]$Nome, [string]$Editor, [string[]]$Locais, [string]$Rotulo = '')
    $pastas = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Locais) {
        $n = Get-PastaReferencia $Contexto $l
        if ($n -ne '' -and -not $pastas.Contains($n)) { $pastas.Add($n) }
    }
    $nomes = @(Get-CompactoNome $Nome)
    $editores = @(Get-CompactoNome $Editor)
    if ($nomes.Count -eq 0 -and $editores.Count -eq 0 -and $pastas.Count -eq 0) { return }
    $texto = $Rotulo
    if ([string]::IsNullOrWhiteSpace($texto)) { $texto = ([string]$Nome).Trim() }
    if ([string]::IsNullOrWhiteSpace($texto)) { $texto = ([string]$Editor).Trim() }
    if ([string]::IsNullOrWhiteSpace($texto)) { $texto = 'um programa instalado' }
    $Contexto.instalados.Add(@{ rotulo = $texto; nome = ([string]$Nome).Trim(); editor = ([string]$Editor).Trim(); nomes = $nomes; editores = $editores; pastas = $pastas.ToArray() })
}

function Add-ExtraResto {
    # Nome que so casa por IGUALDADE (formas compactas): exe e subpastas do InstallLocation, icone, servicos,
    # destinos de atalhos validos. Pasta com esse nome aparece, mas nunca 'segura'.
    param($Contexto, [string]$Nome, [string]$Descricao)
    foreach ($c in @(Get-CompactoNome $Nome)) {
        if (-not $Contexto.extras.ContainsKey($c)) { $Contexto.extras[$c] = $Descricao }
    }
}

function Add-ExtraLocalInstalacao {
    # Nomes de .exe e de subpastas do primeiro nivel do InstallLocation (so leitura do primeiro nivel, disco fixo).
    param($Contexto, [string]$Local, [string]$Programa)
    if ($Local -eq '' -or (Get-TipoUnidade $Local) -ne 'fixa' -or -not (Test-Path -LiteralPath $Local -PathType Container)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $Local -Force -ErrorAction SilentlyContinue)) {
        if ($f.PSIsContainer) { Add-ExtraResto $Contexto $f.Name "pasta $($f.Name) dentro de $Programa"; continue }
        if ($f.Extension -eq '.exe') { Add-ExtraResto $Contexto $f.BaseName "$($f.Name) de $Programa" }
    }
}

function Get-ServicoResto {
    # Servicos: HKLM\SYSTEM\CurrentControlSet\Services fora do teste; simular.servicos ({nome, exibicao, imagem}) em
    # teste. Devolve @{ ok; lista }. ok=$false quando a lista nao pode ser lida.
    param([bool]$Teste, $Simulacao)
    $lista = New-Object System.Collections.Generic.List[object]
    if ($Teste) {
        if ($null -ne $Simulacao -and $null -ne $Simulacao.servicos) {
            foreach ($s in @($Simulacao.servicos)) {
                if ($null -ne $s) { $lista.Add(@{ nome = [string]$s.nome; exibicao = [string]$s.exibicao; imagem = [string]$s.imagem }) }
            }
        }
        return @{ ok = $true; lista = $lista.ToArray() }
    }
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services' -ErrorAction Stop)) {
            $v = $null
            try { $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { $v = $null }
            $exibicao = ''
            $imagem = ''
            if ($null -ne $v) {
                $exibicao = [string]$v.DisplayName
                $imagem = [string]$v.ImagePath
            }
            $lista.Add(@{ nome = [string]$k.PSChildName; exibicao = $exibicao; imagem = $imagem })
        }
    } catch { return @{ ok = $false; lista = @() } }
    return @{ ok = $true; lista = $lista.ToArray() }
}

function Get-ReferenciaInstalada {
    # Preenche $Contexto com os instalados: as tres hives do Uninstall (falsas em teste), a Store (simular.store em
    # teste) e os servicos. Diferente de listar, entram SystemComponent e ParentKeyName (continuam instalados e
    # ocupam pastas); so atualizacoes KB ficam de fora. Pastas: InstallLocation, pasta do desinstalador (normal e
    # silencioso), do icone e do executavel do servico. Fonte que nao pode ser lida vai para $Contexto.erros.
    param($Contexto, [bool]$Teste, $Simulacao)
    foreach ($h in $Script:Hives) {
        $base = Get-ChaveUninstall $h $Teste
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            $v = $null
            try { $v = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { $v = $null }
            if ($null -eq $v) { continue }
            $nome = ([string]$v.DisplayName).Trim()
            if ($nome -match $Script:PadraoAtualizacao) { continue }
            $rotulo = $nome
            if ($rotulo -eq '') { $rotulo = [string]$k.PSChildName }
            $locais = @([string]$v.InstallLocation, (Get-PastaDeComando ([string]$v.UninstallString)),
                (Get-PastaDeComando ([string]$v.QuietUninstallString)), (Get-PastaDeComando ([string]$v.DisplayIcon) $true))
            Add-ReferenciaInstalada $Contexto $nome ([string]$v.Publisher) $locais $rotulo
            $icone = Get-ExecutavelDeComando ([string]$v.DisplayIcon) $true
            if ($icone -ne '') { Add-ExtraResto $Contexto ([IO.Path]::GetFileNameWithoutExtension($icone)) "ícone de $rotulo" }
            Add-ExtraLocalInstalacao $Contexto (Get-PastaReferencia $Contexto ([string]$v.InstallLocation)) $rotulo
        }
    }
    foreach ($p in @(Get-PacoteStore $Teste $Simulacao)) {
        if ($null -eq $p) { continue }
        Add-ReferenciaInstalada $Contexto ([string]$p.Name) (Get-EditorDoCertificado ([string]$p.Publisher)) @([string]$p.InstallLocation)
    }
    $serv = Get-ServicoResto $Teste $Simulacao
    if (-not $serv.ok) { $Contexto.erros.Add('os serviços do Windows') }
    foreach ($s in $serv.lista) {
        $rotulo = "serviço $($s.nome)"
        Add-ExtraResto $Contexto $s.nome $rotulo
        if (-not ([string]$s.exibicao).StartsWith('@')) { Add-ExtraResto $Contexto $s.exibicao $rotulo }
        $exe = Get-ImagemServico $s.imagem
        if ($exe -ne '') { Add-ReferenciaInstalada $Contexto '' '' @([IO.Path]::GetDirectoryName($exe)) $rotulo }
    }
}

function Get-RelacaoInstalado {
    # Relacao de uma pasta com os instalados: @{ tipo; texto; campo }. Em ordem:
    # 'instalado' = e a pasta de um programa (local de instalacao, ou dentro dele, ou mesmo nome compacto);
    # 'conteiner' = guarda a pasta de um instalado ou tem o nome compacto igual ao editor de um (pasta do editor);
    # 'extra'     = mesmo nome compacto de um exe/subpasta do InstallLocation, icone, servico ou destino de atalho;
    # 'parecido'  = nome contido no nome/editor de um instalado ou o contrario (campo 'nome' ou 'editor');
    # ''          = nenhuma relacao. $Compactos = formas compactas do nome da pasta (limpa e crua).
    param([string]$Caminho, [string[]]$Compactos, $Contexto)
    $c = $Caminho.TrimEnd('\')
    $conteiner = $null
    foreach ($p in $Contexto.instalados) {
        foreach ($l in $p.pastas) {
            if ([string]::Equals($l, $c, [StringComparison]::OrdinalIgnoreCase) -or $c.StartsWith($l + '\', [StringComparison]::OrdinalIgnoreCase)) {
                return @{ tipo = 'instalado'; texto = $p.rotulo; campo = 'local' }
            }
            if ($null -eq $conteiner -and $l.StartsWith($c + '\', [StringComparison]::OrdinalIgnoreCase)) { $conteiner = $p.rotulo }
        }
    }
    foreach ($p in $Contexto.instalados) {
        foreach ($x in $Compactos) { if ($p.nomes -contains $x) { return @{ tipo = 'instalado'; texto = $p.rotulo; campo = 'nome' } } }
    }
    if ($null -ne $conteiner) { return @{ tipo = 'conteiner'; texto = $conteiner; campo = 'local' } }
    foreach ($p in $Contexto.instalados) {
        foreach ($x in $Compactos) { if ($p.editores -contains $x) { return @{ tipo = 'conteiner'; texto = $p.editor; campo = 'editor' } } }
    }
    foreach ($x in $Compactos) {
        if ($Contexto.extras.ContainsKey($x)) { return @{ tipo = 'extra'; texto = $Contexto.extras[$x]; campo = 'extra' } }
    }
    foreach ($p in $Contexto.instalados) {
        foreach ($x in $Compactos) { foreach ($y in $p.nomes) { if (Test-NomeParecido $x $y) { return @{ tipo = 'parecido'; texto = $p.rotulo; campo = 'nome' } } } }
    }
    foreach ($p in $Contexto.instalados) {
        foreach ($x in $Compactos) { foreach ($y in $p.editores) { if (Test-NomeParecido $x $y) { return @{ tipo = 'parecido'; texto = $p.editor; campo = 'editor' } } } }
    }
    return @{ tipo = ''; texto = ''; campo = '' }
}

function Get-ResumoRestoAntigo {
    # Uma unica passada pela pasta, sem seguir links e com teto de tempo:
    # @{ ok; recusa; bytes; temExecutavel; dadoUsuario; maisRecente }. maisRecente = maior LastWriteTime/CreationTime
    # de tudo (inclusive da pasta). dadoUsuario = nome da primeira subpasta/arquivo de jogo salvo, chave ou licenca.
    # recusa: 'link' (link/juncao na pasta ou dentro), 'leitura' (algo nao pode ser lido), 'teto' (estourou) ou
    # 'executavelRecente' (programa alterado OU criado depois de $Limite). ok = sem recusa.
    param([string]$Path, [DateTime]$Limite, [int]$TetoMs = 10000)
    $r = @{ ok = $false; recusa = 'leitura'; bytes = [int64]0; temExecutavel = $false; dadoUsuario = ''; maisRecente = [DateTime]::MinValue }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer) { return $r }
    if (Test-Reparse $item) { $r.recusa = 'link'; return $r }
    $r.maisRecente = $item.LastWriteTime
    if ($item.CreationTime -gt $r.maisRecente) { $r.maisRecente = $item.CreationTime }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($item.FullName)
    try {
        while ($pilha.Count -gt 0) {
            if ($sw.ElapsedMilliseconds -ge $TetoMs) { $r.recusa = 'teto'; return $r }
            foreach ($f in @(Get-ChildItem -LiteralPath $pilha.Pop() -Force -ErrorAction Stop)) {
                if (Test-Reparse $f) { $r.recusa = 'link'; return $r }
                $data = $f.LastWriteTime
                if ($f.CreationTime -gt $data) { $data = $f.CreationTime }
                if ($data -gt $r.maisRecente) { $r.maisRecente = $data }
                if ($f.PSIsContainer) {
                    if ($r.dadoUsuario -eq '' -and $Script:PastasDadoUsuario -contains $f.Name) { $r.dadoUsuario = $f.Name }
                    $pilha.Push($f.FullName)
                    continue
                }
                $r.bytes += [int64]$f.Length
                if ($r.dadoUsuario -eq '') {
                    foreach ($p in $Script:ArquivosDadoUsuario) { if ($f.Name -like $p) { $r.dadoUsuario = $f.Name; break } }
                }
                if ($Script:ExtensoesProgramaResto -notcontains $f.Extension.ToLowerInvariant()) { continue }
                $r.temExecutavel = $true
                if ($data -gt $Limite) { $r.recusa = 'executavelRecente'; return $r }
            }
        }
    } catch {
        $r.recusa = 'leitura'
        return $r
    }
    $r.recusa = ''
    $r.ok = $true
    return $r
}

function Add-ItemRestoAntigo {
    # Acrescenta um item ao resultado, sem repetir caminho.
    param($Itens, $Item)
    foreach ($x in $Itens) { if ([string]::Equals($x.caminho, $Item.caminho, [StringComparison]::OrdinalIgnoreCase)) { return } }
    $Itens.Add($Item)
}

function Get-AvaliacaoRestoAntigo {
    # Decide o que fazer com uma pasta: @{ acao = 'ignorar'|'descer'|'listar'; dono; item }. $DonoPai preenchido =
    # segundo nivel, dentro da pasta de um editor/conteiner com programa instalado (dali nunca desce mais).
    # $Usuario = a raiz e AppData/LocalAppData (nunca 'seguro').
    param([string]$Id, [string]$Caminho, [string]$Nome, $Contexto, [string]$DonoPai, [bool]$Usuario, [DateTime]$Limite)
    $ignorar = @{ acao = 'ignorar' }
    if (Test-NomeNuncaResto $Nome) { return $ignorar }
    if (Test-ProtectedPath $Caminho) { return $ignorar }
    if (-not (Test-CadeiaSemLink $Caminho)) { return $ignorar }
    $limpo = Get-NomeLimpo $Nome
    if ($null -ne (Get-MotivoProtegido $Nome '' '') -or $null -ne (Get-MotivoProtegido $limpo '' '')) { return $ignorar }
    $compactos = @(Get-CompactoNome $Nome)
    $principal = ConvertTo-NomeCompacto $Nome
    $rel = Get-RelacaoInstalado $Caminho $compactos $Contexto
    if ($rel.tipo -eq 'instalado') { return $ignorar }
    if ($rel.tipo -eq 'conteiner') {
        if ([string]::IsNullOrEmpty($DonoPai)) { return @{ acao = 'descer'; dono = $rel.texto } }
        return $ignorar
    }
    $resumo = Get-ResumoRestoAntigo $Caminho $Limite $Contexto.tetoPastaMs
    if (-not $resumo.ok) {
        if ($resumo.recusa -eq 'teto') { Send-Log $Id 'info' 'Pasta grande demais para conferir a tempo: ficou de fora.' $Caminho }
        return $ignorar
    }
    $seguro = $false
    if ($Contexto.erros.Count -gt 0) {
        $motivo = "Não foi possível ler $($Contexto.erros.ToArray() -join ' e '): a comparação com os programas instalados ficou incompleta."
    } elseif ($rel.tipo -eq 'parecido' -and $rel.campo -eq 'editor') {
        $motivo = "Nome parecido com o editor de um programa instalado: $($rel.texto)"
    } elseif ($rel.tipo -eq 'parecido') {
        $motivo = "Nome parecido com um programa instalado: $($rel.texto)"
    } elseif ($rel.tipo -eq 'extra') {
        $motivo = "Mesmo nome de algo que ainda está instalado: $($rel.texto)"
    } elseif ($principal.Length -lt $Script:MinCompararNome) {
        $motivo = 'Nome curto demais para comparar com os programas instalados.'
    } elseif (-not [string]::IsNullOrEmpty($DonoPai)) {
        $motivo = "Fica na pasta de $DonoPai, que ainda tem programa instalado: pode ser um componente compartilhado."
    } elseif ($resumo.dadoUsuario -ne '') {
        $motivo = "Tem dados que não voltam se forem perdidos (jogos salvos, chaves ou licenças): $($resumo.dadoUsuario)"
    } elseif ($resumo.temExecutavel) {
        $motivo = 'Tem programas ou scripts dentro: pode ser um programa portátil, sem registro de instalação.'
    } elseif ($resumo.maisRecente -gt $Limite) {
        $motivo = 'Alterada nos últimos 30 dias: pode ainda estar em uso.'
    } elseif ($Usuario) {
        $motivo = 'Dados do usuário (configurações, chaves, jogos salvos): confira antes de mover.'
    } else {
        $seguro = $true
        $motivo = 'Nenhum programa instalado tem nome ou editor parecido.'
    }
    $item = [ordered]@{
        tipo    = 'pasta'
        caminho = $Caminho
        nome    = $Nome
        bytes   = [int64]$resumo.bytes
        seguro  = $seguro
        motivo  = $motivo
    }
    return @{ acao = 'listar'; item = $item }
}

function Add-AtalhoMenu {
    # Percorre os .lnk dos Menus Iniciar. Destino valido: a pasta e o nome do destino entram como instalados no
    # $Contexto. Destino que nao existe: vira item em $Itens. Destino vazio (atalho anunciado do Windows Installer
    # ou app da Store), UNC ou em unidade de rede: ignorado (nada e acessado pela rede). So destino em disco fixo,
    # fora de pasta protegida e cuja pasta tambem sumiu pode ser 'seguro'.
    param($Contexto, [string[]]$Raizes, $Itens)
    foreach ($raiz in $Raizes) {
        if ([string]::IsNullOrWhiteSpace($raiz)) { continue }
        foreach ($lnk in @(Get-ArquivoSemLink $raiz '.lnk')) {
            if (Test-ProtectedPath $lnk.FullName) { continue }
            $alvo = Get-AlvoAtalho $lnk.FullName
            if ([string]::IsNullOrWhiteSpace($alvo) -or $alvo -notmatch '^[A-Za-z]:\\') { continue }
            $tipo = Get-TipoUnidade $alvo
            if ($tipo -eq 'rede') { continue }
            $pai = ''
            try { $pai = [string][IO.Path]::GetDirectoryName($alvo) } catch { $pai = '' }
            $seguro = $false
            if ($tipo -eq 'ausente') {
                $motivo = "O destino fica num disco que não está conectado agora ($($alvo.Substring(0, 2))): o atalho pode voltar a funcionar."
            } elseif (Test-Path -LiteralPath $alvo) {
                $locais = @($pai)
                if (Test-Path -LiteralPath $alvo -PathType Container) { $locais += $alvo }
                Add-ReferenciaInstalada $Contexto '' '' $locais "destino do atalho $($lnk.BaseName)"
                Add-ExtraResto $Contexto ([IO.Path]::GetFileNameWithoutExtension($alvo)) "destino do atalho $($lnk.BaseName)"
                continue
            } elseif ($tipo -ne 'fixa') {
                $motivo = "O destino fica num disco removível ($($alvo.Substring(0, 2))): o atalho pode voltar a funcionar com ele conectado."
            } elseif (Test-ProtectedPath $alvo) {
                $motivo = "O destino ficava numa pasta do Windows ou de componentes compartilhados: confira antes de mover ($alvo)."
            } elseif ($pai -ne '' -and (Test-Path -LiteralPath $pai -PathType Container)) {
                $motivo = "A pasta do destino ainda existe ($pai): o programa pode ter sido só atualizado ou movido."
            } else {
                $seguro = $true
                $motivo = "Atalho cujo destino não existe mais: $alvo"
            }
            Add-ItemRestoAntigo $Itens ([ordered]@{
                    tipo    = 'atalho'
                    caminho = $lnk.FullName
                    nome    = $lnk.BaseName
                    bytes   = [int64]$lnk.Length
                    seguro  = $seguro
                    motivo  = $motivo
                })
        }
    }
}

# ---------- desinstalacao ----------

function Get-PlanoDesinstalacao {
    # @{ exe; args; modo; tipo } a partir das UninstallStrings do programa. -TipoForcado so vem de simular (teste).
    param($Programa, [string]$TipoForcado = '')
    $tipo = $Programa.instalador
    if (-not [string]::IsNullOrEmpty($TipoForcado) -and $Script:TiposInstalador -contains $TipoForcado) { $tipo = $TipoForcado }
    if ($tipo -eq 'quiet' -and -not [string]::IsNullOrWhiteSpace($Programa.quietUninstallString)) {
        $s = Split-UninstallString $Programa.quietUninstallString
        return @{ exe = $s.exe; args = $s.args; modo = 'silencioso'; tipo = 'quiet' }
    }
    $s = Split-UninstallString $Programa.uninstallString
    if ($tipo -eq 'msi' -and $null -ne $s.guid -and $s.exe -ne 'msiexec.exe') {
        # WindowsInstaller=1 com bootstrapper proprio: vai direto no msiexec /X{guid}, como manda o contrato.
        return @{ exe = 'msiexec.exe'; args = (Get-ArgumentosSilenciosos 'msi' ('/X' + $s.guid)); modo = 'silencioso'; tipo = 'msi' }
    }
    if ($Script:TiposSilenciosos -contains $tipo) {
        return @{ exe = $s.exe; args = (Get-ArgumentosSilenciosos $tipo $s.args); modo = 'silencioso'; tipo = $tipo }
    }
    return @{ exe = $s.exe; args = $s.args; modo = 'assistente'; tipo = $tipo }
}

function Resolve-Desinstalador {
    # Caminho completo do executavel: 'msiexec.exe' -> System32; caminho absoluto com letra de unidade -> GetFullPath;
    # relativo, nome solto ou UNC -> $null (a UninstallString vem do registro, que o usuario consegue escrever).
    param([string]$Exe)
    if ([string]::IsNullOrWhiteSpace($Exe)) { return $null }
    if ($Exe -eq 'msiexec.exe') { return (Join-Path $env:windir 'System32\msiexec.exe') }
    if ($Exe -notmatch '^[A-Za-z]:\\') { return $null }
    try {
        if (-not [IO.Path]::IsPathRooted($Exe)) { return $null }
        return [IO.Path]::GetFullPath($Exe)
    } catch { return $null }
}

function Test-ExeSobTeste {
    # Em modo teste so roda o que estiver sob %TEMP%\NexTuneTeste\.
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $false }
    try {
        $base = [IO.Path]::GetFullPath((Join-Path $env:TEMP 'NexTuneTeste')).TrimEnd('\') + '\'
        return [IO.Path]::GetFullPath($Caminho).StartsWith($base, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Stop-ArvoreProcesso {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Processo)
    try { & (Join-Path $env:windir 'System32\taskkill.exe') /T /F /PID ([string]$Processo.Id) 2>&1 | Out-Null } catch { $null = $_ }
    try { if (-not $Processo.HasExited) { $Processo.Kill() } } catch { $null = $_ }
}

function Invoke-Desinstalador {
    # Roda exe + argumentos (lista, nunca string unica) com limite de 10 min. Devolve o codigo ou $null se estourou.
    param([string]$Exe, [string]$Argumentos, [string]$Modo)
    $opts = @{ FilePath = $Exe; PassThru = $true }
    if (-not [string]::IsNullOrWhiteSpace($Argumentos)) { $opts.ArgumentList = $Argumentos }
    if ($Modo -eq 'silencioso') { $opts.WindowStyle = 'Hidden' }
    $p = Start-Process @opts
    if ($null -eq $p) { throw 'o desinstalador não iniciou' }
    if (-not $p.WaitForExit($Script:TetoDesinstalarMs)) {
        Stop-ArvoreProcesso $p
        return $null
    }
    return [int]$p.ExitCode
}

function Remove-ProvisionamentoStore {
    # Remove o pacote provisionado (nao volta em contas novas). Falha vira aviso, nao erro.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, $Programa)
    try {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $Programa.nome -or $_.PackageName -eq $Programa.packageFullName })
        if ($prov.Count -eq 0) { Send-Log $Id 'info' "Nenhum pacote provisionado para $($Programa.nome)"; return }
        foreach ($pp in $prov) { Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null }
        Send-Log $Id 'info' "Pacote desprovisionado: $($Programa.nome)"
    } catch {
        Send-Log $Id 'aviso' ("Não foi possível desprovisionar $($Programa.nome): " + $_.Exception.Message)
    }
}

# ---------- acoes ----------

function Invoke-ListarPrograma {
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $Script:ErroStore = $null
    $lista = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($h in $Script:Hives) {
        Send-Progress $Id ([int](40 * $i / $Script:Hives.Count)) "Lendo programas instalados ($h)"
        $i++
        foreach ($p in @(Get-ProgramaClassico $h $Teste)) { $lista.Add($p) }
    }
    Send-Progress $Id 40 'Lendo apps da Store'
    foreach ($p in @(Get-ProgramaStore $Teste $sim)) { $lista.Add($p) }
    if ($null -ne $Script:ErroStore) { Send-Log $Id 'aviso' ("Não foi possível ler os apps da Store: " + $Script:ErroStore) }
    Send-Progress $Id 70 'Medindo tamanho, serviços e memória'
    Add-Enriquecimento $Id $lista $Teste
    $saida = @($lista.ToArray() | Sort-Object -Property @{ Expression = { [string]$_.nome } } | ForEach-Object { ConvertTo-ProgramaSaida $_ })
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ programas = $saida })
}

function Invoke-Desinstalar {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'desinstalar exige confirmação'; return }
    $idPrograma = ''
    if ($null -ne $Params -and $null -ne $Params.id) { $idPrograma = [string]$Params.id }
    if ([string]::IsNullOrWhiteSpace($idPrograma)) { Send-Result $Id $null $false 'id do programa não informado'; return }
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 0 'Localizando o programa'
    $prog = Get-ProgramaPorId $idPrograma $Teste $sim
    if ($null -eq $prog) { Send-Result $Id $null $false "programa não encontrado: $idPrograma"; return }
    if ($prog.protegido) {
        Write-AppLog ("programas: recusada desinstalação de programa protegido: {0} ({1})" -f $prog.nome, $idPrograma) $Teste
        Send-Result $Id $null $false "programa protegido, não pode ser desinstalado: $($prog.nome). $($prog.motivoProtegido)"
        return
    }
    $avancado = Test-ParamVerdadeiro $Params 'avancado'
    $desprovisionar = $avancado -and (Test-ParamVerdadeiro $Params 'desprovisionar')
    $modo = ''
    $codigo = $null
    Write-AppLog ("programas: desinstalando {0} ({1})" -f $prog.nome, $idPrograma) $Teste
    Send-Progress $Id 10 "Desinstalando $($prog.nome)"
    if ($prog.tipo -eq 'store') {
        $modo = 'loja'
        $codigo = 0
        if (-not $Teste) {
            Remove-AppxPackage -Package $prog.packageFullName -AllUsers -ErrorAction Stop
            if ($desprovisionar) { Remove-ProvisionamentoStore $Id $prog }
        } elseif ($desprovisionar) {
            Send-Log $Id 'info' 'modo teste: desprovisionamento simulado'
        }
    } else {
        $tipoForcado = ''
        if ($null -ne $sim -and $null -ne $sim.tipoInstalador) { $tipoForcado = [string]$sim.tipoInstalador }
        $plano = Get-PlanoDesinstalacao $prog $tipoForcado
        $exe = Resolve-Desinstalador $plano.exe
        if ([string]::IsNullOrWhiteSpace($exe)) { Send-Result $Id $null $false "o programa não informa um desinstalador válido: $($prog.nome)"; return }
        if ($Teste -and -not (Test-ExeSobTeste $exe)) {
            Send-Result $Id $null $false "em modo teste só desinstaladores sob %TEMP%\NexTuneTeste são executados: $exe"
            return
        }
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Send-Result $Id $null $false "desinstalador não encontrado: $exe"; return }
        $modo = $plano.modo
        Send-Log $Id 'info' ("Desinstalador ({0}, {1}): {2} {3}" -f $plano.tipo, $modo, $exe, $plano.args) $exe
        $codigo = Invoke-Desinstalador $exe $plano.args $modo
        if ($null -eq $codigo) { Send-Log $Id 'aviso' 'O desinstalador passou de 10 minutos e foi encerrado' $exe }
    }
    Send-Progress $Id 80 'Procurando restos'
    $ainda = ($null -ne (Get-ProgramaPorId $idPrograma $Teste $sim))
    $restos = @(Get-CandidatoResto -Nome $prog.nome -Editor $prog.editor -Local $prog.local -AindaInstalado $ainda -Teste $Teste)
    $codigoTexto = 'null'
    if ($null -ne $codigo) { $codigoTexto = [string]$codigo }
    Write-AppLog ("programas: {0} desinstalado modo={1} codigo={2} restos={3}" -f $prog.nome, $modo, $codigoTexto, $restos.Count) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ modo = $modo; codigo = $codigo; restos = $restos })
}

function Invoke-Resto {
    param([string]$Id, $Params, [bool]$Teste)
    $nome = ''
    $editor = ''
    $local = ''
    $idPrograma = ''
    if ($null -ne $Params) {
        if ($null -ne $Params.nome) { $nome = [string]$Params.nome }
        if ($null -ne $Params.editor) { $editor = [string]$Params.editor }
        if ($null -ne $Params.local) { $local = [string]$Params.local }
        if ($null -ne $Params.id) { $idPrograma = [string]$Params.id }
    }
    if ([string]::IsNullOrWhiteSpace($nome)) { Send-Result $Id $null $false 'nome do programa não informado'; return }
    $sim = Get-Simulacao $Params $Teste
    Send-Progress $Id 0 'Procurando restos'
    $ainda = ($null -ne (Get-ProgramaPorId $idPrograma $Teste $sim))
    $cands = @(Get-CandidatoResto -Nome $nome -Editor $editor -Local $local -AindaInstalado $ainda -Teste $Teste)
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ candidatos = $cands })
}

function Invoke-LimparResto {
    param([string]$Id, $Params, [bool]$Teste)
    if (-not (Test-ParamVerdadeiro $Params 'confirmado')) { Send-Result $Id $null $false 'limpar restos exige confirmação'; return }
    $itens = @()
    if ($null -ne $Params -and $null -ne $Params.itens -and $Params.itens -isnot [string]) { $itens = @($Params.itens) }
    if ($itens.Count -eq 0) { Send-Result $Id $null $false 'nenhum item informado'; return }
    if ($itens.Count -gt $Script:MaxItensRestos) { Send-Result $Id $null $false "muitos itens de uma vez (máximo $($Script:MaxItensRestos))"; return }
    $descricao = 'Restos de programa'
    if ($null -ne $Params.nome -and -not [string]::IsNullOrWhiteSpace([string]$Params.nome)) { $descricao = 'Restos de ' + ([string]$Params.nome).Trim() }

    $entrada = New-EntradaQuarentena -Modulo 'programas' -Descricao $descricao -Teste $Teste
    $movidos = 0
    $falhas = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($it in $itens) {
        Send-Progress $Id ([int](100 * $i / $itens.Count)) 'Movendo para a quarentena'
        $i++
        $tipo = ''
        $caminho = ''
        if ($null -ne $it) {
            if ($null -ne $it.tipo) { $tipo = [string]$it.tipo }
            if ($null -ne $it.caminho) { $caminho = [string]$it.caminho }
        }
        try {
            if ($Script:TiposResto -cnotcontains $tipo) { throw "tipo de item inválido: $tipo" }
            if ([string]::IsNullOrWhiteSpace($caminho)) { throw 'caminho não informado' }
            if ($tipo -eq 'chave') {
                if (-not (Test-ChaveRegistro $caminho)) { throw "chave de registro inválida: $caminho" }
                if (-not (Test-ChaveRestoPermitida $caminho)) { throw "chave não permitida como resto (só HKCU\Software e HKLM\SOFTWARE, fora das áreas do Windows): $caminho" }
                if ($Teste -and -not (Test-ChaveTeste $caminho)) { throw "em modo teste só chaves sob HKCU\Software\NexTuneTeste são aceitas: $caminho" }
                Add-ItemQuarentena -Entrada $entrada -Caminho $caminho -Tipo 'chave' | Out-Null
            } else {
                if ($caminho -notmatch '^[A-Za-z]:\\.') { throw "caminho inválido: $caminho" }
                if (Test-ProtectedPath $caminho) { throw "caminho protegido, não vai para a quarentena: $caminho" }
                if ($tipo -eq 'atalho' -and [IO.Path]::GetExtension($caminho) -ne '.lnk') { throw "atalho inválido (não é .lnk): $caminho" }
                Add-ItemQuarentena -Entrada $entrada -Caminho $caminho -Tipo $tipo | Out-Null
            }
            $movidos++
        } catch {
            $falhas.Add([ordered]@{ caminho = $caminho; erro = $_.Exception.Message })
            Send-Log $Id 'aviso' ('Item não movido: ' + $_.Exception.Message) $caminho
        }
    }
    $fechada = Complete-EntradaQuarentena -Entrada $entrada
    $quarentenaId = $null
    if ($null -ne $fechada) { $quarentenaId = $fechada.id }
    Write-AppLog ("programas: restos para a quarentena: {0} movidos, {1} falhas, entrada {2}" -f $movidos, $falhas.Count, $quarentenaId) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ quarentenaId = $quarentenaId; movidos = $movidos; falhas = $falhas.ToArray() })
}

function Invoke-RestoAntigo {
    # Restos de programas ja desinstalados (so leitura). Limpar e com limparRestos (vai para a quarentena).
    # Resultado: { itens: [{tipo, caminho, nome, bytes, seguro, motivo}], incompleto }. incompleto = o teto total
    # (120 s) estourou e as pastas restantes nao foram conferidas. simular (so teste): store, erroStore, servicos,
    # tetoPastaMs, tetoTotalMs.
    param([string]$Id, $Params, [bool]$Teste)
    $sim = Get-Simulacao $Params $Teste
    $Script:ErroStore = $null
    $Script:TiposUnidade = @{}
    $tetoPasta = $Script:TetoTamanhoMs
    $tetoTotal = $Script:TetoTotalRestoMs
    if ($null -ne $sim) {
        if ($null -ne $sim.tetoPastaMs) { $tetoPasta = [int]$sim.tetoPastaMs }
        if ($null -ne $sim.tetoTotalMs) { $tetoTotal = [int]$sim.tetoTotalMs }
    }
    $relogio = [Diagnostics.Stopwatch]::StartNew()
    Send-Progress $Id 0 'Conferindo as pastas de busca'
    $def = Get-RaizRestoAntigo $Teste
    $raizes = New-Object System.Collections.Generic.List[object]
    foreach ($r in $def.pastas) {
        $c = Get-RaizValida $Id ([string]$r.caminho)
        if ($c -eq '') { continue }
        $repetida = $false
        foreach ($x in $raizes) { if ([string]::Equals($x.caminho, $c, [StringComparison]::OrdinalIgnoreCase)) { $repetida = $true; break } }
        if (-not $repetida) { $raizes.Add(@{ caminho = $c; usuario = [bool]$r.usuario }) }
    }
    $raizesAtalho = New-Object System.Collections.Generic.List[string]
    foreach ($a in $def.atalhos) {
        $c = Get-RaizValida $Id ([string]$a)
        if ($c -ne '' -and -not $raizesAtalho.Contains($c)) { $raizesAtalho.Add($c) }
    }
    $ctx = @{
        instalados  = New-Object System.Collections.Generic.List[object]
        extras      = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        raizes      = @(foreach ($x in $raizes) { $x.caminho })
        erros       = New-Object System.Collections.Generic.List[string]
        tetoPastaMs = $tetoPasta
    }
    Send-Progress $Id 5 'Lendo programas instalados e serviços'
    Get-ReferenciaInstalada $ctx $Teste $sim
    if ($null -ne $Script:ErroStore) {
        Send-Log $Id 'aviso' ("Não foi possível ler os apps da Store: " + $Script:ErroStore)
        $ctx.erros.Add('os apps da Store')
    }
    if ($ctx.erros.Contains('os serviços do Windows')) { Send-Log $Id 'aviso' 'Não foi possível ler os serviços do Windows.' }
    Send-Progress $Id 15 'Conferindo os atalhos do Menu Iniciar'
    $atalhos = New-Object System.Collections.Generic.List[object]
    Add-AtalhoMenu $ctx $raizesAtalho.ToArray() $atalhos

    # Primeiro nivel de todas as raizes (para o progresso por pasta).
    $fila = New-Object System.Collections.Generic.List[object]
    foreach ($r in $raizes) {
        foreach ($d in @(Get-ChildItem -LiteralPath $r.caminho -Directory -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
            $fila.Add(@{ dir = $d; usuario = $r.usuario })
        }
    }
    $limite = (Get-Date).AddDays(-$Script:DiasResto)
    $itens = New-Object System.Collections.Generic.List[object]
    $incompleto = $false
    $n = [math]::Max(1, $fila.Count)
    $i = 0
    foreach ($e in $fila) {
        if ($relogio.ElapsedMilliseconds -ge $tetoTotal) { $incompleto = $true; break }
        Send-Progress $Id (20 + [int](75 * $i / $n)) "Conferindo $($e.dir.FullName)"
        $i++
        $a = Get-AvaliacaoRestoAntigo $Id $e.dir.FullName $e.dir.Name $ctx '' $e.usuario $limite
        if ($a.acao -eq 'listar') { Add-ItemRestoAntigo $itens $a.item; continue }
        if ($a.acao -ne 'descer') { continue }
        # pasta de um editor (ou que guarda um programa) ainda instalado: olha so o segundo nivel, nunca o terceiro
        foreach ($f in @(Get-ChildItem -LiteralPath $e.dir.FullName -Directory -Force -ErrorAction SilentlyContinue | Sort-Object -Property Name)) {
            if ($relogio.ElapsedMilliseconds -ge $tetoTotal) { $incompleto = $true; break }
            Send-Progress $Id (20 + [int](75 * ($i - 1) / $n)) "Conferindo $($f.FullName)"
            $b = Get-AvaliacaoRestoAntigo $Id $f.FullName $f.Name $ctx $a.dono $e.usuario $limite
            if ($b.acao -eq 'listar') { Add-ItemRestoAntigo $itens $b.item }
        }
        if ($incompleto) { break }
    }
    if ($incompleto) { Send-Log $Id 'aviso' 'A busca passou do tempo máximo e parou: algumas pastas não foram conferidas.' }
    foreach ($x in $atalhos) { Add-ItemRestoAntigo $itens $x }
    $pastas = 0
    $seguros = 0
    foreach ($x in $itens) {
        if ($x.tipo -eq 'pasta') { $pastas++ }
        if ($x.seguro) { $seguros++ }
    }
    Write-AppLog ("programas: restos antigos: {0} pastas, {1} atalhos, {2} seguros, incompleto={3}" -f $pastas, ($itens.Count - $pastas), $seguros, $incompleto) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ itens = $itens.ToArray(); incompleto = $incompleto })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if (@('listar', 'desinstalar', 'restos', 'limparRestos', 'restosAntigos') -cnotcontains $Acao) {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        switch ($Acao) {
            'listar' { Invoke-ListarPrograma $Id $Params $Teste }
            'desinstalar' { Invoke-Desinstalar $Id $Params $Teste }
            'restos' { Invoke-Resto $Id $Params $Teste }
            'limparRestos' { Invoke-LimparResto $Id $Params $Teste }
            'restosAntigos' { Invoke-RestoAntigo $Id $Params $Teste }
        }
    } catch {
        $msg = 'programas falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
