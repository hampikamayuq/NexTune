# Otimizador (nome provisório)

Aplicativo de desktop para Windows que diagnostica o computador e faz limpeza e otimização com segurança.

Especificação: [docs/superpowers/specs/2026-11-20-otimizador-design.md](docs/superpowers/specs/2026-11-20-otimizador-design.md)

Status: em desenvolvimento. Ainda não há versão utilizável.

## Pendências

- RAM medida em 370–383 MB com a janela aberta (meta da spec: 120 MB). O número é a soma do WorkingSet dos 6 processos do WebView2, um teto e não memória privada; tratado no Plano 5. Para medir de novo: `powershell -NoProfile -ExecutionPolicy Bypass -File tools/medir.ps1` (veja as opções no topo do script).
