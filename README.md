# NexTune

Aplicativo de desktop para Windows que diagnostica o computador e faz limpeza e otimização com segurança.

Especificação: [docs/superpowers/specs/2026-11-20-otimizador-design.md](docs/superpowers/specs/2026-11-20-otimizador-design.md)

Planos de implementação: [Plano 1 (fundação, diagnóstico, limpeza)](docs/superpowers/plans/2026-11-20-fundacao-diagnostico-limpeza.md) · [Plano 2 (programas, quarentena, ponto de restauração)](docs/superpowers/plans/2026-11-20-programas-quarentena.md) · [Plano 3 (inicialização, ajustes do Windows)](docs/superpowers/plans/2026-11-20-inicializacao-ajustes-windows.md) · [Plano 4 (disco, atualizações)](docs/superpowers/plans/2026-11-20-disco-atualizacoes.md) · [Plano 5 (modo jogo, bandeja, lembretes, atualizador)](docs/superpowers/plans/2026-11-21-modo-jogo-bandeja-lembretes.md)

Status: em desenvolvimento. Ainda não há versão utilizável.

## O que já existe

- Diagnóstico com perfil em duas dimensões (classe da máquina + tipo de disco).
- Limpeza por categorias, ciente do perfil, com confirmação dupla para o que não se recria.
- Programas: lista programas clássicos e apps da Store, classifica por listas de dados (`data/bloatware.json`, `data/protegidos.json`), desinstala em silêncio quando o instalador permite e leva os restos para a quarentena.
- Quarentena: tudo que o programa remove de você fica em `%ProgramData%\NexTune\Quarentena` por N dias (padrão 7), com restauração atômica por entrada e chaves de registro exportadas em `.reg`.
- Ponto de restauração antes da primeira ação de escrita da sessão; Proteção do Sistema desligada é tratada com uma pergunta, nunca com recusa.
- Bloqueio das ações de escrita quando o usuário elevado não é o usuário da sessão.
- Inicialização: lista o que abre com o Windows (chaves Run, pasta Inicializar e tarefas agendadas), com impacto medido em RAM e tamanho do executável, e liga ou desliga cada item de forma reversível; tarefas de fabricante só no modo avançado.
- Ajustes do Windows: cinco grupos de ajustes com backup antes da escrita e restauração exata do valor anterior; os recomendados para perfil fraco vêm marcados, e os de Política levam selo de aviso.
- Disco: estado das unidades fixas, verificação online só de leitura, correção agendada para o próximo reinício (com a orientação "Reiniciar, não Desligar" quando a Inicialização Rápida está ligada) e otimizar que desfragmenta HDD ou faz TRIM em SSD, nunca o contrário e só depois de uma verificação sem erros.
- Atualizações: Windows Update (sem atualizações de versão; prévias só no modo avançado) e programas pelo `winget`, com parser independente de idioma; instala ou atualiza só o que o usuário marcou.
- Modo Jogo: três presets (`suave`, `equilibrado`, `a_fundo`) que pedem para fechar programas, pausam serviços e trocam o plano de energia; o estado é salvo antes de qualquer mudança e `desativar` desfaz tudo. Nunca fecha processos protegidos nem o próprio jogo; programas que não fecham em 10 s ficam abertos. Há lista "meus jogos" com ativação automática.
- Bandeja, lembretes e autostart: ícone na bandeja (Abrir/Sair), que destrói a janela ao fechar para poupar memória; início com o Windows (só quando instalado em Program Files; tarefa que roda também na bateria e sem limite de tempo); uma instância só (abrir de novo mostra a janela da que está na bandeja); lembrete a cada N dias com uma única notificação quando há o que ver.
- Atualizador do NexTune: verificar e instalar pelo GitHub Releases, com assinatura minisign. O código está pronto; os artefatos assinados entram no Plano 6.
- Abrir links (loja, site do fabricante) a partir de Programas, só `https://` e `ms-windows-store://`, pelo `explorer.exe` (o navegador abre sem elevação).

## Verificação

- Rust: `cargo test --manifest-path src-tauri/Cargo.toml` e `cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings`.
- PowerShell (Pester ≥ 5.5 e PSScriptAnalyzer) e o instalador: só no Windows, com `powershell -NoProfile -ExecutionPolicy Bypass -File tools/ci-local.ps1` (`-SoTestes` pula o build). O GitHub Actions roda o mesmo script a cada push em `main`.
- Localmente o Pester 6 atende o mínimo e roda direto: `Invoke-Pester -Path scripts/tests` (sem `-CI`); o PSScriptAnalyzer também: `Invoke-ScriptAnalyzer -Path scripts -Recurse -Severity Warning,Error`.
- Interface: abrir `ui/index.html` num navegador entra no modo demonstração (nada toca o sistema); `?vista=programas`, `?vista=quarentena`, `?vista=disco`, `?vista=atualizacoes` e `?vista=modojogo` abrem direto nessas telas.

## Chave do atualizador

O atualizador só instala pacotes assinados com a chave minisign do projeto. A chave ainda não foi gerada: `plugins.updater.pubkey` em `src-tauri/tauri.conf.json` está com o marcador `SUBSTITUIR_PELA_CHAVE_PUBLICA_MINISIGN`. O build não confere a chave; ela só é usada ao verificar uma atualização baixada.

1. Gerar o par (fora do repositório): `npx @tauri-apps/cli signer generate -w %USERPROFILE%\.nextune\nextune.key`. Uma senha é opcional, mas recomendada.
2. Chave pública: o conteúdo de `%USERPROFILE%\.nextune\nextune.key.pub` substitui o marcador em `plugins.updater.pubkey`.
3. Chave privada: nunca vai para o repositório. O conteúdo de `nextune.key` vira o secret `TAURI_SIGNING_PRIVATE_KEY` do GitHub Actions e, se houver senha, ela vira o secret `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`. Guarde também uma cópia criptografada fora do GitHub: sem ela, perder a chave impede atualizar quem já instalou.
4. `bundle.createUpdaterArtifacts` fica `false` até o Plano 6, que publica o `latest.json` e os instaladores assinados no Release. Até lá a verificação não encontra o `latest.json` e a interface trata como "sem atualização"; sem rede, mostra o erro.

## Pendências

- Lembretes: o plugin não expõe o clique na notificação no Windows e clicar nela não foi verificado; não leva à tela específica (o Início mostra os mesmos cartões).

- RAM medida em 370–383 MB com a janela aberta (meta da spec: 120 MB). O número é a soma do WorkingSet dos 6 processos do WebView2, um teto e não memória privada. O Plano 5 destrói a janela quando o app fica na bandeja (meta ≤ 30 MB); os dois números precisam ser medidos de novo depois do build do Actions. Para medir de novo: `powershell -NoProfile -ExecutionPolicy Bypass -File tools/medir.ps1` (veja as opções no topo do script).
- Os scripts do Plano 2 (`quarentena.ps1`, `sistema.ps1`, `programas.ps1`) foram escritos e revisados fora do Windows; a primeira rodada do Pester e do PSScriptAnalyzer acontece no Actions ou com `tools/ci-local.ps1`.
- `protegidos.json` cobre drivers NVIDIA, AMD, Intel e Realtek; Synaptics, ELAN, Qualcomm, Conexant e MediaTek ainda aparecem "sem classificação".
- A lista de ajustes partiu de chaves que a tela de Configurações grava; o pacote gpedit/autounattend do usuário não estava aqui e entra depois.
- Atualizações: drivers via Windows Update ficam fora (critério `Type='Software'`). O COM do Windows Update e o `winget` não rodam nos testes (só o parser e a forma da saída): a primeira rodada real é manual, depois do build do Actions.
- Disco: os textos por resultado seguem o enum `RepairStatus` do `Repair-Volume` lido localmente (`ScanNoErrorsFound`, `ScanErrorsFoundNeedSpotFix`, `NeedOfflineScanAndFix`…), mas qual valor o `-Scan` devolve na prática ainda não foi conferido elevado; um valor fora da lista cai no texto genérico e conta como "com erros". Unidade cujo tipo (HDD/SSD) não dá para ler fica com Otimizar travado.
- Disco: a última verificação vem do registro do NexTune (`Estado\disco.json`) e dos eventos Wininit 1001 / Chkdsk 26226; verificações feitas por outros caminhos podem não aparecer. `corrigir` marca o bit sujo do volume (`fsutil dirty set`, o mesmo efeito de `chkdsk /f` agendado) em vez de `Repair-Volume -OfflineScanAndFix`, para nunca desmontar uma unidade de dados em uso.
- `createUpdaterArtifacts` e o secret `TAURI_SIGNING_PRIVATE_KEY` entram no Plano 6, depois que o usuário gerar a chave (ver "Chave do atualizador").
- `Cargo.lock` não foi atualizado localmente (não há Rust instalado aqui): o primeiro build do Actions o regenera e ele deve ser commitado.
- Modo Jogo, bandeja, autostart, lembretes e atualizador foram verificados só em modo teste/demo; a primeira rodada real é manual depois do build do Actions.
- Hooks NSIS do desinstalador (restaurar Modo Jogo pendente, remover a tarefa ONLOGON) ficam para o Plano 6.

## Créditos

As listas iniciais de bloatware e de programas protegidos e a lógica de detecção do tipo de desinstalador partiram do [RetroLimpia](https://github.com/Retropunk94/RetroLimpia) (Retropunk94, licença MIT), reescritas em português com fabricantes brasileiros e com testes próprios.
