BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\atualizacoes.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'atualizacoes'
    $Script:IdSeg = '11111111-1111-4111-8111-111111111111'
    $Script:IdQual = '22222222-2222-4222-8222-222222222222'
    $Script:IdPrev = '33333333-3333-4333-8333-333333333333'
    $Script:IdUpg = '44444444-4444-4444-8444-444444444444'
    $Script:CatSeg = @{ id = '0FA1201D-4330-4FA8-8AE9-B877473B6441'; nome = 'Security Updates' }
    $Script:CatQual = @{ id = 'CD5FFD1E-E932-4E3A-BF74-18BF0B1BBD83'; nome = 'Updates' }
    $Script:CatUpg = @{ id = '3689BDC8-B205-4AF4-8D4A-A63924C5E9D5'; nome = 'Upgrades' }

    function Invoke-Atu {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'u1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    # Linha de tabela do winget com as colunas nas posicoes 0, 30, 60, 76 e 92 (como o winget alinha).
    function Get-LinhaWinget {
        param([string[]]$Campos, [int[]]$Inicios = @(0, 30, 60, 76, 92))
        $inicios = $Inicios
        $s = ''
        for ($i = 0; $i -lt $Campos.Count; $i++) { $s = $s.PadRight($inicios[$i]) + $Campos[$i] }
        return $s
    }
    function Get-SaidaWinget {
        param([string]$Idioma)
        $pt = ($Idioma -eq 'pt')
        $cab = if ($pt) { Get-LinhaWinget 'Nome', 'Id', 'Versão', 'Disponível', 'Origem' } else { Get-LinhaWinget 'Name', 'Id', 'Version', 'Available', 'Source' }
        $spinner = "-`b\`b|`b/`b"
        return @(
            $(if ($pt) { $spinner } else { $spinner + "`r" + $cab }),
            $(if ($pt) { $cab } else { ('-' * 100) }),
            $(if ($pt) { ('-' * 100) } else { (Get-LinhaWinget 'Google Chrome', 'Google.Chrome', '130.0.6723.117', '131.0.6778.86', 'winget') }),
            $(if ($pt) { (Get-LinhaWinget 'Google Chrome', 'Google.Chrome', '130.0.6723.117', '131.0.6778.86', 'winget') } else { (Get-LinhaWinget 'VLC media player', 'VideoLAN.VLC', '3.0.20', '3.0.21', 'winget') }),
            $(if ($pt) { (Get-LinhaWinget 'VLC media player', 'VideoLAN.VLC', '3.0.20', '3.0.21', 'winget') } else { (Get-LinhaWinget 'Microsoft Visual C++ 2015-20…', 'Microsoft.VCRedist.2015+.x64', '14.40.33810.0', '14.42.34433.0', 'winget') }),
            $(if ($pt) { (Get-LinhaWinget 'Microsoft Visual C++ 2015-20…', 'Microsoft.VCRedist.2015+.x64', '14.40.33810.0', '14.42.34433.0', 'winget') } else { '' }),
            $(if ($pt) { '' } else { '3 upgrades available.' }),
            $(if ($pt) { '3 atualizações disponíveis.' } else { '' }),
            '',
            $(if ($pt) { 'Os pacotes a seguir têm uma atualização disponível, mas exigem instalação explícita:' } else { 'The following packages have an upgrade available, but require explicit targeting for upgrade:' }),
            $cab,
            ('-' * 100),
            (Get-LinhaWinget 'Spotify', 'Spotify.Spotify', '1.2.40', '1.2.50', 'winget')
        )
    }
    function Get-SimPadrao {
        return @{
            windows      = @(
                @{ id = $Script:IdSeg; titulo = '2026-11 Atualização Cumulativa para Windows 11 (KB5048667)'; kb = 'KB5048667'; tamanhoBytes = 320MB; categorias = @($Script:CatSeg); exigeReinicio = $true },
                @{ id = $Script:IdQual; titulo = 'Atualização do .NET Framework (KB5048163)'; kb = 'KB5048163'; tamanhoBytes = 60MB; categorias = @($Script:CatQual); exigeReinicio = $false },
                @{ id = $Script:IdPrev; titulo = '2026-11 Cumulative Update Preview for Windows 11 (KB5050094)'; kb = 'KB5050094'; tamanhoBytes = 400MB; categorias = @($Script:CatQual); exigeReinicio = $true },
                @{ id = $Script:IdUpg; titulo = 'Windows 11, versão 25H2'; kb = $null; tamanhoBytes = 4GB; categorias = @($Script:CatUpg); exigeReinicio = $true }
            )
            wingetLinhas = @(Get-SaidaWinget 'pt')
        }
    }
    function Get-Win { param($R, [string]$Id) return @($R.dados.windows | Where-Object { $_.id -eq $Id })[0] }
    function Test-Marcador { param([string]$Nome) return (Test-Path -LiteralPath (Join-Path $Script:PastaT $Nome)) }
}

AfterAll {
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'atualizacoes.ps1' {
    BeforeEach {
        if (Test-Path -LiteralPath $Script:PastaT) { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }
        $Script:Sim = Get-SimPadrao
    }

    Context 'funcoes puras' {
        It 'Review Focus 5: parser do winget da a mesma lista em pt-BR e en-US, ignorando spinner, rodape e segunda tabela' {
            foreach ($idioma in @('pt', 'en')) {
                $lista = @(ConvertFrom-TabelaWinget (Get-SaidaWinget $idioma))
                @($lista | ForEach-Object { $_.id }) | Should -Be @('Google.Chrome', 'VideoLAN.VLC', 'Microsoft.VCRedist.2015+.x64')
                $lista[0].nome | Should -Be 'Google Chrome'
                $lista[0].versaoAtual | Should -Be '130.0.6723.117'
                $lista[0].versaoNova | Should -Be '131.0.6778.86'
                $lista[0].origem | Should -Be 'winget'
                $lista[2].nome | Should -Be 'Microsoft Visual C++ 2015-20…'
            }
        }
        It 'Review Focus 5: saida real do winget (um espaco so entre Disponivel e Origem), nome com numero e id truncado' {
            # Larguras como o winget 1.29 imprime em pt-BR: "Disponível" ocupa a coluna inteira e sobra 1 espaco antes de "Origem".
            $ini = @(0, 21, 55, 64, 75)
            $linhas = @(
                (Get-LinhaWinget @('Nome', 'ID', 'Versão', 'Disponível', 'Origem') $ini),
                ('-' * 81),
                (Get-LinhaWinget @('Google Chrome', 'Google.Chrome', '26.8.0.3', '26.8.3.1', 'winget') $ini),
                (Get-LinhaWinget @('360 Total Security', 'Qihoo.360TotalSecurity', '11.0.0.1', '11.0.0.2', 'winget') $ini),
                (Get-LinhaWinget @('Microsoft Visual C…', 'Microsoft.VCRedi…', '14.40.33810.0', '14.42.34433.0', 'winget') $ini),
                '',
                '3 atualizações disponíveis.'
            )
            $lista = @(ConvertFrom-TabelaWinget $linhas)
            @($lista | ForEach-Object { $_.id }) | Should -Be @('Google.Chrome', 'Qihoo.360TotalSecurity')
            $lista[0].versaoNova | Should -Be '26.8.3.1'
            $lista[0].origem | Should -Be 'winget'
            $lista[1].nome | Should -Be '360 Total Security'
        }
        It 'Review Focus 5: saida vazia ou sem tabela da lista vazia' {
            @(ConvertFrom-TabelaWinget @()).Count | Should -Be 0
            @(ConvertFrom-TabelaWinget $null).Count | Should -Be 0
            @(ConvertFrom-TabelaWinget @('Nenhuma atualização aplicável encontrada.')).Count | Should -Be 0
        }
        It 'Get-TipoAtualizacao classifica pela categoria' {
            Get-TipoAtualizacao @($Script:CatSeg) | Should -Be 'seguranca'
            Get-TipoAtualizacao @($Script:CatQual) | Should -Be 'qualidade'
            Get-TipoAtualizacao @($Script:CatQual, $Script:CatSeg) | Should -Be 'seguranca'
            Get-TipoAtualizacao @(@{ id = 'E0789628-CE08-4437-BE74-2495B842F43B'; nome = 'Definition Updates' }) | Should -Be 'definicao'
            Get-TipoAtualizacao @(@{ id = '00000000-0000-0000-0000-000000000000'; nome = 'X' }) | Should -Be 'outro'
            Get-TipoAtualizacao @() | Should -Be 'outro'
        }
        It 'Test-Excluida: upgrade pela categoria, preview pelo titulo, senao null' {
            Test-Excluida 'Windows 11, versão 25H2' @($Script:CatUpg) | Should -Be 'upgrade'
            Test-Excluida 'Windows 11, versão 25H2' @(@{ id = 'x'; nome = 'Upgrades' }) | Should -Be 'upgrade'
            Test-Excluida '2025-01 Cumulative Update Preview for .NET' @() | Should -Be 'preview'
            Test-Excluida 'Atualização Prévia' @() | Should -Be 'preview'
            Test-Excluida 'KB5048667' @() | Should -BeNullOrEmpty
            Test-Excluida 'Atualização Cumulativa' @($Script:CatSeg) | Should -BeNullOrEmpty
        }
    }

    Context 'listar' {
        It 'sem avancado esconde preview e upgrade; programas vem do winget' {
            $r = Invoke-Atu 'listar' @{ simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.windows | ForEach-Object { $_.id }) | Should -Be @($Script:IdSeg, $Script:IdQual)
            $seg = Get-Win $r $Script:IdSeg
            $seg.tipo | Should -Be 'seguranca'
            $seg.kb | Should -Be 'KB5048667'
            $seg.exigeReinicio | Should -BeTrue
            $seg.excluido | Should -BeNullOrEmpty
            (Get-Win $r $Script:IdQual).tipo | Should -Be 'qualidade'
            $r.dados.windowsErro | Should -BeNullOrEmpty
            @($r.dados.programas | ForEach-Object { $_.id }) | Should -Be @('Google.Chrome', 'VideoLAN.VLC', 'Microsoft.VCRedist.2015+.x64')
            $r.dados.winget.disponivel | Should -BeTrue
            $r.dados.winget.erro | Should -BeNullOrEmpty
        }
        It 'com avancado mostra preview e upgrade marcados como excluidos' {
            $r = Invoke-Atu 'listar' @{ avancado = $true; simular = $Script:Sim }
            @($r.dados.windows).Count | Should -Be 4
            (Get-Win $r $Script:IdPrev).excluido | Should -Be 'preview'
            (Get-Win $r $Script:IdUpg).excluido | Should -Be 'upgrade'
            (Get-Win $r $Script:IdUpg).kb | Should -BeNullOrEmpty
        }
        It 'Review Focus 6: winget ausente nao derruba listar' {
            $sim = Get-SimPadrao
            $sim.wingetAusente = $true
            $r = Invoke-Atu 'listar' @{ simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.programas).Count | Should -Be 0
            $r.dados.winget.disponivel | Should -BeFalse
            $r.dados.winget.erro | Should -Not -BeNullOrEmpty
            @($r.dados.windows).Count | Should -Be 2
        }
        It 'Review Focus 6: erro do Windows Update vai no campo e os programas ainda vem' {
            $sim = Get-SimPadrao
            $sim.windowsErro = 'Exceção de HRESULT: 0x80240438'
            $r = Invoke-Atu 'listar' @{ simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.windows).Count | Should -Be 0
            $r.dados.windowsErro | Should -Match '80240438'
            @($r.dados.programas).Count | Should -Be 3
        }
    }

    Context 'instalar' {
        It 'Review Focus 4: upgrade nunca instala; preview so no avancado; os demais seguem' {
            $ids = @($Script:IdSeg, $Script:IdQual, $Script:IdPrev, $Script:IdUpg)
            $r = Invoke-Atu 'instalar' @{ ids = $ids; confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.instalados) | Should -Be @($Script:IdSeg, $Script:IdQual)
            @($r.dados.falhas | ForEach-Object { $_.id }) | Should -Be @($Script:IdPrev, $Script:IdUpg)
            @($r.dados.falhas)[0].erro | Should -Match 'avan'
            @($r.dados.falhas)[1].erro | Should -Match 'vers'
            $r.dados.precisaReiniciar | Should -BeTrue
            Test-Marcador "instalar-$($Script:IdSeg).txt" | Should -BeTrue
            Test-Marcador "instalar-$($Script:IdPrev).txt" | Should -BeFalse
            Test-Marcador "instalar-$($Script:IdUpg).txt" | Should -BeFalse

            $r2 = Invoke-Atu 'instalar' @{ ids = @($Script:IdPrev, $Script:IdUpg); confirmado = $true; avancado = $true; simular = $Script:Sim }
            @($r2.dados.instalados) | Should -Be @($Script:IdPrev)
            @($r2.dados.falhas | ForEach-Object { $_.id }) | Should -Be @($Script:IdUpg)
            Test-Marcador "instalar-$($Script:IdPrev).txt" | Should -BeTrue
            Test-Marcador "instalar-$($Script:IdUpg).txt" | Should -BeFalse
        }
        It 'id desconhecido e falha simulada vao para falhas; precisaReiniciar segue os instalados' {
            $sim = Get-SimPadrao
            $sim.falharIds = @($Script:IdSeg)
            $r = Invoke-Atu 'instalar' @{ ids = @($Script:IdQual, $Script:IdSeg, '99999999-9999-4999-8999-999999999999'); confirmado = $true; simular = $sim }
            @($r.dados.instalados) | Should -Be @($Script:IdQual)
            @($r.dados.falhas).Count | Should -Be 2
            @($r.dados.falhas)[0].erro | Should -Match 'simulad'
            @($r.dados.falhas)[1].erro | Should -Match 'dispon'
            $r.dados.precisaReiniciar | Should -BeFalse
        }
        It 'recusa sem confirmado e sem ids' {
            (Invoke-Atu 'instalar' @{ ids = @($Script:IdSeg); simular = $Script:Sim }).ok | Should -BeFalse
            (Invoke-Atu 'instalar' @{ ids = @($Script:IdSeg); confirmado = 'true'; simular = $Script:Sim }).ok | Should -BeFalse
            (Invoke-Atu 'instalar' @{ confirmado = $true; simular = $Script:Sim }).ok | Should -BeFalse
            Test-Path -LiteralPath $Script:PastaT | Should -BeFalse
        }
    }

    Context 'atualizarProgramas' {
        It 'atualiza por id e grava o marcador' {
            $r = Invoke-Atu 'atualizarProgramas' @{ ids = @('Google.Chrome', 'VideoLAN.VLC'); confirmado = $true; simular = $Script:Sim }
            $r.ok | Should -BeTrue
            @($r.dados.atualizados) | Should -Be @('Google.Chrome', 'VideoLAN.VLC')
            @($r.dados.falhas).Count | Should -Be 0
            Test-Marcador 'winget-Google.Chrome.txt' | Should -BeTrue
        }
        It 'codigo de saida do winget vira frase em portugues e campo codigo; os outros seguem' {
            $sim = Get-SimPadrao
            $sim.wingetCodigos = @{ 'TheDocumentFoundation.LibreOffice' = [int]-1978334960; 'UltraVNC.UltraVNC' = [int64]0x8A15010C }
            $r = Invoke-Atu 'atualizarProgramas' @{ ids = @('TheDocumentFoundation.LibreOffice', 'UltraVNC.UltraVNC', 'VideoLAN.VLC'); confirmado = $true; simular = $sim }
            $r.ok | Should -BeTrue
            @($r.dados.atualizados) | Should -Be @('VideoLAN.VLC')
            $lo = @($r.dados.falhas | Where-Object { $_.id -like '*LibreOffice' })[0]
            $lo.codigo | Should -Be '0x8A150110'
            $lo.erro | Should -Match 'dependência'
            $vnc = @($r.dados.falhas | Where-Object { $_.id -like '*VNC' })[0]
            $vnc.codigo | Should -Be '0x8A15010C'
            $vnc.erro | Should -Match 'fech'
        }
        It 'Review Focus 6: winget ausente recusa a chamada inteira' {
            $sim = Get-SimPadrao
            $sim.wingetAusente = $true
            $r = Invoke-Atu 'atualizarProgramas' @{ ids = @('Google.Chrome'); confirmado = $true; simular = $sim }
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'winget'
        }
        It 'recusa sem confirmado' {
            (Invoke-Atu 'atualizarProgramas' @{ ids = @('Google.Chrome'); simular = $Script:Sim }).ok | Should -BeFalse
            Test-Path -LiteralPath $Script:PastaT | Should -BeFalse
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Atu 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
