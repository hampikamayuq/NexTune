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
    $t = Join-Path $env:TEMP 'NexTuneTeste'
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
        "$env:ProgramData\NexTune\Quarentena",
        "$env:SystemDrive\PROGRA~1\Common Files\naoexiste\x",
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
    It 'caminho inexistente sob nome curto 8.3 e tratado como o caminho expandido' {
        # PROGRA~1\naoexiste\x expande para Program Files\naoexiste\x, igual a ProgramaQualquer: nao protegido
        Test-ProtectedPath "$env:SystemDrive\PROGRA~1\naoexiste\x" | Should -BeFalse
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
    It 'Get-Perfil sem disco devolve null' {
        $p = Get-AppPastas $true
        [IO.File]::WriteAllText((Join-Path $p.Estado 'perfil.json'), '{"classe":"x"}')
        Get-Perfil $true | Should -BeNullOrEmpty
    }
    It 'Get-Perfil com JSON que nao e objeto devolve null' {
        $p = Get-AppPastas $true
        [IO.File]::WriteAllText((Join-Path $p.Estado 'perfil.json'), '[]')
        Get-Perfil $true | Should -BeNullOrEmpty
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
    It 'nao conta o alvo de uma junction (filha ou raiz)' {
        $d = New-PastaTeste 'size'
        $alvo = New-PastaTeste 'sizeAlvo'
        [IO.File]::WriteAllBytes("$d\a.bin", (New-Object byte[] 10))
        [IO.File]::WriteAllBytes("$alvo\grande.bin", (New-Object byte[] 5000))
        cmd /c mklink /J "$d\jn" "$alvo" | Out-Null
        $raizJ = Join-Path $env:TEMP 'NexTuneTeste\sizeRaizJ'
        cmd /c mklink /J "$raizJ" "$alvo" | Out-Null
        try {
            Get-PathSize $d | Should -Be 10
            Get-PathSize $raizJ | Should -Be 0
        } finally {
            cmd /c rmdir "$d\jn" | Out-Null
            cmd /c rmdir "$raizJ" | Out-Null
        }
    }
    It 'AntesDe conta so arquivos mais antigos que a data' {
        $d = New-PastaTeste 'sizeIdade'
        [IO.File]::WriteAllBytes("$d\velho.bin", (New-Object byte[] 10))
        [IO.File]::WriteAllBytes("$d\novo.bin", (New-Object byte[] 20))
        (Get-Item -LiteralPath "$d\velho.bin").LastWriteTime = (Get-Date).AddDays(-3)
        Get-PathSize $d (Get-Date).AddDays(-1) | Should -Be 10
    }
}

Context 'Seguranca da pasta de dados' {
    It 'Test-SidConfiavel aceita SYSTEM, Administradores e TrustedInstaller' {
        Test-SidConfiavel 'S-1-5-18' | Should -BeTrue
        Test-SidConfiavel 'S-1-5-32-544' | Should -BeTrue
        Test-SidConfiavel 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464' | Should -BeTrue
        Test-SidConfiavel 'S-1-5-32-545' | Should -BeFalse
        Test-SidConfiavel ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Should -BeFalse
        Test-SidConfiavel $null | Should -BeFalse
    }
    It 'Set-SegurancaPastaApp cria a pasta com DACL protegida e dono Administradores' {
        $d = Join-Path $env:TEMP 'NexTuneTeste\daclNova'
        Set-SegurancaPastaApp $d
        $acl = Get-Acl -LiteralPath $d
        $acl.AreAccessRulesProtected | Should -BeTrue
        $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        $regras = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $regras.Count | Should -Be 3
        foreach ($r in $regras) {
            $r.IsInherited | Should -BeFalse
            $r.AccessControlType | Should -Be 'Allow'
            $r.InheritanceFlags | Should -Be ([Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
        }
        $porSid = @{}
        foreach ($r in $regras) { $porSid[$r.IdentityReference.Value] = $r.FileSystemRights }
        $porSid['S-1-5-18'] | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
        $porSid['S-1-5-32-544'] | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
        # O Windows grava ReadAndExecute com SYNCHRONIZE; o que importa: le e executa, nunca escreve.
        $usuarios = [int]$porSid['S-1-5-32-545']
        ($usuarios -band [int][Security.AccessControl.FileSystemRights]::ReadAndExecute) | Should -Be ([int][Security.AccessControl.FileSystemRights]::ReadAndExecute)
        ($usuarios -band [int][Security.AccessControl.FileSystemRights]::Write) | Should -Be 0
        ($usuarios -band [int][Security.AccessControl.FileSystemRights]::Delete) | Should -Be 0
    }
    It 'Set-SegurancaPastaApp repara dono e DACL de pasta existente' {
        $d = New-PastaTeste 'daclExistente'
        $acl = Get-Acl -LiteralPath $d
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $d -AclObject $acl
        (Get-Acl -LiteralPath $d).AreAccessRulesProtected | Should -BeFalse
        Set-SegurancaPastaApp $d
        $novo = Get-Acl -LiteralPath $d
        $novo.AreAccessRulesProtected | Should -BeTrue
        Test-SidConfiavel $novo.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeTrue
        @($novo.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])).Count | Should -Be 3
    }
}
}
