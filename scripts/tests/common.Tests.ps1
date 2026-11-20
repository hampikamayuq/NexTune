BeforeAll {
    . "$PSScriptRoot\..\common.ps1"
    . "$PSScriptRoot\_helpers.ps1"

    function Invoke-Capturando {
        param([scriptblock]$Bloco)
        $sw = New-Object System.IO.StringWriter
        [Console]::SetOut($sw)
        try { & $Bloco } finally { [Console]::SetOut($Script:SaidaOriginal) }
        return $sw.ToString().TrimEnd("`r", "`n")
    }
}

AfterAll {
    $t = Join-Path $env:TEMP 'OtimizadorTeste'
    if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'common.ps1' {
BeforeEach {
    $Script:SaidaOriginal = [Console]::Out
}
AfterEach {
    [Console]::SetOut($Script:SaidaOriginal)
    Set-Saida $null
}
Context 'Protocolo de saida' {
    It 'Send-Result escreve linha @@RESULT com JSON' {
        $linha = Invoke-Capturando { Send-Result 'a1' @{ x = 1 } }
        $linha.StartsWith('@@RESULT ') | Should -BeTrue
        $j = $linha.Substring(9) | ConvertFrom-Json
        $j.id | Should -Be 'a1'
        $j.ok | Should -BeTrue
        $j.dados.x | Should -Be 1
    }
    It 'Send-Result com erro' {
        $linha = Invoke-Capturando { Send-Result 'a1' $null -Ok $false -Erro 'falhou' }
        $j = $linha.Substring(9) | ConvertFrom-Json
        $j.ok | Should -BeFalse
        $j.erro | Should -Be 'falhou'
    }
    It 'Send-Progress escreve @@PROGRESS' {
        $linha = Invoke-Capturando { Send-Progress 'a1' 40 'Medindo' }
        $linha.StartsWith('@@PROGRESS ') | Should -BeTrue
        $j = $linha.Substring(11) | ConvertFrom-Json
        $j.pct | Should -Be 40
        $j.id | Should -Be 'a1'
        $j.msg | Should -Be 'Medindo'
    }
    It 'Send-Log escreve @@LOG com tipo e ruta' {
        $linha = Invoke-Capturando { Send-Log 'a1' 'hallado' 'achou' 'C:\x' }
        $linha.StartsWith('@@LOG ') | Should -BeTrue
        $j = $linha.Substring(6) | ConvertFrom-Json
        $j.tipo | Should -Be 'hallado'
        $j.ruta | Should -Be 'C:\x'
    }
    It 'Set-Saida redireciona para o escritor informado' {
        $sw = New-Object System.IO.StringWriter
        Set-Saida $sw
        Send-Progress 'a1' 5 'x'
        $sw.ToString() | Should -Match '^@@PROGRESS '
    }
}

Context 'Test-ProtectedPath' {
    It 'protege <_>' -ForEach @(
        $env:windir,
        "$env:windir\",
        $env:windir.ToUpper(),
        "$env:SystemDrive\PROGRA~1",
        "$env:ProgramFiles\Microsoft\EdgeWebView",
        "${env:ProgramFiles(x86)}\Microsoft\EdgeCore\1.2.3",
        "$env:ProgramFiles\Microsoft\Edge",
        "$env:ProgramFiles\WindowsApps\X",
        "$env:ProgramData\Otimizador\Quarentena",
        ''
    ) {
        Test-ProtectedPath $_ | Should -BeTrue
    }
    It 'protege null' {
        Test-ProtectedPath $null | Should -BeTrue
    }
    It 'nao protege ProgramaQualquer' {
        Test-ProtectedPath "$env:ProgramFiles\ProgramaQualquer" | Should -BeFalse
    }
    It 'nao protege LOCALAPPDATA\Programs\Editor' {
        Test-ProtectedPath "$env:LOCALAPPDATA\Programs\Editor" | Should -BeFalse
    }
}

Context 'Pastas e perfil' {
    It 'Get-AppPastas $true cria as 5 subpastas sob TEMP' {
        $p = Get-AppPastas $true
        $p.Base.StartsWith($env:TEMP) | Should -BeTrue
        foreach ($k in 'Quarentena', 'Logs', 'Backups', 'Estado', 'Ajustes') {
            Test-Path -LiteralPath $p[$k] | Should -BeTrue
        }
    }
    It 'Get-Perfil sem arquivo devolve null' {
        $p = Get-AppPastas $true
        Remove-Item -LiteralPath (Join-Path $p.Estado 'perfil.json') -Force -ErrorAction SilentlyContinue
        Get-Perfil $true | Should -BeNullOrEmpty
    }
    It 'Set-Perfil e Get-Perfil fazem ida e volta' {
        Set-Perfil @{ classe = 'gamer'; disco = 'hdd'; manual = $false } $true
        $r = Get-Perfil $true
        $r.classe | Should -Be 'gamer'
        $r.disco | Should -Be 'hdd'
        $r.manual | Should -BeFalse
    }
    It 'Write-AppLog anexa ao log do mes' {
        Write-AppLog 'mensagem de teste' $true
        $p = Get-AppPastas $true
        $arq = Join-Path $p.Logs ((Get-Date).ToString('yyyy-MM') + '.log')
        (Get-Content -LiteralPath $arq -Raw) | Should -Match 'mensagem de teste'
    }
}

Context 'Get-PathSize' {
    It 'soma os arquivos' {
        $d = New-PastaTeste 'size'
        [IO.File]::WriteAllBytes("$d\a.bin", (New-Object byte[] 10))
        [IO.File]::WriteAllBytes("$d\b.bin", (New-Object byte[] 20))
        Get-PathSize $d | Should -Be 30
    }
}
}
