# common.ps1 - funcoes compartilhadas (protocolo, pastas, perfil, caminhos protegidos).
# Uso nos modulos: . "$PSScriptRoot\common.ps1"
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $null = $_ }
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

Set-Variable -Name AppNome -Value 'NexTune' -Scope Global
$Script:Saida = $null

function Set-Saida {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    # Define o escritor do protocolo ($null = volta ao console).
    param($Writer)
    $Script:Saida = $Writer
}

function Write-Linha {
    param([string]$Linha)
    if ($null -ne $Script:Saida) { $Script:Saida.WriteLine($Linha) }
    else { [Console]::Out.WriteLine($Linha) }
}

$Script:SidsConfiaveis = @(
    'S-1-5-18',                                                       # SYSTEM
    'S-1-5-32-544',                                                   # BUILTIN\Administradores
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'  # TrustedInstaller
)
$Script:BaseVerificada = $false

function Test-SidConfiavel {
    # Puro: o dono informado e SYSTEM, Administradores ou TrustedInstaller?
    param([string]$Sid)
    return ($Script:SidsConfiaveis -contains $Sid)
}

function Get-DonoSid {
    # SID do dono de um arquivo/pasta ou $null se nao der para ler.
    param([string]$Path)
    try { return (Get-Acl -LiteralPath $Path -ErrorAction Stop).GetOwner([Security.Principal.SecurityIdentifier]).Value }
    catch { return $null }
}

function New-SegurancaPastaApp {
    # DACL protegida da pasta de dados: SYSTEM e Administradores com controle total, Usuarios so leitura.
    # So monta o objeto; quem aplica e Set-SegurancaPastaApp.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param()
    $sec = New-Object System.Security.AccessControl.DirectorySecurity
    $heranca = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $prop = [Security.AccessControl.PropagationFlags]::None
    $permitir = [Security.AccessControl.AccessControlType]::Allow
    $sistema = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $usuarios = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'
    $sec.SetOwner($admins)
    $sec.SetAccessRuleProtection($true, $false)
    $total = [Security.AccessControl.FileSystemRights]::FullControl
    $leitura = [Security.AccessControl.FileSystemRights]::ReadAndExecute
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sistema, $total, $heranca, $prop, $permitir)))
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($admins, $total, $heranca, $prop, $permitir)))
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($usuarios, $leitura, $heranca, $prop, $permitir)))
    return $sec
}

function Set-SegurancaPastaApp {
    # Cria a pasta com a DACL protegida ou reaplica dono + DACL numa pasta existente.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Path)
    $sec = New-SegurancaPastaApp
    if (-not (Test-Path -LiteralPath $Path)) { $null = [IO.Directory]::CreateDirectory($Path, $sec); return }
    [IO.Directory]::SetAccessControl($Path, $sec)
}

function Add-LinhaLog {
    param([string]$PastaLogs, [string]$Msg)
    $arq = Join-Path $PastaLogs ((Get-Date).ToString('yyyy-MM') + '.log')
    $linha = '{0} {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Msg
    try { Add-Content -LiteralPath $arq -Value $linha -Encoding UTF8 } catch { $null = $_ }
}

function Get-AppPastas {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param([bool]$Teste = $false)
    $aviso = $null
    $base = if ($Teste) { Join-Path $env:TEMP 'NexTuneTeste' } else { Join-Path $env:ProgramData 'NexTune' }
    # Qualquer usuario cria pastas em %ProgramData%: se a nossa ja existe como junction/link, nada aqui e
    # confiavel (Get-Acl e a propria limpeza seguiriam o link). Recusa em vez de "corrigir".
    if ((Test-Path -LiteralPath $base) -and (Test-Reparse (Get-Item -LiteralPath $base -Force))) {
        throw "a pasta de dados $base é um link ou junção: recusada"
    }
    if (-not $Teste) {
        # A nossa pasta precisa de dono e DACL proprios; subpastas plantadas antes (dono nao confiavel ou
        # link) saem do caminho, porque o dono mantem WRITE_DAC mesmo depois de reaplicar a DACL do pai.
        if (-not $Script:BaseVerificada) {
            try {
                if (-not (Test-Path -LiteralPath $base)) { Set-SegurancaPastaApp $base }
                else {
                    $acl = Get-Acl -LiteralPath $base -ErrorAction Stop
                    $dono = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                    if (-not (Test-SidConfiavel $dono) -or -not $acl.AreAccessRulesProtected) {
                        Set-SegurancaPastaApp $base
                        $aviso = "aviso: permissões de $base corrigidas (dono anterior $dono)"
                    }
                    foreach ($sub in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop)) {
                        if ((Test-Reparse $sub) -or -not (Test-SidConfiavel (Get-DonoSid $sub.FullName))) {
                            $novo = $sub.Name + '.suspeito-' + [DateTime]::UtcNow.Ticks
                            Rename-Item -LiteralPath $sub.FullName -NewName $novo -Force -ErrorAction Stop
                            $aviso = "aviso: $($sub.FullName) não era nossa (link ou dono estranho); renomeada para $novo"
                        }
                    }
                }
                $Script:BaseVerificada = $true
            } catch { $aviso = "aviso: não foi possível proteger ${base}: $($_.Exception.Message)" }
        }
    }
    $p = @{
        Base       = $base
        Quarentena = Join-Path $base 'Quarentena'
        Logs       = Join-Path $base 'Logs'
        Backups    = Join-Path $base 'Backups'
        Estado     = Join-Path $base 'Estado'
        Ajustes    = Join-Path $base 'Ajustes'
    }
    foreach ($k in $p.Keys) {
        if (-not (Test-Path -LiteralPath $p[$k])) {
            New-Item -ItemType Directory -Path $p[$k] -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    if ($null -ne $aviso) { Add-LinhaLog $p.Logs $aviso }
    return $p
}

function Send-Progress {
    param([string]$Id, [int]$Pct, [string]$Msg)
    $o = [ordered]@{ id = $Id; pct = $Pct; msg = $Msg }
    Write-Linha ('@@PROGRESS ' + ($o | ConvertTo-Json -Compress))
}

function Send-Log {
    param([string]$Id, [string]$Tipo, [string]$Msg, [string]$Ruta = '')
    $o = [ordered]@{ id = $Id; tipo = $Tipo; msg = $Msg; ruta = $Ruta }
    Write-Linha ('@@LOG ' + ($o | ConvertTo-Json -Compress))
}

function Send-Result {
    param([string]$Id, $Dados, [bool]$Ok = $true, [string]$Erro = '')
    $o = [ordered]@{ id = $Id; ok = $Ok; dados = $Dados; erro = $Erro }
    Write-Linha ('@@RESULT ' + ($o | ConvertTo-Json -Depth 8 -Compress))
}

function Write-AppLog {
    param([string]$Msg, [bool]$Teste = $false)
    $p = Get-AppPastas $Teste
    Add-LinhaLog $p.Logs $Msg
}

function Test-ParamVerdadeiro {
    # Somente o booleano $true vale (a string 'true' NAO vale).
    param($Params, [string]$Nome)
    if ($null -eq $Params) { return $false }
    $v = $Params.$Nome
    return ($v -is [bool] -and $v -eq $true)
}

function Get-Simulacao {
    # 'simular' so vale em modo de teste; fora dele e ignorado.
    param($Params, [bool]$Teste)
    if (-not $Teste -or $null -eq $Params) { return $null }
    return $Params.simular
}

function Get-IdsParam {
    # 'ids' dos params como lista de textos nao vazios (vazia se ausente).
    param($Params)
    if ($null -eq $Params -or $null -eq $Params.ids) { return @() }
    return @(@($Params.ids) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Test-Reparse {
    param($Item)
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
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

function Get-PathSize {
    # Soma o tamanho dos arquivos sem seguir junctions/links (nem a propria raiz, se for um).
    # -AntesDe: conta so arquivos com LastWriteTime anterior a essa data.
    param([string]$Path, [DateTime]$AntesDe = [DateTime]::MaxValue)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or (Test-Reparse $item)) { return [int64]0 }
    if (-not $item.PSIsContainer) {
        if ($item.LastWriteTime -ge $AntesDe) { return [int64]0 }
        return [int64]$item.Length
    }
    $total = [int64]0
    $pilha = New-Object System.Collections.Generic.Stack[string]
    $pilha.Push($item.FullName)
    while ($pilha.Count -gt 0) {
        foreach ($f in @(Get-ChildItem -LiteralPath $pilha.Pop() -Force -ErrorAction SilentlyContinue)) {
            if (Test-Reparse $f) { continue }
            if ($f.PSIsContainer) { $pilha.Push($f.FullName) }
            elseif ($f.LastWriteTime -lt $AntesDe) { $total += $f.Length }
        }
    }
    return [int64]$total
}

function Test-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $true }
    # Expande nomes 8.3 no ancestral existente mais proximo e reanexa o restante
    $existente = $full
    $resto = ''
    while ($existente.Length -gt 3 -and -not (Test-Path -LiteralPath $existente)) {
        $resto = '\' + (Split-Path -Leaf $existente) + $resto
        $existente = Split-Path -Parent $existente
        if ([string]::IsNullOrEmpty($existente)) { break }
    }
    if (-not [string]::IsNullOrEmpty($existente) -and (Test-Path -LiteralPath $existente)) {
        try {
            if ($null -eq $Script:Fso) { $Script:Fso = New-Object -ComObject Scripting.FileSystemObject }
            if (Test-Path -LiteralPath $existente -PathType Container) { $exp = $Script:Fso.GetFolder($existente).Path }
            else { $exp = $Script:Fso.GetFile($existente).Path }
            $full = $exp.TrimEnd('\') + $resto
        } catch { $null = $_ }
    }
    $n = $full.TrimEnd('\').ToLowerInvariant()
    if ($n.Length -le 3) { return $true }   # raiz de unidade

    $base = Join-Path $env:ProgramData 'NexTune'
    $prefixos = @($env:windir, $base)
    foreach ($pre in $prefixos) {
        if ([string]::IsNullOrEmpty($pre)) { continue }
        $x = $pre.TrimEnd('\').ToLowerInvariant()
        if ($n -eq $x -or $n.StartsWith($x + '\')) { return $true }
    }

    $pf = $env:ProgramFiles
    $pf86 = ${env:ProgramFiles(x86)}
    $exatos = @(
        $env:SystemDrive, $env:windir,
        (Join-Path $env:windir 'System32'), (Join-Path $env:windir 'SysWOW64'),
        $pf, $pf86, $env:ProgramData, $env:APPDATA, $env:LOCALAPPDATA,
        (Join-Path $env:LOCALAPPDATA 'Programs'), $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Documents'), (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $pf 'Common Files'), (Join-Path $pf86 'Common Files'),
        (Join-Path $pf 'WindowsApps'),
        (Join-Path $env:ProgramData 'Microsoft'), (Join-Path $env:APPDATA 'Microsoft'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft'),
        (Join-Path $pf 'Microsoft'), (Join-Path $pf86 'Microsoft'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
        $base
    )
    foreach ($e in $exatos) {
        if ([string]::IsNullOrEmpty($e)) { continue }
        if ($n -eq $e.TrimEnd('\').ToLowerInvariant()) { return $true }
    }

    if ($n -match '\\(windows defender|windows nt|windowsapps|windows kits|dotnet|microsoft\.net|common files|edgewebview|edgecore|edgeupdate|microsoft\\edge)(\\|$)') { return $true }
    return $false
}

function Get-Perfil {
    param([bool]$Teste = $false)
    $arq = Join-Path (Get-AppPastas $Teste).Estado 'perfil.json'
    if (-not (Test-Path -LiteralPath $arq)) { return $null }
    try {
        $r = Get-Content -LiteralPath $arq -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($r -isnot [pscustomobject]) { return $null }
        $classe = [string]$r.classe
        $disco = [string]$r.disco
        if ([string]::IsNullOrEmpty($classe) -or [string]::IsNullOrEmpty($disco)) { return $null }
        return [pscustomobject]@{ classe = $classe; disco = $disco; manual = [bool]$r.manual }
    } catch { return $null }
}

function Set-Perfil {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Perfil, [bool]$Teste = $false)
    $arq = Join-Path (Get-AppPastas $Teste).Estado 'perfil.json'
    $o = [ordered]@{ classe = $Perfil.classe; disco = $Perfil.disco; manual = $Perfil.manual }
    $json = $o | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($arq, $json, (New-Object System.Text.UTF8Encoding $false))
}

# ---------- dados, atalhos e registro (compartilhados por programas, inicializacao e ajusteswin) ----------

function Get-PastaDeDados {
    # Pasta 'data' ao lado de 'scripts' (repositorio e bundle).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    [CmdletBinding()]
    param()
    return (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($PSScriptRoot))) 'data')
}

function Read-ArquivoJson {
    # Le um JSON em UTF-8 (com ou sem BOM). Lanca se o arquivo nao existir ou nao for JSON.
    param([string]$Caminho)
    if (-not (Test-Path -LiteralPath $Caminho -PathType Leaf)) { throw "arquivo de dados não encontrado: $Caminho" }
    $texto = [IO.File]::ReadAllText($Caminho, [Text.Encoding]::UTF8)
    return ($texto.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop)
}

function New-RegexLista {
    # Regex sem diferenciar caixa; $null se o padrao nao compilar (a entrada e ignorada).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param($Padrao)
    if ([string]::IsNullOrWhiteSpace([string]$Padrao)) { return $null }
    try { return (New-Object System.Text.RegularExpressions.Regex -ArgumentList ([string]$Padrao), ([Text.RegularExpressions.RegexOptions]::IgnoreCase)) }
    catch { return $null }
}

$Script:WsShell = $null
function Get-AlvoAtalho {
    # TargetPath de um .lnk via WScript.Shell; $null se nao der para ler.
    param([string]$Caminho)
    try {
        if ($null -eq $Script:WsShell) { $Script:WsShell = New-Object -ComObject WScript.Shell }
        return [string]$Script:WsShell.CreateShortcut($Caminho).TargetPath
    } catch { return $null }
}

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

# ---------- disco e arquivos JSON (compartilhados por diagnostico, disco e ajusteswin) ----------

function Get-TipoDisco {
    # Puro: MediaType/BusType do disco fisico -> 'HDD' | 'SSD' | 'NVMe'. Ilegivel conta como HDD.
    param([string]$Media, [string]$Bus)
    if ($Bus -eq 'NVMe') { return 'NVMe' }
    if ($Media -eq 'SSD' -or $Media -eq 'SCM') { return 'SSD' }
    return 'HDD'
}

function Get-InicioRapido {
    # Inicializacao Rapida (HiberbootEnabled = 1); erro de leitura conta como desligada.
    try {
        $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
        return ($hb -eq 1)
    } catch { return $false }
}

function Write-JsonAtomico {
    # Grava JSON em UTF-8 sem BOM via .tmp + Move-Item -Force (quem le nunca ve arquivo pela metade).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    param([string]$Caminho, $Objeto, [int]$Profundidade = 6)
    $json = $Objeto | ConvertTo-Json -Depth $Profundidade
    $tmp = $Caminho + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Caminho -Force -ErrorAction Stop
}

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
