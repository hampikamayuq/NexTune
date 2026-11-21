# NexTune

Diagnóstico, limpeza e otimização do Windows com segurança. Gratuito, em português e de código aberto (MIT).

Site: [hampikamayuq.github.io/NexTune](https://hampikamayuq.github.io/NexTune/) · Download: [última versão](https://github.com/hampikamayuq/NexTune/releases/latest)

Status: em desenvolvimento; a primeira versão (0.1.0) está em teste.

## O que ele faz

O NexTune olha o seu PC primeiro (processador, memória, tipo de disco) e só então sugere o que vale a pena. Nada é feito sem você clicar, e tudo que ele muda pode ser desfeito.

- **Limpeza** por categorias, ciente do perfil da máquina; o que não se recria pede confirmação dupla.
- **Programas**: lista pré-instalados de fábrica e apps da Store, desinstala em silêncio quando dá, leva os restos para a quarentena.
- **Inicialização**: o que abre com o Windows, com impacto medido, e liga/desliga reversível.
- **Ajustes do Windows** com backup antes da escrita e restauração exata do valor anterior.
- **Disco**: verificação só de leitura, correção agendada para o próximo reinício, desfragmentar HDD ou TRIM em SSD, nunca o contrário.
- **Atualizações** do Windows e dos programas (winget), só o que você marcar. Quando uma falha, o NexTune explica o motivo em português em vez de mostrar só o código.
- **Reparo do instalador**: acha programas cujo arquivo de instalação sumiu do Windows (erros 1603 e 1612 ao atualizar ou desinstalar) e, se você marcar, remove só o registro quebrado, com backup na quarentena.
- **Modo Jogo**: pede para fechar programas, pausa serviços, troca o plano de energia e desfaz tudo ao sair.
- **Bandeja, lembretes e atualizador** próprio (assinatura minisign, GitHub Releases).

## O que ele nunca faz

- Não apaga nada seu sem quarentena (7 dias para restaurar), backup e ponto de restauração.
- Não mata programas: pede para fechar e respeita o "salvar alterações?". Nunca fecha o Windows, drivers, áudio ou o seu jogo.
- Não usa a rede a partir da interface; a única conexão é HTTPS com o GitHub para verificar atualizações do próprio NexTune.
- Não envia dados, não tem telemetria, não mostra anúncios.
- Não mexe em permissões (ACLs) de pastas do Windows, nem no instalador nem no desinstalador.

## Conferir o arquivo baixado

Cada versão traz um `SHA256.txt`. Na pasta de Downloads:

```
certutil -hashfile NexTune_0.1.0_x64-setup.exe SHA256
```

O hash tem que ser igual ao do `SHA256.txt` da mesma versão.

## Por que o Windows avisa

O NexTune ainda não tem assinatura digital paga, então o SmartScreen mostra "O Windows protegeu o computador": clique em **Mais informações** e **Executar assim mesmo**. Antivírus às vezes marcam ferramentas de limpeza por engano; o código está aberto para conferência.

**Smart App Control** (Windows 11 novo de fábrica) bloqueia programas sem assinatura e não oferece "executar assim mesmo". Desligá-lo é decisão do usuário e é irreversível (só volta reinstalando o Windows). A versão assinada é prioridade da série 1.x; o pedido à SignPath Foundation entra logo após a primeira release pública.

## Como auditar

- As ações que tocam o sistema são scripts PowerShell legíveis em `scripts/`; o Rust em `src-tauri/` só valida parâmetros, roteia e fala com o PowerShell.
- O instalador é compilado em público pelo GitHub Actions (`.github/workflows/build.yml`), que publica o hash de cada versão.
- Especificação completa: [docs/superpowers/specs/2026-11-20-otimizador-design.md](docs/superpowers/specs/2026-11-20-otimizador-design.md).

---

## Para desenvolvedores

Planos de implementação: [1 fundação, diagnóstico, limpeza](docs/superpowers/plans/2026-11-20-fundacao-diagnostico-limpeza.md) · [2 programas, quarentena](docs/superpowers/plans/2026-11-20-programas-quarentena.md) · [3 inicialização, ajustes](docs/superpowers/plans/2026-11-20-inicializacao-ajustes-windows.md) · [4 disco, atualizações](docs/superpowers/plans/2026-11-20-disco-atualizacoes.md) · [5 modo jogo, bandeja, lembretes, atualizador](docs/superpowers/plans/2026-11-21-modo-jogo-bandeja-lembretes.md) · [6 release, site, desinstalador](docs/superpowers/plans/2026-11-21-release-site-desinstalador.md) · [7 reparo do instalador](docs/superpowers/plans/2026-11-21-reparo-instalador.md)

### Verificação

- Tudo de uma vez (Windows): `powershell -NoProfile -ExecutionPolicy Bypass -File tools/ci-local.ps1` (`-SoTestes` pula o build; `-SoBuild` faz só o build; `-Release` gera os artefatos assinados do atualizador e exige `TAURI_SIGNING_PRIVATE_KEY`). O GitHub Actions roda o mesmo script a cada push em `main` e em tags `v*`.
- PowerShell: `Invoke-Pester -Path scripts/tests` (Pester ≥ 5.5, sem `-CI`) e `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error`. Arquivos `.ps1` em UTF-8 com BOM e CRLF.
- Rust: `cargo test --manifest-path src-tauri/Cargo.toml` e `cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings`. Sem Rust na máquina de desenvolvimento, o Actions compila e commita o `Cargo.lock` regenerado em `main`.
- Interface: `ui/index.html` num navegador entra no modo demonstração (nada toca o sistema); `?vista=programas`, `?vista=disco`, `?vista=reparo`, `?vista=modojogo` etc. abrem direto nas telas.
- Site: `docs/index.html` (GitHub Pages servindo a pasta `docs/` de `main`; `.nojekyll` evita o processamento Jekyll dos planos).

### Publicar uma versão

1. Uma vez: criar o secret `TAURI_SIGNING_PRIVATE_KEY` no repositório (Settings → Secrets and variables → Actions) com o conteúdo de `%USERPROFILE%\.nextune\nextune.key`; guardar uma cópia criptografada da chave fora do GitHub (sem ela, perder o secret deixa todas as instalações sem atualização). Ativar o GitHub Pages em Settings → Pages → `main` / `docs`.
2. Subir `version` em `src-tauri/tauri.conf.json`, `src-tauri/Cargo.toml` e `package.json` (os três iguais) e commitar em `main`.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`. O Actions confere que a tag bate com a versão, compila com `-Release`, e cria a **Release em rascunho** com `NexTune_X.Y.Z_x64-setup.exe`, `.sig`, `latest.json` e `SHA256.txt`.
4. Checklist manual da spec (seção 13): instalar por cima da versão anterior numa VM Windows 11 e numa Windows 10; rodar cada módulo; testar restaurar quarentena e ajustes; medir RAM com `tools/medir.ps1`.
5. Publicar o rascunho. Só então `releases/latest/download/latest.json` passa a existir e o atualizador das instalações anteriores encontra a versão.

### Chave do atualizador

O atualizador só instala pacotes assinados com a chave minisign do projeto. O par foi gerado em 2026-11-21 com `npx tauri signer generate -w %USERPROFILE%\.nextune\nextune.key --ci` (sem senha): a chave pública está em `plugins.updater.pubkey` de `src-tauri/tauri.conf.json`; a privada ficou fora do repositório e vira o secret `TAURI_SIGNING_PRIVATE_KEY` (sem `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`). Para trocar a chave antes da primeira release, rode o comando de novo com `-f` e substitua a pública. `createUpdaterArtifacts` fica `false` no build normal e é ligado só no build de tag por `src-tauri/tauri.release.conf.json`.

### Desinstalador

`src-tauri/windows/hooks.nsh` (hook `PREUNINSTALL` do NSIS) chama `scripts/desinstalar.ps1` fora de atualizações: desfaz um Modo Jogo pendente, remove a tarefa de início `NexTune` e, se o usuário aceitar (padrão sim; também em `/S`), apaga `%ProgramData%\NexTune` sem seguir junctions. `%APPDATA%\NexTune` (ajustes e data do último lembrete) fica.

### Reparo do instalador

`scripts/reparo.ps1` lê os produtos do Windows Installer de máquina (`HKLM\SOFTWARE\Classes\Installer\Products` e `UserData\S-1-5-18\Products`) e chama de órfão o que não tem a cópia local do `.msi` (`LocalPackage`) nem origem registrada acessível; sem isso o Windows responde 1603/1612 ao atualizar ou remover. `reparar` relê o diagnóstico na hora, exporta as cinco chaves do produto como `.reg` para a quarentena e só então as remove; nunca apaga arquivos, e `data/reparo.json` lista o que não se repara por aqui (NexTune, WebView2/Edge, componentes do Windows). `UpgradeCodes` e `Components` ficam intocados nesta versão. A lógica de detecção parte do [Unregister-MissingMSIs.ps1](https://gist.github.com/BrentHumphreys/111ac670e577a94bf1531cc4d9a9d8a0) (MIT), reescrito sem baixar módulos da internet.

### Saúde do Windows

`scripts/saude.ps1` (seção na tela Disco): `verificar` lê o `ImageHealthState` do `Repair-WindowsImage -Online -CheckHealth` (só leitura; o `Dism.exe /CheckHealth` sai com 0 tanto saudável quanto reparável); `reparar` roda `Dism.exe /Online /Cleanup-Image /RestoreHealth` e depois `sfc.exe /scannow`, com o progresso tirado da porcentagem da saída. O resultado vem dos códigos de saída e das linhas `[SR]` do `CBS.log` desde o início do sfc (o CBS grava em inglês em qualquer idioma), nunca do texto da tela. Cancelar mata os dois processos pelo host.

### Pendências

- Verificação manual na máquina real: bandeja, autostart na bateria, Modo Jogo, Windows Update, winget, desinstalador com Modo Jogo pendente e o Reparo num PC com produtos órfãos. Tudo isso foi testado só em modo teste/demo.
- Lembretes: o plugin não expõe o clique na notificação no Windows; clicar nela não leva à tela específica (o Início mostra os mesmos cartões).
- RAM medida em 370–383 MB com a janela aberta (meta da spec: 120 MB), soma do WorkingSet dos 6 processos do WebView2, um teto e não memória privada; na bandeja a janela é destruída (meta ≤ 30 MB). Medir de novo com `tools/medir.ps1` depois do instalador.
- `protegidos.json` cobre NVIDIA, AMD, Intel e Realtek; Synaptics, ELAN, Qualcomm, Conexant e MediaTek ainda aparecem "sem classificação".
- A lista de ajustes partiu de chaves que a tela de Configurações grava; o pacote gpedit/autounattend do usuário entra depois.
- Atualizações: drivers via Windows Update ficam fora (`Type='Software'`); o COM do Windows Update e o `winget` não rodam nos testes.
- Disco: os textos por resultado seguem o enum `RepairStatus` lido localmente; qual valor o `-Scan` devolve na prática ainda não foi conferido elevado. `corrigir` marca o bit sujo (`fsutil dirty set`) em vez de `Repair-Volume -OfflineScanAndFix`, para nunca desmontar uma unidade em uso.
- Botão "Reportar problema" (endpoint anônimo) adiado; Smart App Control sem assinatura na v1 (ver acima).

## Créditos

As listas iniciais de bloatware e de programas protegidos e a lógica de detecção do tipo de desinstalador partiram do [RetroLimpia](https://github.com/Retropunk94/RetroLimpia) (Retropunk94, licença MIT), reescritas em português com fabricantes brasileiros e com testes próprios. A detecção de produtos órfãos do Windows Installer parte do Unregister-MissingMSIs.ps1 (MIT, heaths e BrentHumphreys). Os valores de registro dos ajustes de privacidade de feedback, idioma para sites, novidades do Windows e sugestões da web vêm do [Sophia Script for Windows](https://github.com/farag2/Sophia-Script-for-Windows) (farag2, licença MIT); o NexTune acrescenta o backup e a restauração exata.
