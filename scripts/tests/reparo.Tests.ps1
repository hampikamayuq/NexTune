BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\..\reparo.ps1"
    . "$PSScriptRoot\_helpers.ps1"
}

Describe 'reparo.ps1: funcoes puras' {
    Context 'Get-MensagemWinget' {
        It 'traduz os codigos conhecidos e inclui o codigo em hexadecimal' {
            $m = Get-MensagemWinget 0x8A150110L
            $m | Should -Match 'dependência'
            $m | Should -Match '0x8A150110'
            (Get-MensagemWinget 0x8A15010CL) | Should -Match 'fech'
            (Get-MensagemWinget 0x8A150107L) | Should -Match 'internet'
        }
        It 'aceita o codigo como inteiro de 32 bits negativo' {
            (Get-MensagemWinget ([int]-1978334964)) | Should -Match '0x8A15010C'
        }
        It 'codigo desconhecido vira mensagem generica com o codigo, nunca vazia' {
            (Get-MensagemWinget 0x12345678L) | Should -Be 'winget terminou com código 0x12345678'
        }
    }

    Context 'ConvertTo-GuidCompactado' {
        It 'converte para a forma do Windows Installer' {
            ConvertTo-GuidCompactado '{E5281CF4-57AC-41C9-8034-00F8428B8951}' | Should -Be '4FC1825ECA759C140843008F24B89815'
        }
        It 'guid invalido e recusado' {
            { ConvertTo-GuidCompactado 'nao-guid' } | Should -Throw
            { ConvertTo-GuidCompactado '{E5281CF4-57AC-41C9-8034-00F8428B895}' } | Should -Throw
            { ConvertTo-GuidCompactado '' } | Should -Throw
        }
    }

    Context 'Test-ProdutoOrfao' {
        BeforeAll {
            $Script:Pasta = New-PastaTeste 'reparo-orfao'
            $Script:Msi = Join-Path $Script:Pasta 'x.msi'
            Set-Content -LiteralPath $Script:Msi -Value 'msi'
            $Script:Origem = New-PastaTeste 'reparo-origem'
            Set-Content -LiteralPath (Join-Path $Script:Origem 'vc.msi') -Value 'msi'
        }
        It 'cache local existe: nao e orfao' {
            Test-ProdutoOrfao @{ localPackage = $Script:Msi; packageName = 'vc.msi'; origens = @() } | Should -BeFalse
        }
        It 'origem acessivel salva o produto' {
            Test-ProdutoOrfao @{ localPackage = 'C:\nao\existe.msi'; packageName = 'vc.msi'; origens = @($Script:Origem) } | Should -BeFalse
        }
        It 'sem cache e sem origem utilizavel: orfao' {
            Test-ProdutoOrfao @{ localPackage = 'C:\nao\existe.msi'; packageName = 'vc.msi'; origens = @('W:\Data\x64\', $Script:Origem + 'x') } | Should -BeTrue
        }
        It 'localPackage vazio e sem origens: orfao, sem excecao' {
            Test-ProdutoOrfao @{ localPackage = ''; packageName = ''; origens = @() } | Should -BeTrue
            Test-ProdutoOrfao @{ localPackage = $null; packageName = $null; origens = $null } | Should -BeTrue
        }
    }
}
