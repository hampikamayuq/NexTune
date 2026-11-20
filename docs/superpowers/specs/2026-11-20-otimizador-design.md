# Otimizador de Windows para PCs populares e gamer — Documento de design

Data: 2026-11-20
Estado: rascunho para aprovação
Nome do programa: **a definir** (usa-se "o Otimizador" neste documento)

---

## 1. Intenção e porquê

Criar um programa de limpeza e otimização de Windows 10/11, em português, para o público brasileiro baixar da internet e instalar em PCs e notebooks populares (Positivo, Multilaser, Samsung de entrada, Lenovo IdeaPad e similares) e também em máquinas gamer, com HDD ou SSD.

A motivação vem de duas fontes:

1. **O RetroLimpia** (Retropunk94, MIT, Electron + PowerShell, em espanhol), analisado em 2026-11-19 em `C:\Users\UPASC\Documents\Nova pasta\RetroLimpia-main`. Acertou na arquitetura de segurança (quarentena, ponto de restauração, caminhos protegidos, estado salvo antes de mexer) e na honestidade com o usuário. Errou no peso (Electron: ~150 MB de RAM só com a janela, instalador de dezenas de MB), em alterações permanentes sem reversão e em usar chaves de Política que travam a tela de Configurações.
2. **A experiência prática de manutenção** de um Positivo C6400 (HDD, 8 GB, Windows 11 Pro 26H2): o que ferramentas como RyTuneX fazem de ruim em HDD, por que SysMain e indexação exigem decisão caso a caso, limpeza de componentes via DISM, Windows.old, como agendar chkdsk de verdade (e por que ele às vezes não roda no boot), e o pacote de ajustes do gpedit/autounattend que o usuário já padronizou para reinstalações.

A tese do produto: **primeiro descobrir que máquina é aquela, só depois recomendar.** Concorrentes aplicam a mesma receita para todo mundo; o Otimizador adapta a receita ao perfil (disco mecânico ou SSD, pouca ou muita RAM, notebook ou desktop, GPU dedicada ou integrada) e nunca aplica um ajuste que piore aquela classe de máquina.

## 2. Público

Público geral, não técnico, que baixa o instalador de um site/GitHub. Inclui:

- Quem tem notebook ou PC popular lento, com HDD e 4 a 8 GB de RAM, cheio de software de fabricante e da Microsoft.
- Quem tem PC gamer e quer fechar o que atrapalha enquanto joga e manter drivers/atualizações em dia.

Consequências: tudo em português claro, sem jargão sem explicação; cada ação diz o que faz, o que muda e como desfazer; o padrão é conservador e o "modo avançado" libera o resto.

## 3. Objetivos, não-objetivos e anti-objetivos

### Objetivos (v1)

- Leve de verdade: ver orçamento de desempenho na seção 12.
- Perfil da máquina detectado automaticamente e exibido; o usuário pode trocar.
- Oito módulos: Diagnóstico, Limpeza, Programas, Inicialização, Ajustes do Windows, Disco, Atualizações, Modo Jogo (seção 8).
- Tudo reversível: quarentena de 7 dias, ponto de restauração antes de mudanças, backup do valor original de cada chave de registro, restauração com um clique.
- Transparente: scripts PowerShell em texto puro no instalador, log de cada ação em `%ProgramData%`, nada enviado à internet sem clique explícito.
- Instalador, atualização automática assinada, página explicando o aviso do SmartScreen.

### Não-objetivos (v1)

- Assistente "acabei de formatar" (instalar programas via winget em lote). Candidato à v2.
- Inglês/espanhol na interface. A estrutura de textos já nasce preparada (JSON por idioma), mas só pt-BR é escrito na v1.
- Gerenciar drivers de fabricante fora do Windows Update.
- Suporte a Windows 7/8.1 ou 32 bits.

### Anti-objetivos (fracasso mesmo que "funcione")

- "Limpar registro para ganhar velocidade", "otimizador de RAM", "desativar pagefile", desligar Windows Defender, desligar Windows Update. Nada disso entra, nem no modo avançado.
- Desabilitar ou remover Microsoft Edge e o **WebView2 Runtime**: o Windows e o próprio Otimizador dependem deles. Entram na lista de protegidos.
- Qualquer alteração permanente sem caminho de volta.
- Usar chaves de Política de Grupo (`HKLM\SOFTWARE\Policies\...`, `HKCU\Software\Policies\...`) quando existir a chave que a própria tela de Configurações grava. Onde não houver alternativa, a interface avisa "trava esta opção em Configurações" e o ajuste é reversível.
- Telemetria própria. O único tráfego automático é a consulta de versão nova no GitHub.
- Tarefas agendadas que executam scripts gravados em pasta do usuário (o `relanzar.ps1` do RetroLimpia é um vetor de elevação). O atualizador do Tauri cuida do reinício.

## 4. Restrições

- Windows 10 (build 19045+) e Windows 11, 64 bits. PowerShell 5.1 (o que vem no Windows); nada pode exigir PowerShell 7.
- Precisa de administrador para quase tudo: o executável pede elevação no manifesto (`requireAdministrator`), como o RetroLimpia.
- Máquina de desenvolvimento: Windows 11 Pro, Node 26 e npm 11 já instalados; **Rust não instalado** (rustup + toolchain MSVC ≈ 1 GB em HDD); `gh` CLI não instalado. O build oficial roda no GitHub Actions (runner `windows-latest` já tem Rust).
- Sem certificado de assinatura de código pago. SmartScreen vai avisar; a documentação explica e orienta. Depois da v1, pedir assinatura gratuita à SignPath Foundation (projeto open source).
- Licença: MIT (decisão do usuário pendente, ver pergunta aberta). Código novo; listas de dados (bloatware, inicialização, protegidos) podem ser adaptadas do RetroLimpia com crédito no README, já que são MIT.

## 5. Abordagens consideradas

| | Abordagem | Prós | Contras |
|---|---|---|---|
| 1 | Electron + scripts PowerShell (igual ao RetroLimpia) | Mais rápido de construir; padrão conhecido | Instalador ≥ 80 MB; ~150 MB de RAM só com a janela; contradiz a proposta de "leve" |
| **2** | **Tauri 2 (Rust + WebView2) + scripts PowerShell** | Instalador ~10 MB; 30-50 MB de RAM; interface em HTML/CSS/JS; scripts legíveis por qualquer pessoa (argumento de confiança); WebView2 já vem no Windows 10/11 | Toolchain Rust para compilar; se o usuário removeu o WebView2 com outro "debloater", é preciso reinstalá-lo |
| 3 | Nativo em C# (WPF) chamando APIs do Windows | O mais leve e rápido de abrir | Muito mais código; interface menos flexível; usuário não audita o que o programa faz sem descompilar; runtime .NET pode faltar |

**Escolhida: 2 (Tauri + PowerShell)**, pelo usuário, em 2026-11-19. Motivo: entrega o programa leve, mantém a transparência dos scripts e reaproveita o que o RetroLimpia acertou na arquitetura. Decisão decorrente (minha): o instalador embute o bootstrapper do WebView2 (~1,5 MB) para instalar o runtime quando faltar, antes de abrir a janela.

## 6. Arquitetura

```
┌──────────────────────────────────────────────────────────────┐
│  Janela (WebView2)                                           │
│  HTML/CSS/JS puro, sem framework; textos em pt-BR via JSON   │
└───────────────┬──────────────────────────────────────────────┘
                │ Tauri commands / events (JSON)
┌───────────────▼──────────────────────────────────────────────┐
│  Núcleo Rust (Tauri 2)                                       │
│  • allowlist de ações + validação de parâmetros por esquema  │
│  • gerencia o Host PowerShell (1 processo persistente)       │
│  • ajustes do usuário, perfil, updater, autostart, bandeja   │
│  • vigia do Modo Jogo automático (tasklist a cada 15 s)      │
└───────────────┬──────────────────────────────────────────────┘
                │ stdin: 1 linha JSON por comando {id, acao, params}
                │ stdout: @@PROGRESS / @@LOG / @@RESULT com o mesmo id
┌───────────────▼──────────────────────────────────────────────┐
│  Host PowerShell 5.1 (scripts/host.ps1)                      │
│  dot-source de scripts/<modulo>.ps1 sob demanda              │
│  fecha sozinho após 2 min ocioso; o Rust relança se precisar │
└──────────────────────────────────────────────────────────────┘
```

### 6.1 Interface

- HTML, CSS e JavaScript puros (sem React/Vue). Motivo: peso mínimo, zero dependências de build no frontend, e é o que o RetroLimpia já prova funcionar para esse tipo de app.
- CSP estrita: `default-src 'self'; connect-src 'none'` (a interface nunca fala com a internet; quem fala é o Rust).
- Escape de HTML obrigatório em tudo que vem do motor. Preferir construir nós do DOM a `innerHTML` com texto do motor.
- Zoom automático pela resolução (de 1366×768 até 4K), tema escuro padrão, tema claro opcional.
- Textos em `ui/i18n/pt-BR.json`; chave por texto; `en.json` fica vazio na v1.

### 6.2 Núcleo Rust

- Expõe comandos ao frontend: `executar(acao, params)`, `cancelar()`, `ajustes_ler/gravar`, `dados(nome)`, `info()`, `abrir_pasta(qual)`, `abrir_url(https only)`, `atualizacao_*`, `autostart(on)`, `modo_jogo_*`.
- **Validação de parâmetros no Rust**, por ação, antes de chegar ao PowerShell (melhoria sobre o RetroLimpia, que confiava na interface): tipos, limites de tamanho, listas fechadas (ids de categoria, ids de ajuste), caminhos que precisam existir e não estar em pasta protegida quando a ação for destrutiva.
- Mantém **um** Host PowerShell: `powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\host.ps1`, janela oculta, prioridade abaixo do normal quando o perfil for `fraco`. Comandos entram por stdin como JSON de uma linha com `id`; respostas saem por stdout prefixadas (`@@PROGRESS`, `@@LOG`, `@@RESULT`) com o mesmo `id`. O Rust roteia por `id`, então várias ações podem estar em voo (ex.: diagnóstico em paralelo com leitura de programas).
- Cancelar: comando `cancelar {id}` para o host, que mata a árvore de processos filhos daquela ação; se o host não responder em 5 s, o Rust mata o host e relança.
- Host ocioso por 2 minutos fecha sozinho (devolve ~50 MB de RAM); relança em menos de 1 s no próximo clique (no HDD, até 2 s: a interface mostra "preparando").
- Ajustes do usuário em `%APPDATA%\<App>\ajustes.json`. Dados do sistema em `%ProgramData%\<App>\` (`Quarentena\`, `logs\`, `backups\`, `estado\`). Permissões padrão do Windows, sem `icacls`.
- Bandeja opcional (quando o usuário ativa lembretes). Autostart por tarefa agendada ONLOGON com `RL HIGHEST` apontando para o executável em Program Files (sem script intermediário).
- **Lembretes (definição):** com a bandeja ativa, a cada N dias (padrão 3) o Rust pede ao host uma revisão **só de leitura**: tamanho da limpeza verde, atualizações pendentes do Windows e de programas, dias desde a última verificação de disco, alerta de saúde do disco (SMART). Se houver algo acima dos limites (lixo > 500 MB, qualquer atualização, disco sem verificação há 90 dias, saúde diferente de "OK"), mostra **uma** notificação do Windows; clicar abre o programa na tela certa. Lembretes nunca executam nada. O host fecha logo após a revisão. Ligar o **Modo Jogo automático** liga a bandeja e o autostart (sem bandeja ele não funciona), e a interface diz isso ao ligar.
- Vigia do Modo Jogo automático: no Rust, `tasklist /FO CSV /NH` a cada 15 s quando o usuário tiver jogos na lista e o automático ligado.

### 6.3 Host e scripts PowerShell

- `scripts/host.ps1`: loop de leitura de stdin; para cada comando, resolve `scripts/<modulo>.ps1` da allowlist, dot-source uma vez por sessão, chama `Invoke-Acao $acao $params` daquele módulo; captura exceções e devolve `@@RESULT {id, ok:false, erro}`. Saída sempre UTF-8 sem BOM.
- `scripts/common.ps1`: `Send-Progress`, `Send-Log`, `Send-Result` (com `id`), `Write-AppLog`, `Get-PathSize`, `Test-ProtectedPath` (lista do RetroLimpia **mais** `Microsoft\EdgeWebView`, `Microsoft\EdgeCore`, `Microsoft\Edge`, pastas de runtimes .NET/VC++, `WindowsApps`), `Get-Perfil` (lê o perfil salvo pelo diagnóstico).
- Cada módulo é um arquivo. Cada ação destrutiva recebe o perfil e recusa o que for proibido para aquele perfil (defesa em profundidade: a interface nem oferece, o Rust valida, o script confere).
- Modo `teste`: parâmetro que redireciona registro para `HKCU\Software\<App>Teste\` e pastas para `%TEMP%\<App>Teste\`, para Pester rodar sem tocar no sistema.

## 7. Perfil da máquina (o coração do produto)

O Diagnóstico roda na primeira abertura (e sob demanda) e grava `%ProgramData%\<App>\estado\perfil.json`.

**Coleta:** CPU (núcleos, hilos, nome), RAM total, disco do sistema (`Get-PhysicalDisk` → `MediaType` HDD/SSD, `BusType` NVMe; fallback `Win32_DiskDrive`), demais discos, GPU(s) e se há dedicada (NVIDIA/AMD não integrada), bateria presente (notebook), fabricante/modelo, versão e build do Windows, Inicialização Rápida ativa (`HiberbootEnabled`), SysMain e WSearch (estado atual), saúde dos discos (`Get-StorageReliabilityCounter`), espaço livre.

**Classificação** (regras em `data/perfis.json`, editáveis sem recompilar):

| Classe | Critério (qualquer um) | O que muda |
|---|---|---|
| `basico` | RAM ≤ 4,5 GB ou ≤ 2 núcleos | Recomendações priorizam RAM; Modo Jogo oferece só o preset "suave" por padrão ("a fundo" no modo avançado) |
| `medio` | o resto | padrão |
| `gamer` | GPU dedicada e RAM ≥ 16 GB | Modo Jogo em destaque; limpeza de shaders oferecida; preset "a fundo" disponível |

(Onde o restante do documento diz `fraco`, leia-se `basico` ou `disco = hdd`, conforme a regra acima.)

**Decisão (minha) sobre o esquema do perfil:** o perfil tem **duas dimensões independentes** gravadas em `perfil.json`: `classe` (`basico` | `medio` | `gamer`), calculada só por CPU, RAM e GPU, e `disco` (`hdd` | `ssd`), pelo disco do sistema. O critério de `basico` passa a ser RAM ≤ 4,5 GB ou ≤ 2 núcleos (sem o disco). As regras de disco valem sempre, independentemente da classe. O "modo leve" da interface e a prioridade baixa do host ligam quando `classe = basico` **ou** `disco = hdd`. Um PC gamer com HDD fica `gamer` + `hdd`: vê Modo Jogo em destaque e limpeza de shaders, pode usar o preset "a fundo", mas recebe as regras de HDD (sem TRIM, SysMain opcional, desfragmentação). A troca manual de perfil pelo usuário é gravada e sobrevive a novos diagnósticos até ele desfazer.

As classes se combinam com o **tipo de disco**, que é a dimensão mais importante:

**Regras para HDD** (lições do Positivo):
- Nunca executar TRIM. "Otimizar unidades" = desfragmentação, e só depois de o volume estar limpo (`Repair-Volume -Scan` sem erros).
- SysMain (Superfetch/Prefetch) e WSearch (indexação): **nunca desligar automaticamente**. Aparecem como "opcional", com os dois lados explicados: ajudam a abrir programas, mas em HDD com pouca RAM mantêm o disco ocupado por minutos após ligar. Se o usuário desligar, fica registrado e é reversível.
- Não aplicar ajustes "gamer" (prioridade de GPU, timers, etc.) em perfil `fraco`.
- Hibernação/Inicialização Rápida: oferecer desligar quando atrapalhar o chkdsk agendado (ver 8.6), explicando o custo (boot um pouco mais lento).

**Regras para SSD/NVMe:**
- Nunca desfragmentar; "Otimizar" = TRIM (`Optimize-Volume -ReTrim`).
- SysMain: deixar em paz (no SSD ele quase não pesa); não oferecer desligar fora do modo avançado.
- Nada de "desativar pagefile" (anti-objetivo).

**Regras para pouca RAM (≤ 8 GB):** sugerir fechar inicialização pesada, desligar Widgets/Copilot/Teams no arranque, efeitos visuais reduzidos (reversível). Nunca mexer em memória virtual.

## 8. Módulos da v1

Cada módulo expõe ações de **leitura** (sempre permitidas) e **escrita** (passam pelas regras do perfil, criam ponto de restauração quando configurado, registram log e, quando removem algo, usam a quarentena).

### 8.1 Diagnóstico
Leitura: tudo da seção 7, mais temperatura de CPU/GPU quando disponível, saúde e desgaste dos discos, bateria. Mostra o perfil detectado com um botão "não é isso, trocar". Gera um relatório HTML salvo em `Documentos\<App>\`.

### 8.2 Limpeza
Categorias com cor (verde = seguro, amarelo = decide você):
- verde: temp do usuário, temp do Windows, cache do Windows Update (parando `wuauserv`/`bits` e religando), Otimização de Entrega, relatórios de erro, miniaturas, caches de launchers (Steam htmlcache, Battle.net, Discord).
- amarelo: cache de navegadores (só cache, nunca histórico/senhas), minidumps, lixeira, caches de shaders (só perfil `gamer`).
- **novos em relação ao RetroLimpia:** limpeza de componentes do Windows (`DISM /Online /Cleanup-Image /StartComponentCleanup`, **sem** `/ResetBase` por padrão, porque ResetBase impede desinstalar atualizações; `/ResetBase` só no modo avançado com aviso); `Windows.old` (só se existir há mais de 10 dias; mostra tamanho e avisa que impede voltar à versão anterior); pontos de restauração antigos (mantendo o mais recente) via `vssadmin`, só no modo avançado.
- Mede antes e depois e mostra o quanto liberou.
- **Decisão (minha): a Limpeza apaga direto, sem quarentena.** Tudo que ela toca é temporário ou cache que o sistema recria sozinho, e o público quer o espaço na hora; mover 3 GB para a quarentena não libera nada por 7 dias. A quarentena fica para Programas (restos, bloatware) e Ajustes (backup de registro). As duas exceções que não se recriam, `Windows.old` e pontos de restauração antigos, pedem confirmação dupla com o texto "isto não vai para a quarentena". A frase da tela inicial passa a ser "tudo que o programa **remove de você** pode ser desfeito; caches e temporários são apagados de vez".

### 8.3 Programas
- Lista programas clássicos e apps da Store, com tamanho, data, serviços e RAM em uso (como o RetroLimpia).
- Cores por lista de dados: `bloatware.json` (verde/amarelo/vermelho) adaptada com **fabricantes brasileiros** (Positivo, Multilaser, utilitários OEM), e `protegidos.json` (runtimes, Edge, WebView2, GameInput, DirectX, drivers).
- Desinstalar: tenta silencioso (MSI, Inno, NSIS, InstallShield, QuietUninstallString), lojas de jogos pela própria loja, último recurso o assistente do programa. Lógica portada do `desinstalar.ps1` do RetroLimpia (é a parte mais madura dele), reescrita e com testes.
- Restos: pastas, atalhos quebrados, chaves de registro e entradas fantasma, sempre via quarentena (arquivos movidos; chaves exportadas em `.reg` antes de apagar). Heurística de "pasta órfã" exige: fora de `Test-ProtectedPath`, sem programa instalado correspondente, sem `.exe/.dll/.sys`, sem alteração há 30 dias, e confiança "média" (sempre pergunta).
- Quarentena: listar, restaurar lote, purgar após N dias (padrão 7). Nunca apaga antes do prazo sem clique.
- **Caminho de volta da desinstalação (decisão minha).** Desinstalar não cabe na quarentena, então o resumo "para desfazer" diz a verdade: para apps da Store, o programa guarda o `PackageFamilyName` e, quando conhecido, o `ProductId` em `bloatware.json`, e oferece o link `ms-windows-store://pdp/?ProductId=` para reinstalar; para programas clássicos, "reinstale pelo site do fabricante" (link quando conhecido na lista). Alcance padrão para apps da Store: remover para **todos os usuários** (`-AllUsers`), porque é o que resolve o bloatware de fábrica; **desprovisionar** (impedir que volte em contas novas) só no modo avançado, com aviso de que uma atualização de versão do Windows pode reinstalar.

### 8.4 Inicialização
Mesmo mecanismo do Gerenciador de Tarefas (`StartupApproved`), reversível, com recomendação por padrão de nome (`inicio.json`) e mostrando impacto medido quando possível. Inclui tarefas agendadas de inicialização conhecidas de fabricantes (lista de dados), só no modo avançado.

### 8.5 Ajustes do Windows
Grupos: anúncios e sugestões, privacidade (ID de publicidade, experiências personalizadas, telemetria no nível mínimo permitido pela edição), Copilot/Widgets, Explorador (extensões visíveis, abrir em "Este Computador"), efeitos visuais reduzidos (perfil `fraco`).
- Cada valor original é salvo em `backups\ajustes-registro.json` **antes** da escrita; "restaurar" devolve exatamente o valor anterior ou remove o valor se não existia.
- Regra de ouro: usar a chave que a tela de Configurações usa. Chaves de Política só quando inevitável, com selo "trava a opção em Configurações" na interface.
- Fonte adicional: o pacote de gpedit/autounattend que o usuário padronizou (PDF "config gpedit" no Drive e `autounattend.xml` em Downloads). O construtor recebe a lista convertida em `data/ajustes.json`; itens que exigem Política ficam no modo avançado.

### 8.6 Disco
- Saúde (SMART via `Get-StorageReliabilityCounter`), espaço, tipo.
- Verificar agora (online, só leitura): `Repair-Volume -Scan`.
- Corrigir no próximo reinício: `Repair-Volume -OfflineScanAndFix` (equivale a `chkdsk /f` agendado). **Lição do Positivo:** o chkdsk agendado pode não rodar no boot com Inicialização Rápida ligada ou quando o desligamento é por hibernação. O módulo mostra se Inicialização Rápida está ativa, oferece "reiniciar agora" (`shutdown /r /t 0`, que não hiberna) e, se falhar de novo, explica a alternativa pelo Ambiente de Recuperação (`reagentc /boottore`), sem executar sozinho.
- Otimizar: desfragmentar (HDD) ou TRIM (SSD), nunca o contrário, e só com volume limpo.

### 8.7 Atualizações
- Windows Update via COM (`Microsoft.Update.Session`): listar, instalar selecionadas; excluir atualizações de versão ("Upgrades") e Preview por padrão.
- Programas via `winget upgrade` (parser independente de idioma, como o RetroLimpia).
- Atualização do próprio Otimizador: Tauri updater com assinatura minisign; chave privada só nos secrets do GitHub Actions; `latest.json` e instalador em GitHub Releases; baixa só o instalador; instala quando o usuário aceitar ou, se estiver na bandeja, quando nenhuma ação estiver em curso.

### 8.8 Modo Jogo
Portado do RetroLimpia (`modojuego.ps1`) com as mesmas garantias: estado salvo em disco **antes** de qualquer mudança; nunca ativa por cima de um estado existente; lista de protegidos (OBS, Discord, launchers, drivers, áudio, overlays); programas com janela recebem pedido de fechar (respeita "salvar alterações?"), não `kill`; restaura tudo ao sair (plano de energia, notificações, serviços pausados, prioridade) e reabre o que fechou.
- Presets: `suave` (fechar escolhidos + plano de energia), `equilibrado` (+ silenciar notificações + pausar Windows Update/BITS/Otimização de Entrega, exceto se o Windows estiver instalando), `a fundo` (+ pausar WSearch e SysMain + prioridade alta no jogo). No perfil `fraco`, `a fundo` fica no modo avançado.
- Automático: lista "meus jogos" (`.exe` escolhidos pelo usuário); vigia em Rust; liga ao detectar o jogo e restaura 30 s depois de ele fechar.

## 9. Segurança e reversibilidade (regras transversais)

1. Ponto de restauração antes da primeira ação de escrita de cada sessão (configurável). Zerar `SystemRestorePointCreationFrequency` **só durante a criação** e devolver o valor original logo depois (o RetroLimpia deixava em 0 para sempre).
   **Proteção do Sistema desligada** (comum em PC de fábrica com disco pequeno): o programa nunca recusa a ação por isso. Na primeira ação de escrita pergunta uma vez: "Ligar a Proteção do Sistema reservando até 3 % do disco (recomendado)" ou "Continuar sem ponto de restauração (a quarentena e os backups de registro continuam valendo)". A escolha fica gravada e pode mudar em Opções. Ligar usa `Enable-ComputerRestore` e `vssadmin resize shadowstorage /maxsize=3%`.
   **Conta padrão com senha de administrador no UAC:** na v1 o programa exige que o usuário logado seja administrador. Ao abrir, o Rust compara o usuário do processo (elevado) com o usuário da sessão de console; se forem diferentes, mostra uma tela explicando que, para não mexer nas configurações da pessoa errada, é preciso entrar com a conta de administrador, e não libera ações de escrita. Rodar a interface sem elevação com um serviço elevado fica para uma versão futura.
2. Quarentena para todo arquivo/pasta/chave removido. Registro exportado em `.reg` antes de apagar.
3. `Test-ProtectedPath` em toda ação destrutiva de arquivo, no Rust e no PowerShell.
4. Lista de processos e programas protegidos compartilhada entre Programas, Inicialização e Modo Jogo.
5. Log em `%ProgramData%\<App>\logs\AAAA-MM.log` de toda escrita: o quê, onde, resultado.
6. Sem rede a partir da interface; no Rust só HTTPS para `api.github.com` e `github.com` (updater) e, se o usuário clicar em "Reportar problema", o endpoint de reportes (opt-in, com anonimização de usuário, hostname, e-mails e IPs, como o RetroLimpia faz).
7. Sem `Invoke-Expression`; comandos externos sempre com lista de argumentos.
8. O instalador NSIS nunca mexe em ACLs (`icacls`).

## 10. Distribuição e operação

- Repositório público no GitHub, licença MIT, README em português com: o que faz, o que nunca faz, como auditar, SHA-256, "por que o Windows avisa".
- GitHub Actions (`windows-latest`): instala Rust, `npm ci`, `cargo tauri build`, roda testes (seção 13), gera `SHA256.txt`, publica Release em tag `v*` com instalador NSIS per-machine (`requireAdministrator`), `latest.json` do updater e assinaturas.
- Instalador embute o bootstrapper do WebView2.
- **Desinstalador do próprio programa** (hooks NSIS desde a v1): 1) se houver estado pendente do Modo Jogo, restaura antes de remover; 2) remove a tarefa ONLOGON; 3) pergunta "Apagar também a quarentena, backups e registros em `%ProgramData%\<App>`?" com **sim** marcado por padrão (é um limpador; não deixa resto), e um aviso de que a quarentena pode conter coisas de até 7 dias; 4) nunca mexe em ACLs.
- **Chave de assinatura do atualizador:** gerada uma vez na máquina do usuário com `tauri signer generate`; a chave pública vai no código; a privada entra nos secrets do GitHub **e** uma cópia criptografada com senha fica fora do GitHub, em local que o usuário escolher (pergunta aberta 6). Sem essa cópia, perder o secret deixa todas as instalações sem atualização para sempre.
- Site: página única em `docs/` (GitHub Pages), como o RetroLimpia.
- **Smart App Control (Windows 11 novo de fábrica):** bloqueia executáveis sem assinatura sem opção de "executar assim mesmo", e desligá-lo é permanente até reinstalar o Windows. Decisão (minha): a v1 sai sem assinatura mesmo assim, porque a SignPath Foundation só aceita projeto já publicado; o site e o README ganham uma seção "Windows diz que o app foi bloqueado pelo Smart App Control" explicando o que é, que a decisão de desligar é do usuário e irreversível, e que a versão assinada é prioridade da v1.x. O pedido à SignPath entra logo após a primeira release pública.
- Pós-v1: submeter cada versão ao Microsoft Defender (falso positivo).

## 11. Experiência de uso (esboço)

```
┌─ <App> ───────────────────────────────────────── v1.0.0 ─ ─ □ ✕ ┐
│ ▣ Início        │  Seu PC: Positivo C6400 · HDD 1 TB · 8 GB      │
│ ▤ Limpeza       │  Perfil: PC básico com disco mecânico  [trocar]│
│ ▥ Programas     │                                                │
│ ▦ Inicialização │  Recomendado agora                             │
│ ▧ Ajustes       │  • 3,2 GB de arquivos temporários   [Limpar]   │
│ ▨ Disco         │  • 7 programas abrindo com o Windows [Ver]     │
│ ▩ Atualizações  │  • Disco sem verificação há 90 dias  [Verificar]│
│ ▪ Modo Jogo     │                                                │
│                 │  Tudo que o programa muda pode ser desfeito.   │
│ Quarentena (2)  │  [Ver quarentena]  [Ver registro de ações]     │
│ ⚙ Opções        │                                                │
└─────────────────┴────────────────────────────────────────────────┘
```

Primeira abertura: tour de 4 passos (perfil detectado, onde fica a quarentena, modo avançado, lembretes opcionais). Toda ação de escrita mostra antes um resumo "vai fazer X em Y; para desfazer, Z".

## 12. Orçamento de desempenho (metas verificáveis)

As metas de RAM **contam todos os processos**: o executável do app, os processos `msedgewebview2.exe` que ele criou e o host PowerShell quando vivo. Um Tauri real no Windows fica entre 80 e 150 MB com o WebView2 somado; os números abaixo são realistas para isso e ainda ficam na metade do RetroLimpia.

| Métrica | Meta | Bloqueia release? | Como medir |
|---|---|---|---|
| Instalador | ≤ 15 MB (+1,5 MB do bootstrapper WebView2) | **sim** (CI falha) | tamanho do `.exe` da Release |
| RAM com janela aberta, ociosa, host fechado | ≤ 120 MB (soma de todos os processos) | sim (checklist manual de release) | script `tools/medir.ps1` (como `medir-rendimiento.ps1` do RetroLimpia) |
| RAM com host PowerShell vivo | ≤ 180 MB total | não (reportar) | idem |
| RAM na bandeja, janela fechada | ≤ 30 MB (WebView2 destruído) | sim (checklist) | idem |
| Tempo até a janela, HDD frio | ≤ 6 s | não (reportar) | idem |
| CPU ociosa | < 0,5 % | sim (checklist) | idem |
| Tempo da primeira ação após clique (host frio, HDD) | ≤ 2,5 s até a primeira linha de progresso | não (reportar) | log do host |

Medida arquitetural que torna a linha "bandeja" possível: ao fechar a janela para a bandeja, a janela e o WebView2 são **destruídos**, não escondidos (o RetroLimpia já faz isso); só o processo Rust e o vigia ficam.

## 13. Testes e qualidade

- **Pester** (PowerShell) para cada módulo, em modo `teste`: registro e pastas falsas; cobre regras de perfil (ex.: TRIM em HDD deve ser recusado), quarentena (mover/restaurar/purgar), backup e restauração de ajustes, detecção de tipo de instalador, parser do winget com saídas gravadas.
- **PSScriptAnalyzer** no CI com regras padrão.
- **Rust**: `cargo clippy -D warnings`, testes unitários da validação de parâmetros e do roteamento por `id`.
- **Interface**: modo demo (dados falsos, nenhuma ação toca o sistema) para desenvolver e para captura de telas; checagem de que nenhum texto do motor chega a `innerHTML` sem escape (grep no CI).
- **Manual**, antes de cada release: instalar por cima da versão anterior numa VM Windows 11 e numa Windows 10; rodar cada módulo; testar restaurar quarentena e ajustes.

## 14. O que fica para o construtor

- Organização interna dos arquivos Rust e dos scripts, nomes de funções, formato exato do JSON de perfil e de parâmetros por ação (desde que validados no Rust).
- Visual (cores, tipografia, ícone), respeitando tema escuro padrão e zoom por resolução.
- Conteúdo inicial das listas `bloatware.json`, `inicio.json`, `protegidos.json`, `ajustes.json`, `perfis.json`, partindo do RetroLimpia (com crédito) e do pacote gpedit do usuário.
- Textos em pt-BR; tom: direto, sem jargão, explica a consequência e como desfazer.
- Estratégia de instalação do Rust na máquina de desenvolvimento (rustup com toolchain MSVC) e do Build Tools do Visual Studio, ou optar por desenvolver só com CI.

## 15. Fora da v1 (registro)

Assistente pós-formatação (winget em lote), inglês/espanhol, verificação de drivers de fabricante, histórico "por que meu PC reiniciou", relatórios comparativos antes/depois ao longo do tempo, assinatura de código.

## 16. Perguntas abertas (só o usuário responde)

1. Nome do programa (define pasta em `%ProgramData%`, nome do repositório, instalador e site).
2. Licença MIT e repositório público desde o início, ou privado até a primeira versão?
3. Conta GitHub a usar para o repositório e para as Releases/Actions.
4. Desenvolver e testar localmente (instalar Rust ≈ 1 GB no HDD do Positivo) ou compilar só no GitHub Actions e testar o instalador baixado?
5. Ter o botão "Reportar problema" na v1 (precisa de um endpoint, como o Cloudflare Worker do RetroLimpia) ou adiar?
6. Onde guardar a cópia de segurança da chave privada do atualizador (gerenciador de senhas, pendrive, arquivo criptografado no Drive)?

## 17. Decisões tomadas após a revisão independente (2026-11-20)

Um revisor leu o documento como construtor. Estas foram as lacunas e como foram fechadas (todas decisões minhas, para o usuário conferir):

| Lacuna | Decisão | Onde |
|---|---|---|
| Limpeza passa pela quarentena? | Não: apaga direto; quarentena só em Programas/Ajustes; Windows.old e pontos antigos com confirmação dupla | 8.2 |
| Conta padrão + senha de admin no UAC | v1 exige usuário logado administrador; detecta e bloqueia escrita com explicação | 9.1 |
| Proteção do Sistema desligada | Pergunta uma vez: ligar com 3 % do disco (recomendado) ou seguir sem ponto; nunca recusa | 9.1 |
| Caminho de volta da desinstalação | Link da Store / do fabricante; Store remove para todos os usuários; desprovisionar só no avançado | 8.3 |
| Orçamento de RAM conta WebView2? Quais metas bloqueiam? | Sim, conta tudo; metas renegociadas; só instalador, RAM ociosa, RAM na bandeja e CPU ociosa bloqueiam | 12 |
| `fraco` × `gamer` | Perfil em duas dimensões: `classe` (CPU/RAM/GPU) + `disco` (HDD/SSD); regras de disco valem sempre | 7 |
| O que são os lembretes | Revisão só de leitura a cada N dias, uma notificação, nunca executa; Modo Jogo automático liga bandeja | 6.2 |
| Smart App Control | v1 sem assinatura, documentado; SignPath logo após a primeira release | 10 |
| Cópia da chave minisign | Cópia criptografada fora do GitHub, local a definir pelo usuário | 10, pergunta 6 |
| Desinstalador do próprio app | Restaura Modo Jogo, remove tarefa, pergunta se apaga `%ProgramData%` (padrão sim) | 10 |
