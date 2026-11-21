# reparo.ps1 - explica falhas do winget/instalador e repara produtos do Windows Installer orfaos
# (sem a copia local do .msi em C:\Windows\Installer e sem origem acessivel: o Windows nao consegue
# atualizar nem desinstalar e responde 1603/1612). Reparar so remove o REGISTRO do produto, depois de
# exportar as chaves para a quarentena; nunca apaga arquivos de programas nem do cache do instalador.
# Acoes: diagnosticar {simular?}, reparar {ids:[{GUID}], confirmado}.
# Logica de deteccao baseada em Unregister-MissingMSIs.ps1 (MIT, heaths/BrentHumphreys), reescrita sem o
# modulo MSI da internet.
. "$PSScriptRoot\common.ps1"

$Script:MensagensWinget = @{
    0x8A150101L = 'O programa está aberto. Feche-o e tente de novo.'
    0x8A150102L = 'Outra instalação já está em andamento. Espere terminar e tente de novo.'
    0x8A150103L = 'Há arquivos do programa em uso. Feche o programa (e, se houver, o serviço dele) e tente de novo.'
    0x8A150105L = 'Não há espaço livre suficiente no disco. Libere espaço e tente de novo.'
    0x8A150107L = 'O instalador precisa de internet. Conecte-se e tente de novo.'
    0x8A150108L = 'O instalador do programa deu erro. Tente de novo ou procure o suporte do fabricante.'
    0x8A150109L = 'Reinicie o PC para terminar a instalação.'
    0x8A15010AL = 'A instalação falhou e pede reinício. Reinicie o PC e tente de novo.'
    0x8A15010CL = 'A instalação foi cancelada, em geral porque o programa está aberto e o instalador não conseguiu fechá-lo. Feche o programa (e o serviço dele, se houver) e tente de novo.'
    0x8A15010DL = 'Já existe outra versão deste programa instalada.'
    0x8A15010EL = 'Já existe uma versão mais nova instalada.'
    0x8A15010FL = 'Uma política da organização impede esta instalação.'
    0x8A150110L = 'Falhou a instalação de uma dependência do programa (por exemplo, o Visual C++). Veja a tela Reparo: pode haver um registro do instalador quebrado.'
}

function Get-MensagemWinget {
    # Frase em portugues para um codigo de saida do winget (aceita int32 negativo ou int64). Desconhecido: generica com o codigo.
    param([int64]$Codigo)
    if ($Codigo -lt 0) { $Codigo += 4294967296 }
    $hex = '0x{0:X8}' -f $Codigo
    if (-not $Script:MensagensWinget.ContainsKey([int64]$Codigo)) { return "winget terminou com código $hex" }
    return ($Script:MensagensWinget[[int64]$Codigo] + " ($hex)")
}

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
