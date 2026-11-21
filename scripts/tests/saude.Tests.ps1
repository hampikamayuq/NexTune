BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\saude.ps1"
    . "$PSScriptRoot\_helpers.ps1"
    $Script:PastaT = Join-Path (Join-Path $env:TEMP 'NexTuneTeste') 'saude'

    function Invoke-Saude {
        param([string]$Acao, $Params = @{})
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        try { Invoke-Acao 's1' $Acao $Params $true } finally { Set-Saida $null }
        $Script:UltimaSaida = $sw.ToString()
        $linhas = @($sw.ToString() -split "`r?`n" | Where-Object { $_.StartsWith('@@RESULT ') })
        if ($linhas.Count -ne 1) { return $null }
        return $linhas[0].Substring(9) | ConvertFrom-Json
    }
    function Get-Porcentagem {
        return @($Script:UltimaSaida -split "`r?`n" | Where-Object { $_.StartsWith('@@PROGRESS ') } | ForEach-Object { ($_.Substring(11) | ConvertFrom-Json).pct })
    }

    # Trechos de CBS.log gravados. O CBS escreve em ingles em qualquer idioma do Windows (num Windows pt-BR
    # o console do DISM sai em portugues e o CBS.log continua em ingles); o "pt" tem caminhos e .mui pt-BR.
    $Script:CbsLimpoEn = @(
        '2026-11-21 14:00:01, Info                  CSI    00000010 [SR] Verifying 100 components',
        '2026-11-21 14:00:01, Info                  CSI    00000011 [SR] Beginning Verify and Repair transaction',
        '2026-11-21 14:00:03, Info                  CSI    00000012 [SR] Verify complete',
        '2026-11-21 14:00:03, Info                  CSI    00000013 [SR] Repairing 0 components',
        '2026-11-21 14:00:03, Info                  CSI    00000014 [SR] Beginning Verify and Repair transaction',
        '2026-11-21 14:00:03, Info                  CSI    00000015 [SR] Repair complete'
    )
    $Script:CbsReparadoEn = @(
        '2026-11-21 14:00:01, Info                  CSI    00000010 [SR] Verifying 100 components',
        '2026-11-21 14:00:02, Info                  CSI    00000011 [SR] Beginning Verify and Repair transaction',
        '2026-11-21 14:00:03, Info                  CSI    00000012 Hashes for file member \SystemRoot\WinSxS\amd64_microsoft-windows-tcpip\tcpip.sys do not match actual file [l:9]"tcpip.sys" :',
        '2026-11-21 14:00:03, Info                  CSI    00000013 [SR] Repairing corrupted file \??\C:\WINDOWS\System32\drivers\tcpip.sys from store',
        '2026-11-21 14:00:04, Info                  CSI    00000014 [SR] Repairing 1 components',
        '2026-11-21 14:00:04, Info                  CSI    00000015 [SR] Repair complete'
    )
    $Script:CbsNaoReparadoPt = @(
        '2026-11-21 14:00:01, Info                  CSI    00000010 [SR] Verifying 100 components',
        '2026-11-21 14:00:02, Info                  CSI    00000011 [SR] Beginning Verify and Repair transaction',
        '2026-11-21 14:00:03, Info                  CSI    00000012 [SR] Cannot repair member file [l:16]"explorer.exe.mui" of Microsoft-Windows-Explorer.Resources, version 10.0.19041.1, arch amd64, culture pt-BR in the store, hash mismatch',
        '2026-11-21 14:00:03, Info                  CSI    00000013 [SR] Could not reproject corrupted file \??\C:\WINDOWS\System32\pt-BR\explorer.exe.mui; source file in store is also corrupted',
        '2026-11-21 14:00:04, Info                  CSI    00000014 [SR] Repair complete'
    )
    $Script:CbsReparadoPt = @(
        '2026-11-21 14:00:01, Info                  CSI    00000010 [SR] Verifying 100 components',
        '2026-11-21 14:00:03, Info                  CSI    00000011 [SR] Repaired file \SystemRoot\WinSxS\Temp\PendingRenames\pt-BR\notepad.exe.mui by copying from backup',
        '2026-11-21 14:00:04, Info                  CSI    00000012 [SR] Repair complete'
    )
    # Texto de tela do sfc (UTF-16 lido como bytes) dizendo o CONTRARIO do CBS: nao pode decidir nada.
    $Script:TelaSfcPt = @('V' + [char]0 + 'e' + [char]0 + 'r' + [char]0 + ' ' + [char]0 + '4' + [char]0 + '5' + [char]0 + '%' + [char]0,
        'A Proteção de Recursos do Windows não encontrou nenhuma violação de integridade.')
    $Script:TelaDism = @('Ferramenta de Gerenciamento e Manutenção de Imagens de Implantação', 'Versão: 10.0.19041.572',
        '[=========                  15.0%                          ]',
        '[==========================50.0%                          ]',
        '[==========================100.0%==========================] A operação de restauração foi concluída com êxito.',
        'A operação foi concluída com êxito.')
}

AfterAll { Remove-Item -LiteralPath (Join-Path $env:TEMP 'NexTuneTeste') -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'saude.ps1: funcoes puras' {
    Context 'Get-EstadoVerificacao' {
        It 'mapeia o enum ImageHealthState (nao localizado)' {
            Get-EstadoVerificacao 'Healthy' | Should -Be 'ok'
            Get-EstadoVerificacao 'Repairable' | Should -Be 'reparavel'
            Get-EstadoVerificacao 'NonRepairable' | Should -Be 'irreparavel'
        }
        It 'valor desconhecido devolve nulo, nunca chuta' {
            Get-EstadoVerificacao 'Saudável' | Should -BeNullOrEmpty
            Get-EstadoVerificacao '' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-EstadoDism' {
        It '0 e 3010 sao sucesso' {
            Get-EstadoDism 0 | Should -Be 'ok'
            Get-EstadoDism 3010 | Should -Be 'ok'
        }
        It 'sem fonte de reparo, com o codigo negativo (Int32) ou sem sinal' {
            Get-EstadoDism ([int]-2146498529) | Should -Be 'semFonte'
            Get-EstadoDism 0x800F081FL | Should -Be 'semFonte'
            Get-EstadoDism 0x800F0906L | Should -Be 'semFonte'
            Get-EstadoDism 0x800F0907L | Should -Be 'semFonte'
        }
        It 'codigo que nao conhecemos vira desconhecido' {
            Get-EstadoDism 87 | Should -Be 'desconhecido'
            Get-EstadoDism 1 | Should -Be 'desconhecido'
        }
    }

    Context 'Get-PctLinha' {
        It 'tira a porcentagem da barra do DISM' {
            Get-PctLinha '[=========                  15.0%                          ]' | Should -Be 15
            Get-PctLinha '[==========================100.0%==========================] A operação foi concluída.' | Should -Be 100
            Get-PctLinha '62,3%' | Should -Be 62
        }
        It 'le a porcentagem da saida UTF-16 do sfc' {
            Get-PctLinha $Script:TelaSfcPt[0] | Should -Be 45
        }
        It 'linha sem porcentagem ou fora de 0..100 devolve nulo' {
            Get-PctLinha 'Versão: 10.0.19041.572' | Should -BeNullOrEmpty
            Get-PctLinha '150%' | Should -BeNullOrEmpty
            Get-PctLinha '' | Should -BeNullOrEmpty
        }
    }

    Context 'Select-LinhaSr' {
        It 'fica so com as linhas [SR] da sessao atual (a partir do inicio do sfc)' {
            $antigas = @('2026-11-20 09:00:00, Info                  CSI    00000001 [SR] Cannot repair member file [l:5]"x.dll" of X')
            $outra = @('2026-11-21 14:00:02, Info                  CBS    TiWorker: Client requests SFP repair object.')
            $r = @(Select-LinhaSr ($antigas + $outra + $Script:CbsLimpoEn) ([datetime]'2026-11-21 14:00:00'))
            $r.Count | Should -Be 6
            ($r -join "`n") | Should -Not -Match 'Cannot repair'
        }
        It 'sem linhas devolve lista vazia' {
            @(Select-LinhaSr @() ([datetime]'2026-11-21 14:00:00')).Count | Should -Be 0
        }
    }

    Context 'Get-EstadoSfc (Review Focus 3: so codigo de saida e CBS.log)' {
        It 'sessao limpa com codigo 0: semProblemas ("Repairing 0 components" nao conta como reparo)' {
            Get-EstadoSfc 0 $Script:CbsLimpoEn | Should -Be 'semProblemas'
        }
        It 'CBS em ingles com arquivo reparado: reparado' {
            Get-EstadoSfc 0 $Script:CbsReparadoEn | Should -Be 'reparado'
        }
        It 'Windows pt-BR com arquivo reparado: reparado' {
            Get-EstadoSfc 0 $Script:CbsReparadoPt | Should -Be 'reparado'
        }
        It 'Windows pt-BR com arquivo que nao deu para reparar: naoReparado, mesmo com codigo 0' {
            Get-EstadoSfc 0 $Script:CbsNaoReparadoPt | Should -Be 'naoReparado'
        }
        It 'sem linhas [SR] (CBS.log ilegivel) ou codigo diferente de 0 sem evidencia: desconhecido' {
            Get-EstadoSfc 0 @() | Should -Be 'desconhecido'
            Get-EstadoSfc 1 $Script:CbsLimpoEn | Should -Be 'desconhecido'
        }
    }
}

Describe 'saude.ps1: verificar' {
    It 'reparavel vem do enum simulado' {
        $r = Invoke-Saude 'verificar' @{ simular = @{ saude = 'Repairable' } }
        $r.ok | Should -BeTrue
        $r.dados.estado | Should -Be 'reparavel'
        $r.dados.detalhe | Should -Not -BeNullOrEmpty
    }
    It 'saudavel e irreparavel' {
        (Invoke-Saude 'verificar' @{ simular = @{ saude = 'Healthy' } }).dados.estado | Should -Be 'ok'
        (Invoke-Saude 'verificar' @{ simular = @{ saude = 'NonRepairable' } }).dados.estado | Should -Be 'irreparavel'
    }
    It 'sem simulacao em teste nao chama o DISM e devolve ok' {
        Mock Repair-WindowsImage { throw 'nao deveria rodar' }
        (Invoke-Saude 'verificar').dados.estado | Should -Be 'ok'
        Should -Invoke Repair-WindowsImage -Times 0
    }
    It 'estado que nao conhecemos falha em vez de chutar' {
        $r = Invoke-Saude 'verificar' @{ simular = @{ saude = 'Outro' } }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'Outro'
    }
    It 'acao desconhecida falha' {
        (Invoke-Saude 'apagar').ok | Should -BeFalse
    }
}

Describe 'saude.ps1: reparar' {
    BeforeEach { Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue }

    It 'exige confirmado:true' {
        $r = Invoke-Saude 'reparar' @{ simular = @{} }
        $r.ok | Should -BeFalse
        $r.erro | Should -Match 'confirma'
        Test-Path -LiteralPath (Join-Path $Script:PastaT 'dism-restorehealth.txt') | Should -BeFalse
    }
    It 'tudo certo: DISM ok, SFC semProblemas, sem reiniciar; progresso do DISM vem da barra' {
        $sim = @{ dism = @{ codigo = 0; saida = $Script:TelaDism }; sfc = @{ codigo = 0; saida = $Script:TelaSfcPt; cbs = $Script:CbsLimpoEn } }
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.dism.codigo | Should -Be 0
        $r.dados.dism.estado | Should -Be 'ok'
        $r.dados.sfc.codigo | Should -Be 0
        $r.dados.sfc.estado | Should -Be 'semProblemas'
        $r.dados.precisaReiniciar | Should -BeFalse
        $r.dados.detalhe | Should -Not -BeNullOrEmpty
        $p = Get-Porcentagem
        $p | Should -Contain 9      # 15% do DISM = 9% do total (DISM ocupa 0..60)
        $p | Should -Contain 30     # 50% do DISM
        $p | Should -Contain 100
        Test-Path -LiteralPath (Join-Path $Script:PastaT 'dism-restorehealth.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Script:PastaT 'sfc-scannow.txt') | Should -BeTrue
    }
    It 'CBS em ingles com reparo: reparado e pede reinicio' {
        $sim = @{ dism = @{ codigo = 0 }; sfc = @{ codigo = 0; cbs = $Script:CbsReparadoEn } }
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = $sim }
        $r.dados.sfc.estado | Should -Be 'reparado'
        $r.dados.precisaReiniciar | Should -BeTrue
    }
    It 'Windows pt-BR: a tela diz "nenhuma violacao", o CBS diz que nao reparou: vale o CBS' {
        $sim = @{ dism = @{ codigo = 0 }; sfc = @{ codigo = 0; saida = $Script:TelaSfcPt; cbs = $Script:CbsNaoReparadoPt } }
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = $sim }
        $r.ok | Should -BeTrue
        $r.dados.sfc.estado | Should -Be 'naoReparado'
    }
    It 'sessoes antigas do CBS.log nao contam' {
        $antiga = @('2026-11-20 09:00:00, Info                  CSI    00000001 [SR] Cannot repair member file [l:5]"x.dll" of X')
        $sim = @{ dism = @{ codigo = 0 }; sfc = @{ codigo = 0; cbs = ($antiga + $Script:CbsLimpoEn); desde = '2026-11-21T14:00:00' } }
        (Invoke-Saude 'reparar' @{ confirmado = $true; simular = $sim }).dados.sfc.estado | Should -Be 'semProblemas'
    }
    It 'DISM 3010 pede reinicio; DISM sem fonte nao impede o SFC' {
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = @{ dism = @{ codigo = 3010 }; sfc = @{ codigo = 0; cbs = $Script:CbsLimpoEn } } }
        $r.dados.dism.estado | Should -Be 'ok'
        $r.dados.precisaReiniciar | Should -BeTrue
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = @{ dism = @{ codigo = -2146498529 }; sfc = @{ codigo = 0; cbs = $Script:CbsReparadoPt } } }
        $r.ok | Should -BeTrue
        $r.dados.dism.estado | Should -Be 'semFonte'
        $r.dados.sfc.estado | Should -Be 'reparado'
    }
    It 'codigo do DISM que nao conhecemos vira desconhecido, com o codigo no detalhe' {
        $r = Invoke-Saude 'reparar' @{ confirmado = $true; simular = @{ dism = @{ codigo = 1726 }; sfc = @{ codigo = 0; cbs = $Script:CbsLimpoEn } } }
        $r.dados.dism.estado | Should -Be 'desconhecido'
        $r.dados.detalhe | Should -Match '1726'
    }
}

Describe 'saude.ps1: cancelar no meio (host)' {
    AfterEach {
        if ($null -ne $Script:Proc -and -not $Script:Proc.HasExited) { try { $Script:Proc.Kill() } catch { $null = $_ } }
        if ($null -ne $Script:Proc) { $Script:Proc.Dispose() }
    }
    It 'cancelar durante o DISM devolve "cancelado" e mata o processo filho' {
        Remove-Item -LiteralPath $Script:PastaT -Recurse -Force -ErrorAction SilentlyContinue
        $Script:Proc = Start-HostTeste
        Send-Comando $Script:Proc @{ id = 'r1'; modulo = 'saude'; acao = 'reparar'; params = @{ confirmado = $true; simular = @{ demorarSegundos = 30 } }; teste = $true }
        $linha = Read-Linha $Script:Proc 20000
        $linha | Should -Match '^@@PROGRESS '
        # o processo filho (que faz o papel do DISM) ja existe
        $limite = [DateTime]::UtcNow.AddSeconds(10)
        $filhos = @()
        while ($filhos.Count -eq 0 -and [DateTime]::UtcNow -lt $limite) {
            $filhos = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Script:Proc.Id) AND Name = 'PING.EXE'")
        }
        $filhos.Count | Should -Be 1
        Send-Comando $Script:Proc @{ id = 'c1'; modulo = 'host'; acao = 'cancelar'; params = @{ alvo = 'r1' }; teste = $true }
        $r = Read-Resultado $Script:Proc 'r1' 5000
        $r.ok | Should -BeFalse
        $r.erro | Should -Be 'cancelado'
        # o host reserva o resultado antes de matar os filhos: espera um pouco pela morte do processo
        $limite = [DateTime]::UtcNow.AddSeconds(5)
        while ($null -ne (Get-Process -Id $filhos[0].ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $limite) { Start-Sleep -Milliseconds 100 }
        Get-Process -Id $filhos[0].ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        # a acao parou ali: nao seguiu para o SFC (no teste, o marcador dele)
        Start-Sleep -Milliseconds 500
        Test-Path -LiteralPath (Join-Path $Script:PastaT 'sfc-scannow.txt') | Should -BeFalse
    }
}
