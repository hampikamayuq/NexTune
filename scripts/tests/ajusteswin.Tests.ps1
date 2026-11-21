BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\ajusteswin.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:RaizT = 'HKCU:\Software\NexTuneTeste\Ajustes'
    $Script:Catalogo = @((Read-ArquivoJson (Join-Path (Get-PastaDeDados) 'ajustes.json')).ajustes)
    $Script:Backup = Join-Path (Get-AppPastas $true).Backups 'ajustes-registro.json'
    $Script:ChavePub = 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
    $Script:ChaveMetrics = 'HKCU\Control Panel\Desktop\WindowMetrics'

    function Invoke-Aj {
        param([string]$Acao, $Params = @{}, [bool]$Teste = $true)
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 'j1' $Acao $Params $Teste } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    # Caminho do provedor (Registry::...) da chave efetiva em modo teste.
    function Get-ProvT { param([string]$Chave) return (ConvertTo-CaminhoRegistro (Get-ChaveEfetiva $Chave $true)) }
    function Set-ValorT {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
        [CmdletBinding()]
        param([string]$Chave, [string]$Nome, $Valor, [string]$Tipo)
        $p = Get-ProvT $Chave
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
        Set-ItemProperty -LiteralPath $p -Name $Nome -Value $Valor -Type $Tipo
    }
    function Get-ValorT {
        param([string]$Chave, [string]$Nome)
        $p = Get-ProvT $Chave
        if (-not (Test-Path -LiteralPath $p)) { return $null }
        $k = Get-Item -LiteralPath $p
        if (@($k.GetValueNames()) -notcontains $Nome) { return $null }
        return $k.GetValue($Nome, $null, 'DoNotExpandEnvironmentNames')
    }
    function Get-KindT {
        param([string]$Chave, [string]$Nome)
        return [string](Get-Item -LiteralPath (Get-ProvT $Chave)).GetValueKind($Nome)
    }
    function Get-Aj { param($R, [string]$Id) return @($R.dados.ajustes | Where-Object { $_.id -eq $Id })[0] }
    function Use-PerfilTeste {
        param([string]$Classe, [string]$Disco)
        Set-Perfil ([pscustomobject]@{ classe = $Classe; disco = $Disco; manual = $true }) $true
    }
}

AfterAll {
    Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\Ajustes' -Recurse -Force -ErrorAction SilentlyContinue
    $t = Join-Path $env:TEMP 'NexTuneTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'ajusteswin.ps1' {
    BeforeEach {
        Remove-Item -LiteralPath 'HKCU:\Software\NexTuneTeste\Ajustes' -Recurse -Force -ErrorAction SilentlyContinue
        $b = (Get-AppPastas $true).Backups
        if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Recurse -Force -ErrorAction SilentlyContinue }
        Use-PerfilTeste 'medio' 'ssd'
    }

    Context 'funcoes puras' {
        It 'Get-ChaveEfetiva redireciona HKCU e HKLM em teste e devolve a chave intacta fora dele' {
            Get-ChaveEfetiva 'HKLM\SOFTWARE\X' $true | Should -Be 'HKCU\Software\NexTuneTeste\Ajustes\HKLM\SOFTWARE\X'
            Get-ChaveEfetiva 'HKCU\Software\Y' $true | Should -Be 'HKCU\Software\NexTuneTeste\Ajustes\HKCU\Software\Y'
            Get-ChaveEfetiva 'HKLM\SOFTWARE\X' $false | Should -Be 'HKLM\SOFTWARE\X'
        }
        It 'Test-AjusteDisponivel: soWin11 exige build 22000+' {
            (Test-AjusteDisponivel @{ soWin11 = $true } 19045).disponivel | Should -BeFalse
            (Test-AjusteDisponivel @{ soWin11 = $true } 19045).motivo | Should -Match 'Windows 11'
            (Test-AjusteDisponivel @{ soWin11 = $true } 22631).disponivel | Should -BeTrue
            (Test-AjusteDisponivel @{ soWin11 = $false } 19045).disponivel | Should -BeTrue
        }
        It 'Test-RecomendadoAjuste: todos sempre; fraco so com basico ou hdd (perfil ausente conta como fraco)' {
            $gamer = [pscustomobject]@{ classe = 'gamer'; disco = 'ssd' }
            $hdd = [pscustomobject]@{ classe = 'medio'; disco = 'hdd' }
            Test-RecomendadoAjuste @{ recomendadoPara = 'todos' } $gamer | Should -BeTrue
            Test-RecomendadoAjuste @{ recomendadoPara = 'fraco' } $gamer | Should -BeFalse
            Test-RecomendadoAjuste @{ recomendadoPara = 'fraco' } $hdd | Should -BeTrue
            Test-RecomendadoAjuste @{ recomendadoPara = 'fraco' } $null | Should -BeTrue
            Test-RecomendadoAjuste @{ recomendadoPara = 'nenhum' } $hdd | Should -BeFalse
        }
    }

    Context 'listar' {
        It 'sem avancado devolve so os ajustes nao avancados, nenhum aplicado nem com backup' {
            $r = Invoke-Aj 'listar'
            $r.ok | Should -BeTrue
            $esperados = @($Script:Catalogo | Where-Object { -not $_.avancado } | ForEach-Object { $_.id })
            @($r.dados.ajustes | ForEach-Object { $_.id }) | Should -Be $esperados
            foreach ($a in $r.dados.ajustes) {
                $a.aplicado | Should -BeFalse
                $a.temBackup | Should -BeFalse
                $a.grupo | Should -BeIn @('anuncios', 'privacidade', 'copilot', 'explorador', 'desempenho')
            }
        }
        It 'Review Focus 5: com avancado devolve todos; politica so aparece no avancado' {
            $r = Invoke-Aj 'listar' @{ avancado = $true }
            @($r.dados.ajustes).Count | Should -Be $Script:Catalogo.Count
            $h = Get-Aj $r 'historico_atividades'
            $h.politica | Should -BeTrue
            $h.avancado | Should -BeTrue
            Get-Aj (Invoke-Aj 'listar') 'historico_atividades' | Should -BeNullOrEmpty
        }
        It 'Review Focus 5: soWin11 indisponivel no Windows 10 e disponivel no 11' {
            $w10 = Get-Aj (Invoke-Aj 'listar' @{ simular = @{ build = 19045 } }) 'widgets_barra'
            $w10.disponivel | Should -BeFalse
            $w10.motivoIndisponivel | Should -Match 'Windows 11'
            $w11 = Get-Aj (Invoke-Aj 'listar' @{ simular = @{ build = 22631 } }) 'widgets_barra'
            $w11.disponivel | Should -BeTrue
            $w11.motivoIndisponivel | Should -BeNullOrEmpty
        }
        It 'recomendado segue o perfil: fraco so em basico/hdd, todos sempre' {
            Use-PerfilTeste 'basico' 'hdd'
            $r1 = Invoke-Aj 'listar'
            (Get-Aj $r1 'efeitos_visuais').recomendado | Should -BeTrue
            (Get-Aj $r1 'id_publicidade').recomendado | Should -BeTrue
            Use-PerfilTeste 'gamer' 'ssd'
            $r2 = Invoke-Aj 'listar'
            (Get-Aj $r2 'efeitos_visuais').recomendado | Should -BeFalse
            (Get-Aj $r2 'id_publicidade').recomendado | Should -BeTrue
        }
        It 'reiniciarExplorer vem do catalogo' {
            $r = Invoke-Aj 'listar'
            (Get-Aj $r 'extensoes_visiveis').reiniciarExplorer | Should -BeTrue
            (Get-Aj $r 'id_publicidade').reiniciarExplorer | Should -BeFalse
        }
    }

    Context 'privacidade ampliada (dados do Sophia)' {
        BeforeAll {
            $Script:Novos = @(
                @{ Id = 'feedback_frequencia'; Chave = 'HKCU\Software\Microsoft\Siuf\Rules'; Nome = 'NumberOfSIUFInPeriod'; Valor = 0; Pol = $false }
                @{ Id = 'idioma_sites'; Chave = 'HKCU\Control Panel\International\User Profile'; Nome = 'HttpAcceptLanguageOptOut'; Valor = 1; Pol = $false }
                @{ Id = 'novidades_windows'; Chave = 'HKCU\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; Nome = 'ScoobeSystemSettingEnabled'; Valor = 0; Pol = $false }
                @{ Id = 'sugestoes_pesquisa_web'; Chave = 'HKCU\Software\Policies\Microsoft\Windows\Explorer'; Nome = 'DisableSearchBoxSuggestions'; Valor = 1; Pol = $true }
            )
        }
        It 'os 4 ids aparecem em listar' {
            $r = Invoke-Aj 'listar' @{ avancado = $true }
            foreach ($n in $Script:Novos) {
                $a = Get-Aj $r $n.Id
                $a | Should -Not -BeNullOrEmpty
                $a.grupo | Should -Be 'privacidade'
                $a.politica | Should -Be $n.Pol
            }
        }
        It 'aplicar e restaurar quando nada existia remove nome e chave' {
            foreach ($n in $Script:Novos) {
                Test-Path -LiteralPath (Get-ProvT $n.Chave) | Should -BeFalse
                $r = Invoke-Aj 'aplicar' @{ ids = @($n.Id); confirmado = $true; avancado = $true }
                @($r.dados.aplicados) | Should -Be @($n.Id)
                Get-ValorT $n.Chave $n.Nome | Should -Be $n.Valor
                Get-KindT $n.Chave $n.Nome | Should -Be 'DWord'
                $r2 = Invoke-Aj 'restaurar' @{ ids = @($n.Id); confirmado = $true }
                @($r2.dados.restaurados) | Should -Be @($n.Id)
                Test-Path -LiteralPath (Get-ProvT $n.Chave) | Should -BeFalse
            }
        }
        It 'restaurar devolve o valor anterior exato' {
            foreach ($n in $Script:Novos) {
                Set-ValorT $n.Chave $n.Nome 7 'DWord'
                Invoke-Aj 'aplicar' @{ ids = @($n.Id); confirmado = $true; avancado = $true } | Out-Null
                Get-ValorT $n.Chave $n.Nome | Should -Be $n.Valor
                Invoke-Aj 'restaurar' @{ ids = @($n.Id); confirmado = $true } | Out-Null
                Get-ValorT $n.Chave $n.Nome | Should -Be 7
                Get-KindT $n.Chave $n.Nome | Should -Be 'DWord'
            }
        }
    }

    Context 'aplicar e restaurar' {
        It 'Review Focus 4: chave ausente -> aplica como DWord, backup registra ausencia, restaurar remove nome e chave' {
            Test-Path -LiteralPath (Get-ProvT $Script:ChavePub) | Should -BeFalse
            $r = Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.aplicados) | Should -Be @('id_publicidade')
            @($r.dados.falhas).Count | Should -Be 0
            $r.dados.precisaReiniciar | Should -BeFalse
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 0
            Get-KindT $Script:ChavePub 'Enabled' | Should -Be 'DWord'
            $bk = Get-Content -LiteralPath $Script:Backup -Raw -Encoding UTF8 | ConvertFrom-Json
            $bk.id_publicidade.valores[0].chaveExistia | Should -BeFalse
            $bk.id_publicidade.valores[0].existia | Should -BeFalse
            $bk.id_publicidade.data | Should -Not -BeNullOrEmpty
            $l = Get-Aj (Invoke-Aj 'listar') 'id_publicidade'
            $l.aplicado | Should -BeTrue
            $l.temBackup | Should -BeTrue

            $r2 = Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true }
            $r2.ok | Should -BeTrue
            @($r2.dados.restaurados) | Should -Be @('id_publicidade')
            Test-Path -LiteralPath (Get-ProvT $Script:ChavePub) | Should -BeFalse
            $l2 = Get-Aj (Invoke-Aj 'listar') 'id_publicidade'
            $l2.aplicado | Should -BeFalse
            $l2.temBackup | Should -BeFalse
        }
        It 'Review Focus 4: valor existente volta com o mesmo valor e tipo (DWord e String)' {
            Set-ValorT $Script:ChavePub 'Enabled' 1 'DWord'
            Set-ValorT $Script:ChaveMetrics 'MinAnimate' '1' 'String'
            (Invoke-Aj 'aplicar' @{ ids = @('id_publicidade', 'efeitos_visuais'); confirmado = $true }).dados.aplicados.Count | Should -Be 2
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 0
            Get-ValorT $Script:ChaveMetrics 'MinAnimate' | Should -Be '0'
            Get-KindT $Script:ChaveMetrics 'MinAnimate' | Should -Be 'String'
            (Get-Aj (Invoke-Aj 'listar') 'efeitos_visuais').aplicado | Should -BeTrue
            $r = Invoke-Aj 'restaurar' @{ ids = @('id_publicidade', 'efeitos_visuais'); confirmado = $true }
            @($r.dados.restaurados).Count | Should -Be 2
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
            Get-KindT $Script:ChavePub 'Enabled' | Should -Be 'DWord'
            Get-ValorT $Script:ChaveMetrics 'MinAnimate' | Should -Be '1'
            Get-KindT $Script:ChaveMetrics 'MinAnimate' | Should -Be 'String'
            # Desktop ja existia (pai de WindowMetrics): os nomes criados saem, a chave fica
            Test-Path -LiteralPath (Get-ProvT 'HKCU\Control Panel\Desktop') | Should -BeTrue
            Get-ValorT 'HKCU\Control Panel\Desktop' 'DragFullWindows' | Should -BeNullOrEmpty
            Get-ValorT 'HKCU\Control Panel\Desktop' 'MenuShowDelay' | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Get-ProvT $Script:ChaveMetrics) | Should -BeTrue
        }
        It 'chave existente sem o nome: restaurar remove o nome e mantem a chave' {
            $p = Get-ProvT $Script:ChavePub
            New-Item -Path $p -Force | Out-Null
            Set-ItemProperty -LiteralPath $p -Name 'Outro' -Value 5 -Type DWord
            Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            Test-Path -LiteralPath $p | Should -BeTrue
            Get-ValorT $Script:ChavePub 'Enabled' | Should -BeNullOrEmpty
            Get-ValorT $Script:ChavePub 'Outro' | Should -Be 5
        }
        It 'Review Focus 3: reaplicar nao sobrescreve o backup original' {
            Set-ValorT $Script:ChavePub 'Enabled' 1 'DWord'
            Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            Set-ValorT $Script:ChavePub 'Enabled' 5 'DWord'
            Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 0
            $bk = Get-Content -LiteralPath $Script:Backup -Raw -Encoding UTF8 | ConvertFrom-Json
            $bk.id_publicidade.valores[0].valor | Should -Be 1
            Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
        }
        It 'id desconhecido vai para falhas e o resto e aplicado; politica sem avancado e recusada (Review Focus 5)' {
            $r = Invoke-Aj 'aplicar' @{ ids = @('id_publicidade', 'nao_existe'); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.aplicados) | Should -Be @('id_publicidade')
            @($r.dados.falhas).Count | Should -Be 1
            $r.dados.falhas[0].id | Should -Be 'nao_existe'
            $r.dados.falhas[0].erro | Should -Not -BeNullOrEmpty
            $h = Invoke-Aj 'aplicar' @{ ids = @('historico_atividades'); confirmado = $true }
            @($h.dados.aplicados).Count | Should -Be 0
            $h.dados.falhas[0].id | Should -Be 'historico_atividades'
            $h.dados.falhas[0].erro | Should -Match 'avan'
            Test-Path -LiteralPath (Get-ProvT 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System') | Should -BeFalse
            $h2 = Invoke-Aj 'aplicar' @{ ids = @('historico_atividades'); confirmado = $true; avancado = $true }
            @($h2.dados.aplicados) | Should -Be @('historico_atividades')
            Get-ValorT 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' | Should -Be 0
        }
        It 'indisponivel (soWin11 no Windows 10) nao e aplicado' {
            $r = Invoke-Aj 'aplicar' @{ ids = @('widgets_barra'); confirmado = $true; simular = @{ build = 19045 } }
            @($r.dados.aplicados).Count | Should -Be 0
            $r.dados.falhas[0].erro | Should -Match 'Windows 11'
        }
        It 'precisaReiniciar reflete reiniciarExplorer dos ajustes aplicados e restaurados' {
            (Invoke-Aj 'aplicar' @{ ids = @('extensoes_visiveis'); confirmado = $true }).dados.precisaReiniciar | Should -BeTrue
            (Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true }).dados.precisaReiniciar | Should -BeFalse
            (Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true }).dados.precisaReiniciar | Should -BeFalse
            (Invoke-Aj 'restaurar' @{ ids = @('extensoes_visiveis'); confirmado = $true }).dados.precisaReiniciar | Should -BeTrue
        }
        It 'Review Focus 6: restaurar sem backup falha para aquele id e nada e escrito' {
            Set-ValorT $Script:ChavePub 'Enabled' 1 'DWord'
            $r = Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.restaurados).Count | Should -Be 0
            $r.dados.falhas[0].id | Should -Be 'id_publicidade'
            $r.dados.falhas[0].erro | Should -Match 'backup'
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
        }
        It 'Review Focus 6: backup corrompido -> restaurar falha, registro intacto, listar segue funcionando' {
            Set-ValorT $Script:ChavePub 'Enabled' 1 'DWord'
            $pasta = Split-Path -Parent $Script:Backup
            if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
            [IO.File]::WriteAllText($Script:Backup, '{ isto nao e json', (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true }
            $r.ok | Should -BeTrue
            @($r.dados.restaurados).Count | Should -Be 0
            $r.dados.falhas[0].erro | Should -Not -BeNullOrEmpty
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
            $l = Invoke-Aj 'listar'
            $l.ok | Should -BeTrue
            foreach ($a in $l.dados.ajustes) { $a.temBackup | Should -BeFalse }
            # aplicar com backup ilegivel tambem recusa: nunca escreve sem conseguir guardar o original
            $ap = Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true }
            @($ap.dados.aplicados).Count | Should -Be 0
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
        }
        It 'restaurar ignora entradas do backup fora das chaves do catalogo (arquivo adulterado nao escreve em outra chave)' {
            Set-ValorT $Script:ChavePub 'Enabled' 1 'DWord'
            Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = $true } | Out-Null
            $bk = Get-Content -LiteralPath $Script:Backup -Raw -Encoding UTF8 | ConvertFrom-Json
            $estranha = [pscustomobject]@{ chave = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System'; nome = 'EnableLUA'; chaveExistia = $true; existia = $true; tipo = 'DWord'; valor = 0 }
            $bk.id_publicidade.valores = @($bk.id_publicidade.valores) + @($estranha)
            [IO.File]::WriteAllText($Script:Backup, ($bk | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
            $r = Invoke-Aj 'restaurar' @{ ids = @('id_publicidade'); confirmado = $true }
            @($r.dados.restaurados) | Should -Be @('id_publicidade')
            Get-ValorT $Script:ChavePub 'Enabled' | Should -Be 1
            Test-Path -LiteralPath (Get-ProvT 'HKLM\SOFTWARE\Policies\Microsoft\Windows\System') | Should -BeFalse
        }
        It 'recusa sem confirmado e sem ids' {
            (Invoke-Aj 'aplicar' @{ ids = @('id_publicidade') }).ok | Should -BeFalse
            (Invoke-Aj 'aplicar' @{ ids = @('id_publicidade'); confirmado = 'true' }).ok | Should -BeFalse
            (Invoke-Aj 'restaurar' @{ ids = @('id_publicidade') }).ok | Should -BeFalse
            (Invoke-Aj 'aplicar' @{ confirmado = $true }).ok | Should -BeFalse
            Test-Path -LiteralPath (Get-ProvT $Script:ChavePub) | Should -BeFalse
        }
    }

    Context 'Invoke-Acao' {
        It 'acao desconhecida devolve erro' {
            $r = Invoke-Aj 'xyz'
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'ação desconhecida'
        }
    }
}
