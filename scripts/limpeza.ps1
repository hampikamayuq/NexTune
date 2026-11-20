# limpeza.ps1 - limpeza de lixo por categoria, ciente do perfil da maquina.
# Acoes: analisar {avancado?}, limpar {categorias, confirmado?, avancado?, resetBase?}.
# So apaga o CONTEUDO de caches/temporarios (nunca a pasta raiz da categoria, nunca documentos).
# Caminhos portados do limpieza.ps1 do RetroLimpia (MIT).
. "$PSScriptRoot\common.ps1"

$Script:Categorias = @(
    @{ id = 'temp_usuario';     cor = 'verde' },
    @{ id = 'temp_windows';     cor = 'verde' },
    @{ id = 'wu_cache';         cor = 'verde' },
    @{ id = 'entrega';          cor = 'verde' },
    @{ id = 'informes';         cor = 'verde' },
    @{ id = 'miniaturas';       cor = 'verde' },
    @{ id = 'launchers';        cor = 'verde' },
    @{ id = 'navegadores';      cor = 'amarelo' },
    @{ id = 'minidumps';        cor = 'amarelo' },
    @{ id = 'lixeira';          cor = 'amarelo' },
    @{ id = 'shaders';          cor = 'amarelo' },
    @{ id = 'dism_componentes'; cor = 'amarelo' },
    @{ id = 'windows_old';      cor = 'amarelo' },
    @{ id = 'pontos_antigos';   cor = 'amarelo' }
)
$Script:CategoriasDuplas = @('windows_old', 'pontos_antigos')
$Script:MaxAvisos = 20
$Script:AvisosEmitidos = 0
$Script:FalhasCat = $null   # mensagens de falha da categoria em curso (Invoke-Limpar)

function Test-ParamVerdadeiro {
    # Somente o booleano $true vale (a string 'true' NAO vale).
    param($Params, [string]$Nome)
    if ($null -eq $Params) { return $false }
    $v = $Params.$Nome
    return ($v -is [bool] -and $v -eq $true)
}

function Test-RaizSegura {
    # Recusa raizes que nunca devem ser esvaziadas (vazias, relativas, rasas ou de sistema).
    param([string]$Raiz)
    if ([string]::IsNullOrWhiteSpace($Raiz)) { return $false }
    if ($Raiz -notmatch '^[A-Za-z]:\\[^\\]+') { return $false }
    try { $n = [IO.Path]::GetFullPath($Raiz).TrimEnd('\').ToLowerInvariant() } catch { return $false }
    if ($n.Length -le 3) { return $false }   # normalizou para a raiz da unidade
    $partes = @($n.Substring(3) -split '\\' | Where-Object { $_ -ne '' })
    if ($partes.Count -lt 2) { return $false }
    foreach ($p in @($env:SystemDrive, $env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrEmpty($p)) { continue }
        if ($n -eq $p.TrimEnd('\').ToLowerInvariant()) { return $false }
    }
    return $true
}

function Test-CadeiaSemLink {
    # $true se a rota e cada pasta acima dela (que exista) nao forem junction, link simbolico ou
    # ponto de montagem. GetFullPath nao resolve junctions; por isso a subida item a item.
    param([string]$Caminho)
    try {
        $atual = [IO.Path]::GetFullPath($Caminho)
        while (-not [string]::IsNullOrEmpty($atual)) {
            if (Test-Path -LiteralPath $atual) {
                if (Test-Reparse (Get-Item -LiteralPath $atual -Force -ErrorAction Stop)) { return $false }
            }
            $pai = [IO.Path]::GetDirectoryName($atual)
            if ($pai -eq $atual) { break }
            $atual = $pai
        }
        return $true
    } catch { return $false }
}

function Test-DonoRaiz {
    # Sob %ProgramData% qualquer usuario cria pastas: ali a raiz e as pastas entre ela e a base
    # precisam ter dono SYSTEM, Administradores ou TrustedInstaller.
    param([string]$Caminho, [string]$Base = $env:ProgramData)
    try {
        $b = [IO.Path]::GetFullPath($Base).TrimEnd('\')
        $atual = [IO.Path]::GetFullPath($Caminho).TrimEnd('\')
        if (-not $atual.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        while ($atual.Length -gt $b.Length) {
            if ((Test-Path -LiteralPath $atual) -and -not (Test-SidConfiavel (Get-DonoSid $atual))) { return $false }
            $atual = [IO.Path]::GetDirectoryName($atual)
        }
        return $true
    } catch { return $false }
}

function Get-CorteIdade {
    # So entram itens com LastWriteTime anterior ao corte (mesma regra da Limpeza de Disco do Windows).
    param([string]$Id)
    switch ($Id) {
        'temp_usuario' { return (Get-Date).AddHours(-24) }
        'temp_windows' { return (Get-Date).AddDays(-7) }
        default { return [DateTime]::MaxValue }
    }
}

function Add-FalhaRaiz {
    param([string]$Id, [string]$Msg, [string]$Raiz)
    Send-Log $Id 'aviso' $Msg $Raiz
    if ($null -ne $Script:FalhasCat) { $Script:FalhasCat.Add($Msg) }
}

function Get-DirNavegador {
    $dirs = New-Object System.Collections.Generic.List[string]
    $bases = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    )
    foreach ($b in $bases) {
        if (-not (Test-Path -LiteralPath $b)) { continue }
        foreach ($perfil in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($c in @('Cache\Cache_Data', 'Code Cache', 'GPUCache')) {
                $d = Join-Path $perfil.FullName $c
                if (Test-Path -LiteralPath $d) { $dirs.Add($d) }
            }
        }
    }
    $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path -LiteralPath $ff) {
        foreach ($perfil in @(Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue)) {
            $d = Join-Path $perfil.FullName 'cache2'
            if (Test-Path -LiteralPath $d) { $dirs.Add($d) }
        }
    }
    return $dirs.ToArray()
}

function Get-DirLauncher {
    # Somente caches puros; nunca jogos, partidas ou sessoes.
    $l = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(
            "$env:LOCALAPPDATA\Steam\htmlcache\Cache", "$env:LOCALAPPDATA\Steam\htmlcache\Code Cache", "$env:LOCALAPPDATA\Steam\htmlcache\GPUCache",
            "$env:LOCALAPPDATA\Battle.net\Cache",
            "$env:APPDATA\discord\Cache", "$env:APPDATA\discord\Code Cache", "$env:APPDATA\discord\GPUCache")) { $l.Add($c) }
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { $null = $_ }
    if (-not [string]::IsNullOrEmpty($steam)) { $l.Add((Join-Path ($steam -replace '/', '\') 'appcache\httpcache')) }
    return @($l | Where-Object { Test-Path -LiteralPath $_ })
}

function Get-RotasCategoria {
    # Rotas (pastas/arquivos) de uma categoria. Em teste: uma pasta por categoria sob %TEMP%.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([string]$Id, [bool]$Teste)
    if ($Teste) { return @(Join-Path $env:TEMP "NexTuneTeste\limpeza\$Id") }
    switch ($Id) {
        'temp_usuario' { return @($env:TEMP) }
        'temp_windows' { return @("$env:windir\Temp") }
        'wu_cache' { return @("$env:windir\SoftwareDistribution\Download") }
        'entrega' { return @("$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") }
        'informes' { return @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:LOCALAPPDATA\CrashDumps") }
        'miniaturas' { return @("$env:LOCALAPPDATA\Microsoft\Windows\Explorer") }
        'launchers' { return @(Get-DirLauncher) }
        'navegadores' { return @(Get-DirNavegador) }
        'minidumps' { return @("$env:windir\Minidump", "$env:windir\MEMORY.DMP") }
        'shaders' {
            return @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache",
                "$env:ProgramData\NVIDIA Corporation\NV_Cache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache",
                "$env:LOCALAPPDATA\AMD\GLCache", "$env:LOCALAPPDATA\AMD\VkCache", "$env:LOCALAPPDATA\Intel\ShaderCache")
        }
        default { return @() }
    }
}

function Get-FiltroCategoria {
    param([string]$Id, [bool]$Teste)
    if (-not $Teste -and $Id -eq 'miniaturas') { return 'thumbcache_*.db' }
    return ''
}

function Get-TamanhoRaiz {
    # Mede so o que a limpeza apagaria: raiz atras de junction conta 0, e vale o corte de idade.
    param([string]$Raiz, [string]$Filtro, [DateTime]$AntesDe = [DateTime]::MaxValue)
    if (-not (Test-Path -LiteralPath $Raiz) -or -not (Test-CadeiaSemLink $Raiz)) { return [int64]0 }
    if ([string]::IsNullOrEmpty($Filtro)) { return (Get-PathSize $Raiz $AntesDe) }
    if (-not (Test-Path -LiteralPath $Raiz -PathType Container)) { return [int64]0 }
    $t = [int64]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Raiz -Filter $Filtro -File -Force -ErrorAction SilentlyContinue)) {
        if (-not (Test-Reparse $f) -and $f.LastWriteTime -lt $AntesDe) { $t += $f.Length }
    }
    return $t
}

function Get-TamanhoLixeira {
    try {
        $sh = New-Object -ComObject Shell.Application
        $soma = [int64]0
        foreach ($i in $sh.NameSpace(10).Items()) { $soma += [int64]$i.Size }
        return $soma
    } catch { return [int64]0 }
}

function Get-TamanhoCategoria {
    param([string]$Id, [bool]$Teste)
    if ($Id -eq 'lixeira') { if ($Teste) { return [int64]0 } else { return (Get-TamanhoLixeira) } }
    if ($Id -eq 'dism_componentes') { return [int64]-1 }
    if ($Id -eq 'pontos_antigos') { if ($Teste) { return [int64]0 } else { return [int64]-1 } }
    if ($Id -eq 'windows_old') {
        if ($Teste) { return [int64]0 }
        return (Get-PathSize (Join-Path $env:SystemDrive 'Windows.old'))
    }
    $filtro = Get-FiltroCategoria $Id $Teste
    $corte = Get-CorteIdade $Id
    $total = [int64]0
    foreach ($r in @(Get-RotasCategoria $Id $Teste)) { $total += (Get-TamanhoRaiz $r $filtro $corte) }
    return $total
}

function Get-Disponibilidade {
    # Devolve @{ disponivel; motivo }. Perfil ausente = basico/hdd (conservador).
    param([string]$Id, $Params, [bool]$Teste)
    $ok = @{ disponivel = $true; motivo = '' }
    switch ($Id) {
        'shaders' {
            $perfil = Get-Perfil $Teste
            $classe = 'basico'
            if ($null -ne $perfil) { $classe = $perfil.classe }
            if ($classe -eq 'gamer' -or (Test-ParamVerdadeiro $Params 'avancado')) { return $ok }
            return @{ disponivel = $false; motivo = 'Oferecida apenas para máquinas gamer ou no modo avançado.' }
        }
        'pontos_antigos' {
            if (Test-ParamVerdadeiro $Params 'avancado') { return $ok }
            return @{ disponivel = $false; motivo = 'Disponível apenas no modo avançado.' }
        }
        'windows_old' {
            if ($Teste) {
                if (Test-ParamVerdadeiro $Params 'simularWindowsOld') { return $ok }
                return @{ disponivel = $false; motivo = 'Não há pasta Windows.old neste computador.' }
            }
            $wo = Join-Path $env:SystemDrive 'Windows.old'
            $item = Get-Item -LiteralPath $wo -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) { return @{ disponivel = $false; motivo = 'Não há pasta Windows.old neste computador.' } }
            if ($item.CreationTime -gt (Get-Date).AddDays(-10)) {
                return @{ disponivel = $false; motivo = 'A pasta Windows.old tem menos de 10 dias; mantenha-a para poder voltar à versão anterior.' }
            }
            return $ok
        }
        default { return $ok }
    }
}

function Write-AvisoPulado {
    param([string]$Id, [string]$Caminho)
    if ($Script:AvisosEmitidos -lt $Script:MaxAvisos) {
        Send-Log $Id 'aviso' 'Arquivo em uso ou protegido, pulado' $Caminho
    }
    $Script:AvisosEmitidos++
}

function Clear-Conteudo {
    # Apaga o conteudo de uma pasta (nao a propria pasta). Junctions/links nao sao seguidos nem apagados.
    # Itens com LastWriteTime >= $AntesDe ficam. Devolve a quantidade de itens pulados.
    param([string]$Id, [string]$Pasta, [string]$Filtro = '', [DateTime]$AntesDe = [DateTime]::MaxValue)
    $pulados = 0
    $filhos = @()
    try {
        if ([string]::IsNullOrEmpty($Filtro)) { $filhos = @(Get-ChildItem -LiteralPath $Pasta -Force -ErrorAction Stop) }
        else { $filhos = @(Get-ChildItem -LiteralPath $Pasta -Filter $Filtro -File -Force -ErrorAction Stop) }
    } catch { return 0 }
    foreach ($f in $filhos) {
        if (Test-Reparse $f) { continue }
        if ($f.PSIsContainer) {
            # Reconfere logo antes de entrar: a pasta pode ter virado junction depois da listagem.
            $agora = Get-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if ($null -eq $agora -or (Test-Reparse $agora)) { continue }
            $velha = $agora.LastWriteTime -lt $AntesDe
            $pulados += Clear-Conteudo $Id $f.FullName '' $AntesDe
            $resta = @(Get-ChildItem -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue).Count
            if ($resta -eq 0 -and $velha) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { $null = $_ }
            }
        } else {
            if ($f.LastWriteTime -ge $AntesDe) { continue }
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            catch { $pulados++; Write-AvisoPulado $Id $f.FullName }
        }
    }
    return $pulados
}

function Clear-Raiz {
    # Esvazia uma raiz de categoria (ou apaga o arquivo, se a rota for um arquivo). Devolve pulados.
    # Raiz recusada vai para as falhas da categoria (Add-FalhaRaiz), nunca para os pulados.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Id, [string]$Raiz, [string]$Filtro, [DateTime]$AntesDe = [DateTime]::MaxValue)
    if (-not (Test-RaizSegura $Raiz)) {
        Add-FalhaRaiz $Id "pasta recusada por segurança: $Raiz" $Raiz
        return 0
    }
    if (-not (Test-Path -LiteralPath $Raiz)) { return 0 }
    if (-not (Test-CadeiaSemLink $Raiz)) {
        Add-FalhaRaiz $Id "pasta deixada intacta por segurança (é ou está dentro de um link/junção): $Raiz" $Raiz
        return 0
    }
    if (-not (Test-DonoRaiz $Raiz)) {
        Add-FalhaRaiz $Id "pasta deixada intacta por segurança (o dono não é o sistema): $Raiz" $Raiz
        return 0
    }
    if (Test-Path -LiteralPath $Raiz -PathType Leaf) {
        if ((Get-Item -LiteralPath $Raiz -Force).LastWriteTime -ge $AntesDe) { return 0 }
        try { Remove-Item -LiteralPath $Raiz -Force -ErrorAction Stop; return 0 }
        catch { Write-AvisoPulado $Id $Raiz; return 1 }
    }
    return (Clear-Conteudo $Id $Raiz $Filtro $AntesDe)
}

function Invoke-LimparPasta {
    param([string]$Id, [bool]$Teste)
    $filtro = Get-FiltroCategoria $Id $Teste
    $corte = Get-CorteIdade $Id
    $pulados = 0
    foreach ($r in @(Get-RotasCategoria $Id $Teste)) { $pulados += (Clear-Raiz $Id $r $filtro $corte) }
    return $pulados
}

function Invoke-LimparCacheAtualizacao {
    param([string]$Id, [bool]$Teste)
    if ($Teste) { return (Invoke-LimparPasta $Id $Teste) }
    $parados = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($s in @('wuauserv', 'bits')) {
            $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
            if ($null -ne $svc -and $svc.Status -eq 'Running') {
                try { Stop-Service -Name $s -Force -ErrorAction Stop; $parados.Add($s) } catch { $null = $_ }
            }
        }
        return (Invoke-LimparPasta $Id $Teste)
    } finally {
        foreach ($s in $parados) { try { Start-Service -Name $s -ErrorAction Stop } catch { $null = $_ } }
    }
}

function Invoke-LimparEntrega {
    param([string]$Id, [bool]$Teste)
    if (-not $Teste -and $null -ne (Get-Command 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)) {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop; return 0 } catch { $null = $_ }
    }
    return (Invoke-LimparPasta $Id $Teste)
}

function Invoke-LimparLixeira {
    param([bool]$Teste)
    if ($Teste) { return 0 }
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch { $null = $_ }
    return 0
}

function Invoke-LimparDism {
    param($Params, [bool]$Teste)
    if ($Teste) { return 0 }
    $args1 = '/Online /Cleanup-Image /StartComponentCleanup'
    if ((Test-ParamVerdadeiro $Params 'avancado') -and (Test-ParamVerdadeiro $Params 'resetBase')) { $args1 += ' /ResetBase' }
    $p = Start-Process -FilePath "$env:windir\System32\Dism.exe" -ArgumentList $args1 -Wait -WindowStyle Hidden -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "DISM terminou com código $($p.ExitCode)" }
    return 0
}

function Invoke-CleanmgrSomente {
    # Roda o cleanmgr /sagerun apenas para UM handler: remove StateFlags<Flag> dos demais
    # (guardando os valores), define so no handler pedido e restaura tudo no final.
    param([string]$Handler, [int]$Flag, [string]$Base, [bool]$Teste)
    $nome = 'StateFlags{0:D4}' -f $Flag
    $guardados = @{}
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath $Base -ErrorAction Stop)) {
            if ($k.PSChildName -eq $Handler) { continue }
            $v = (Get-ItemProperty -LiteralPath $k.PSPath -Name $nome -ErrorAction SilentlyContinue).$nome
            if ($null -ne $v) {
                $guardados[$k.PSPath] = $v
                Remove-ItemProperty -LiteralPath $k.PSPath -Name $nome -ErrorAction Stop
            }
        }
        Set-ItemProperty -LiteralPath (Join-Path $Base $Handler) -Name $nome -Value 2 -Type DWord -ErrorAction Stop
        if (-not $Teste) {
            Start-Process -FilePath "$env:windir\System32\cleanmgr.exe" -ArgumentList "/sagerun:$Flag" -Wait -WindowStyle Hidden
        }
    } finally {
        Remove-ItemProperty -LiteralPath (Join-Path $Base $Handler) -Name $nome -ErrorAction SilentlyContinue
        foreach ($p in $guardados.Keys) {
            Set-ItemProperty -LiteralPath $p -Name $nome -Value $guardados[$p] -Type DWord -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LimparWindowsOld {
    param([bool]$Teste)
    if ($Teste) { return 0 }
    Invoke-CleanmgrSomente 'Previous Installations' 99 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches' $false
    return 0
}

function Get-SombraParaApagar {
    # Puro: de todas as sombras, so as do volume do sistema (e acessiveis ao cliente);
    # devolve os GUIDs de todas menos a mais recente DESSE conjunto.
    param($Sombras, [string]$VolumeId)
    $meu = @($Sombras | Where-Object { $_.VolumeName -eq $VolumeId -and $_.ClientAccessible -eq $true } | Sort-Object InstallDate -Descending)
    return @($meu | Select-Object -Skip 1 | ForEach-Object { [string]$_.ID })
}

function Invoke-LimparPonto {
    # Apaga os pontos de restauracao do volume do sistema exceto o mais recente.
    # Lista via CIM (independe do idioma do Windows); apaga via vssadmin.
    param([bool]$Teste)
    if ($Teste) { return 0 }
    $vol = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $vol -or [string]::IsNullOrEmpty([string]$vol.DeviceID)) { throw 'volume do sistema não identificado' }
    $copias = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop)
    $pulados = 0
    foreach ($guid in @(Get-SombraParaApagar $copias ([string]$vol.DeviceID))) {
        if ($guid -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { $pulados++; continue }
        & "$env:windir\System32\vssadmin.exe" delete shadows "/Shadow=$guid" /Quiet | Out-Null
        if ($LASTEXITCODE -ne 0) { $pulados++ }
    }
    return $pulados
}
function Invoke-LimparCategoria {
    # Executa a limpeza de UMA categoria; devolve pulados.
    param([string]$Id, $Params, [bool]$Teste)
    switch ($Id) {
        'wu_cache' { return (Invoke-LimparCacheAtualizacao $Id $Teste) }
        'entrega' { return (Invoke-LimparEntrega $Id $Teste) }
        'lixeira' { return (Invoke-LimparLixeira $Teste) }
        'dism_componentes' { return (Invoke-LimparDism $Params $Teste) }
        'windows_old' { return (Invoke-LimparWindowsOld $Teste) }
        'pontos_antigos' { return (Invoke-LimparPonto $Teste) }
        default { return (Invoke-LimparPasta $Id $Teste) }
    }
}

function Invoke-Analisar {
    param([string]$Id, $Params, [bool]$Teste)
    $lista = New-Object System.Collections.Generic.List[object]
    $n = $Script:Categorias.Count
    $i = 0
    foreach ($c in $Script:Categorias) {
        Send-Progress $Id ([int](100 * $i / $n)) ("Analisando " + $c.id)
        $disp = Get-Disponibilidade $c.id $Params $Teste
        $tam = [int64]0
        if ($disp.disponivel) { $tam = Get-TamanhoCategoria $c.id $Teste }
        $lista.Add([ordered]@{
            id                 = $c.id
            cor                = $c.cor
            tamanhoBytes       = $tam
            disponivel         = [bool]$disp.disponivel
            motivoIndisponivel = [string]$disp.motivo
            confirmacaoDupla   = ($Script:CategoriasDuplas -contains $c.id)
            avancado           = ($c.id -eq 'pontos_antigos')
        })
        $i++
    }
    Send-Result $Id ([ordered]@{ categorias = $lista.ToArray() })
}

function Invoke-Limpar {
    param([string]$Id, $Params, [bool]$Teste)
    $cats = @()
    if ($null -ne $Params -and $null -ne $Params.categorias) { $cats = @($Params.categorias) }
    if ($cats.Count -eq 0) { Send-Result $Id $null $false 'nenhuma categoria informada'; return }

    $validos = @($Script:Categorias | ForEach-Object { $_.id })
    foreach ($c in $cats) {
        if ($c -isnot [string] -or $validos -cnotcontains $c) { Send-Result $Id $null $false "categoria desconhecida: $c"; return }
    }
    if (@($cats | Select-Object -Unique).Count -ne $cats.Count) { Send-Result $Id $null $false 'categoria repetida'; return }
    foreach ($c in $cats) {
        if ($Script:CategoriasDuplas -contains $c -and -not (Test-ParamVerdadeiro $Params 'confirmado')) {
            Send-Result $Id $null $false "categoria $c exige confirmação"; return
        }
    }
    foreach ($c in $cats) {
        $d = Get-Disponibilidade $c $Params $Teste
        if (-not $d.disponivel) { Send-Result $Id $null $false "categoria indisponível: $c. $($d.motivo)"; return }
    }

    $Script:AvisosEmitidos = 0
    $detalhes = New-Object System.Collections.Generic.List[object]
    $falhas = New-Object System.Collections.Generic.List[object]
    $somaAntes = [int64]0
    $somaDepois = [int64]0
    $totalPulados = 0
    $i = 0
    foreach ($c in $cats) {
        Send-Progress $Id ([int](100 * $i / $cats.Count)) "Limpando $c"
        $antes = [int64]0
        $depois = [int64]0
        $pulados = 0
        $Script:FalhasCat = New-Object System.Collections.Generic.List[string]
        if ($c -ne 'dism_componentes' -and $c -ne 'windows_old' -and $c -ne 'pontos_antigos') { $antes = Get-TamanhoCategoria $c $Teste }
        elseif ($c -eq 'windows_old' -and -not $Teste) { $antes = Get-TamanhoCategoria $c $Teste }
        try {
            $pulados = Invoke-LimparCategoria $c $Params $Teste
        } catch {
            $Script:FalhasCat.Add($_.Exception.Message)
        }
        $erro = $null
        if ($Script:FalhasCat.Count -gt 0) {
            $erro = ($Script:FalhasCat.ToArray() -join '; ')
            Send-Log $Id 'aviso' ("Falha em ${c}: " + $erro)
            $falhas.Add([ordered]@{ id = $c; erro = $erro })
        }
        $Script:FalhasCat = $null
        if ($c -ne 'dism_componentes' -and $c -ne 'pontos_antigos') { $depois = Get-TamanhoCategoria $c $Teste }
        $somaAntes += $antes
        $somaDepois += $depois
        $totalPulados += $pulados
        $detalhes.Add([ordered]@{ id = $c; antes = $antes; depois = $depois; pulados = $pulados; erro = $erro })
        $i++
    }
    if ($Script:AvisosEmitidos -gt $Script:MaxAvisos) {
        Send-Log $Id 'aviso' ("{0} arquivos pulados no total (mostrados os primeiros {1})" -f $Script:AvisosEmitidos, $Script:MaxAvisos)
    }
    $liberado = [math]::Max([int64]0, $somaAntes - $somaDepois)
    Write-AppLog ("limpeza: liberado {0} bytes, {1} pulados, {2} falhas" -f $liberado, $totalPulados, $falhas.Count) $Teste
    Send-Progress $Id 100 'Concluído'
    Send-Result $Id ([ordered]@{ liberadoBytes = $liberado; pulados = $totalPulados; falhas = $falhas.ToArray(); detalhes = $detalhes.ToArray() })
}

function Invoke-Acao {
    param([string]$Id, [string]$Acao, $Params, [bool]$Teste)
    if ($Acao -ne 'analisar' -and $Acao -ne 'limpar') {
        Send-Result $Id $null $false 'ação desconhecida'
        return
    }
    try {
        if ($Acao -eq 'analisar') { Invoke-Analisar $Id $Params $Teste }
        else { Invoke-Limpar $Id $Params $Teste }
    } catch {
        $msg = 'limpeza falhou: ' + $_.Exception.Message
        Write-AppLog $msg $Teste
        Send-Result $Id $null $false $msg
    }
}
