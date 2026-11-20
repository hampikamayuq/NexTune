BeforeAll {
    . "$PSScriptRoot\_helpers.ps1"
    $Script:Scripts = Split-Path -Parent $PSScriptRoot
    $Script:EcoDestino = Join-Path $Script:Scripts 'eco.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\eco.ps1') -Destination $Script:EcoDestino -Force
}

AfterAll {
    if (Test-Path -LiteralPath $Script:EcoDestino) { Remove-Item -LiteralPath $Script:EcoDestino -Force }
}

Describe 'host.ps1' {
    BeforeEach {
        $Script:Proc = $null
    }
    AfterEach {
        if ($null -ne $Script:Proc -and -not $Script:Proc.HasExited) {
            try { $Script:Proc.Kill() } catch { $null = $_ }
        }
        if ($null -ne $Script:Proc) { $Script:Proc.Dispose() }
    }

    Context 'Comandos basicos' {
        It 'ping responde @@RESULT com id, ok e pid inteiro' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'p1'; modulo = 'host'; acao = 'ping'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'p1' 15000
            $r | Should -Not -BeNullOrEmpty
            $r.id | Should -Be 'p1'
            $r.ok | Should -BeTrue
            $r.dados.pid | Should -BeOfType [int]
            $r.dados.pid | Should -Be $Script:Proc.Id
            $r.dados.versao | Should -Match '^5\.1'
        }

        It 'modulo inexistente responde ok=false com "nao permitido"' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'm1'; modulo = 'inexistente'; acao = 'x'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'm1' 15000
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'nao permitido'
        }

        It 'sair termina o processo com ExitCode 0' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 's1'; modulo = 'host'; acao = 'sair'; params = @{}; teste = $true }
            $Script:Proc.WaitForExit(15000) | Should -BeTrue
            $Script:Proc.ExitCode | Should -Be 0
        }

        It 'linha de stdin invalida responde id vazio e o host continua' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc $null 'isto nao e json'
            $r = Read-Resultado $Script:Proc '' 15000
            $r | Should -Not -BeNullOrEmpty
            $r.id | Should -Be ''
            $r.ok | Should -BeFalse
            Send-Comando $Script:Proc @{ id = 'p2'; modulo = 'host'; acao = 'ping'; params = @{}; teste = $true }
            $r2 = Read-Resultado $Script:Proc 'p2' 15000
            $r2.ok | Should -BeTrue
        }
    }

    Context 'Modulo de teste eco' {
        It 'devolve params intactos (acentos e aspas)' {
            $Script:Proc = Start-HostTeste
            $caminho = 'C:\Users\João Ção\Área de Trabalho\"x" y'
            Send-Comando $Script:Proc @{ id = 'e1'; modulo = 'eco'; acao = 'eco'; params = @{ caminho = $caminho; n = 5 }; teste = $true }
            $r = Read-Resultado $Script:Proc 'e1' 20000
            $r.ok | Should -BeTrue
            $r.dados.caminho | Should -BeExactly $caminho
            $r.dados.n | Should -Be 5
        }

        It 'passa o flag teste para Invoke-Acao' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 't1'; modulo = 'eco'; acao = 'teste'; params = @{}; teste = $true }
            (Read-Resultado $Script:Proc 't1' 20000).dados.teste | Should -BeTrue
        }

        It 'excecao na acao vira ok=false com a mensagem' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'f1'; modulo = 'eco'; acao = 'falhar'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'f1' 20000
            $r.ok | Should -BeFalse
            $r.erro | Should -Match 'falha de proposito'
        }

        It 'acao que termina sem Send-Result vira ok=false em ate 5 s' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'x1'; modulo = 'eco'; acao = 'semResultado'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'x1' 5000
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeFalse
            $r.erro | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Concorrencia e cancelamento' {
        It 'cancelar interrompe a acao em menos de 5 s com erro cancelado' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'd1'; modulo = 'eco'; acao = 'demorar'; params = @{ segundos = 30 }; teste = $true }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Send-Comando $Script:Proc @{ id = 'c1'; modulo = 'host'; acao = 'cancelar'; params = @{ alvo = 'd1' }; teste = $true }
            $r = Read-Resultado $Script:Proc 'd1' 5000
            $sw.Stop()
            $r | Should -Not -BeNullOrEmpty
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'cancelado'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
            (Read-Resultado $Script:Proc 'c1' 5000).ok | Should -BeTrue
        }

        It 'cancelar emite um unico resultado para o alvo e nao quebra comandos nativos depois' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'n0'; modulo = 'eco'; acao = 'nativo'; params = @{}; teste = $true }
            (Read-Resultado $Script:Proc 'n0' 20000).dados.saida | Should -Be 'ola'
            Send-Comando $Script:Proc @{ id = 'd2'; modulo = 'eco'; acao = 'demorar'; params = @{ segundos = 30 }; teste = $true }
            Send-Comando $Script:Proc @{ id = 'c2'; modulo = 'host'; acao = 'cancelar'; params = @{ alvo = 'd2' }; teste = $true }
            $vistos = @()
            $limite = [DateTime]::UtcNow.AddSeconds(2)
            while ([DateTime]::UtcNow -lt $limite) {
                $linha = Read-Linha $Script:Proc 300
                if ($linha -and $linha.StartsWith('@@RESULT ')) { $vistos += ($linha.Substring(9) | ConvertFrom-Json).id }
            }
            @($vistos | Where-Object { $_ -eq 'd2' }).Count | Should -Be 1
            Send-Comando $Script:Proc @{ id = 'n1'; modulo = 'eco'; acao = 'nativo'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'n1' 20000
            $r.ok | Should -BeTrue
            $r.dados.saida | Should -Be 'ola'
        }

        It 'sair com acao em curso responde cancelado e termina com ExitCode 0' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'd3'; modulo = 'eco'; acao = 'demorar'; params = @{ segundos = 30 }; teste = $true }
            Send-Comando $Script:Proc @{ id = 's3'; modulo = 'host'; acao = 'sair'; params = @{}; teste = $true }
            $r = Read-Resultado $Script:Proc 'd3' 10000
            $r.ok | Should -BeFalse
            $r.erro | Should -Be 'cancelado'
            $Script:Proc.WaitForExit(10000) | Should -BeTrue
            $Script:Proc.ExitCode | Should -Be 0
        }

        It 'duas acoes rodam em paralelo (a de 0,5 s responde antes da de 2 s)' {
            $Script:Proc = Start-HostTeste
            Send-Comando $Script:Proc @{ id = 'l1'; modulo = 'eco'; acao = 'demorar'; params = @{ segundos = 2 }; teste = $true }
            Send-Comando $Script:Proc @{ id = 'r1'; modulo = 'eco'; acao = 'demorar'; params = @{ segundos = 0.5 }; teste = $true }
            $ordem = @()
            while ($ordem.Count -lt 2) {
                $linha = Read-Linha $Script:Proc 15000
                $linha | Should -Not -BeNullOrEmpty
                if ($linha.StartsWith('@@RESULT ')) { $ordem += ($linha.Substring(9) | ConvertFrom-Json).id }
            }
            $ordem[0] | Should -Be 'r1'
            $ordem[1] | Should -Be 'l1'
        }
    }

    Context 'Ocioso' {
        It 'sem comandos termina sozinho com ExitCode 0' {
            $Script:Proc = Start-HostTeste -Ocioso 2
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $Script:Proc.WaitForExit(10000) | Should -BeTrue
            $sw.Stop()
            $Script:Proc.ExitCode | Should -Be 0
        }
    }
}
