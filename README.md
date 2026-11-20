# NexTune

Aplicativo de desktop para Windows que diagnostica o computador e faz limpeza e otimização com segurança.

Especificação: [docs/superpowers/specs/2026-11-20-otimizador-design.md](docs/superpowers/specs/2026-11-20-otimizador-design.md)

Planos de implementação: [Plano 1 (fundação, diagnóstico, limpeza)](docs/superpowers/plans/2026-11-20-fundacao-diagnostico-limpeza.md) · [Plano 2 (programas, quarentena, ponto de restauração)](docs/superpowers/plans/2026-11-20-programas-quarentena.md)

Status: em desenvolvimento. Ainda não há versão utilizável.

## O que já existe

- Diagnóstico com perfil em duas dimensões (classe da máquina + tipo de disco).
- Limpeza por categorias, ciente do perfil, com confirmação dupla para o que não se recria.
- Programas: lista programas clássicos e apps da Store, classifica por listas de dados (`data/bloatware.json`, `data/protegidos.json`), desinstala em silêncio quando o instalador permite e leva os restos para a quarentena.
- Quarentena: tudo que o programa remove de você fica em `%ProgramData%\NexTune\Quarentena` por N dias (padrão 7), com restauração atômica por entrada e chaves de registro exportadas em `.reg`.
- Ponto de restauração antes da primeira ação de escrita da sessão; Proteção do Sistema desligada é tratada com uma pergunta, nunca com recusa.
- Bloqueio das ações de escrita quando o usuário elevado não é o usuário da sessão.

## Verificação

- Rust: `cargo test --manifest-path src-tauri/Cargo.toml` e `cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings`.
- PowerShell (Pester 5 e PSScriptAnalyzer) e o instalador: só no Windows, com `powershell -NoProfile -ExecutionPolicy Bypass -File tools/ci-local.ps1` (`-SoTestes` pula o build). O GitHub Actions roda o mesmo script a cada push em `main`.
- Interface: abrir `ui/index.html` num navegador entra no modo demonstração (nada toca o sistema); `?vista=programas` e `?vista=quarentena` abrem direto nessas telas.

## Pendências

- RAM medida em 370–383 MB com a janela aberta (meta da spec: 120 MB). O número é a soma do WorkingSet dos 6 processos do WebView2, um teto e não memória privada; tratado no Plano 5. Para medir de novo: `powershell -NoProfile -ExecutionPolicy Bypass -File tools/medir.ps1` (veja as opções no topo do script).
- Os scripts do Plano 2 (`quarentena.ps1`, `sistema.ps1`, `programas.ps1`) foram escritos e revisados fora do Windows; a primeira rodada do Pester e do PSScriptAnalyzer acontece no Actions ou com `tools/ci-local.ps1`. Pontos a observar estão nos comentários de cabeçalho de cada script.
- Abrir links (loja, site do fabricante) a partir da interface depende de um comando Rust `abrir_url` (só HTTPS e `ms-windows-store:`), previsto para o Plano 5; hoje a tela mostra o endereço para copiar.

## Créditos

As listas iniciais de bloatware e de programas protegidos e a lógica de detecção do tipo de desinstalador partiram do [RetroLimpia](https://github.com/Retropunk94/RetroLimpia) (Retropunk94, licença MIT), reescritas em português com fabricantes brasileiros e com testes próprios.
