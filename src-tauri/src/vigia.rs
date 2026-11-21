//! Vigia do Modo Jogo automático.
//!
//! A cada 15 s, com `modoJogoAuto` ligado e a lista `jogos` preenchida, lê os processos
//! (`tasklist /FO CSV /NH`). Um jogo da lista rodando ativa `modojogo/ativar` (preset dos ajustes,
//! `automatico:true`); o jogo que ativou ausente por 30 s desativa (`modojogo/desativar`). Só
//! desativa o que o próprio vigia ativou. Nunca executa outra ação. Cada mudança emite o evento
//! `modojogo` com `{ativo, jogo}`; falha emite `{erro}`.

use crate::ajustes;
use crate::comandos::{self, Estado};
use serde_json::json;
use std::collections::HashSet;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

const INTERVALO: Duration = Duration::from_secs(15);
/// Tempo que o jogo pode ficar fechado antes de desativar (reinício do jogo, launcher).
const TOLERANCIA_AUSENTE: Duration = Duration::from_secs(30);

/// Nomes (minúsculos) dos executáveis na saída de `tasklist /FO CSV /NH`.
pub fn exes_de_tasklist(csv: &str) -> HashSet<String> {
    csv.lines()
        .filter_map(|l| {
            let nome = l.trim().strip_prefix('"')?.split('"').next()?.to_lowercase();
            nome.ends_with(".exe").then_some(nome)
        })
        .collect()
}

#[derive(PartialEq, Debug)]
pub enum Decisao {
    Nada,
    Ativar(String),
    Desativar,
}

/// Decisão pura de um ciclo do vigia.
pub fn decidir(
    jogos: &[String],
    rodando: &HashSet<String>,
    ativo_por_vigia: Option<&str>,
    ausente_ha: Option<Duration>,
) -> Decisao {
    if jogos.is_empty() {
        return Decisao::Nada;
    }
    match ativo_por_vigia {
        None => jogos
            .iter()
            .find(|j| rodando.contains(&j.to_lowercase()))
            .map_or(Decisao::Nada, |j| Decisao::Ativar(j.clone())),
        Some(j) if rodando.contains(&j.to_lowercase()) => Decisao::Nada,
        Some(_) if ausente_ha >= Some(TOLERANCIA_AUSENTE) => Decisao::Desativar,
        Some(_) => Decisao::Nada,
    }
}

async fn processos() -> Result<HashSet<String>, String> {
    let mut cmd = tokio::process::Command::new(crate::bandeja::system32("tasklist.exe"));
    cmd.args(["/FO", "CSV", "/NH"]);
    #[cfg(windows)]
    cmd.creation_flags(crate::host::CREATE_NO_WINDOW);
    let out = cmd
        .output()
        .await
        .map_err(|e| format!("tasklist falhou: {e}"))?;
    Ok(exes_de_tasklist(&String::from_utf8_lossy(&out.stdout)))
}

pub fn iniciar(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut ativo_por_vigia: Option<String> = None;
        let mut ausente_desde: Option<Instant> = None;
        // Jogo cuja ativação falhou (ex.: Modo Jogo já ligado à mão): não tenta de novo enquanto roda.
        let mut recusado: Option<String> = None;
        loop {
            tokio::time::sleep(INTERVALO).await;
            let estado = app.state::<Estado>();
            if estado.demo {
                continue;
            }
            let a = ajustes::ler(&estado.pastas);
            if !a.modo_jogo_auto || a.jogos.is_empty() {
                ausente_desde = None;
                continue;
            }
            let rodando = match processos().await {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("vigia: {e}");
                    continue;
                }
            };
            let roda = |j: &str| rodando.contains(&j.to_lowercase());
            if recusado.as_deref().is_some_and(|j| !roda(j)) {
                recusado = None;
            }
            let jogo_ausente = ativo_por_vigia.as_deref().is_some_and(|j| !roda(j));
            if !jogo_ausente {
                ausente_desde = None;
            } else if ausente_desde.is_none() {
                ausente_desde = Some(Instant::now());
            }
            let decisao = decidir(
                &a.jogos,
                &rodando,
                ativo_por_vigia.as_deref(),
                ausente_desde.map(|t| t.elapsed()),
            );
            let r = match decisao {
                Decisao::Nada => continue,
                Decisao::Ativar(j) if recusado.as_ref() == Some(&j) => continue,
                Decisao::Ativar(j) => {
                    let p = json!({
                        "preset": a.modo_jogo_preset, "fechar": [], "jogo": j,
                        "automatico": true, "confirmado": true, "avancado": a.modo_avancado
                    });
                    match comandos::executar_interno(&estado, "modojogo", "ativar", p).await {
                        Ok(_) => {
                            ativo_por_vigia = Some(j.clone());
                            ausente_desde = None;
                            Ok(json!({"ativo": true, "jogo": j}))
                        }
                        Err(e) => {
                            recusado = Some(j);
                            Err(e)
                        }
                    }
                }
                Decisao::Desativar => {
                    // Mesmo se falhar, para de vigiar este jogo: o erro sai uma vez só (sem repetir a
                    // cada ciclo) e `desativar` é idempotente, a UI pode repetir.
                    ativo_por_vigia = None;
                    ausente_desde = None;
                    let p = json!({"confirmado": true});
                    comandos::executar_interno(&estado, "modojogo", "desativar", p)
                        .await
                        .map(|_| json!({"ativo": false, "jogo": null}))
                }
            };
            let evento = r.unwrap_or_else(|e| {
                eprintln!("vigia: {e}");
                json!({"erro": e})
            });
            let _ = app.emit("modojogo", evento);
        }
    });
}

#[cfg(test)]
mod testes {
    use super::*;

    fn conjunto(itens: &[&str]) -> HashSet<String> {
        itens.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn exes_de_tasklist_le_csv() {
        let csv = "\"NexTune.exe\",\"1234\",\"Console\",\"1\",\"85.000 K\"\r\n\
                   \"Jogo Legal.exe\",\"99\",\"Console\",\"1\",\"1,2 MB\"\r\n\
                   \"obs64.exe\",\"7\",\"Console\",\"1\",\"x, y\"\r\n\
                   INFO: No tasks are running.\r\n";
        assert_eq!(
            exes_de_tasklist(csv),
            conjunto(&["nextune.exe", "jogo legal.exe", "obs64.exe"])
        );
        assert!(exes_de_tasklist("").is_empty());
    }

    #[test]
    fn decidir_tabela() {
        let jogos = vec!["Jogo Legal.exe".to_string()];
        let com_jogo = conjunto(&["jogo legal.exe", "explorer.exe"]);
        let sem_jogo = conjunto(&["explorer.exe"]);
        assert_eq!(
            decidir(&jogos, &com_jogo, None, None),
            Decisao::Ativar("Jogo Legal.exe".into())
        );
        assert_eq!(decidir(&jogos, &sem_jogo, None, None), Decisao::Nada);
        let ativo = Some("Jogo Legal.exe");
        assert_eq!(
            decidir(&jogos, &sem_jogo, ativo, Some(Duration::from_secs(15))),
            Decisao::Nada
        );
        assert_eq!(
            decidir(&jogos, &sem_jogo, ativo, Some(Duration::from_secs(30))),
            Decisao::Desativar
        );
        assert_eq!(decidir(&jogos, &sem_jogo, ativo, None), Decisao::Nada);
        assert_eq!(
            decidir(&jogos, &com_jogo, ativo, Some(Duration::from_secs(60))),
            Decisao::Nada
        );
        assert_eq!(decidir(&[], &com_jogo, None, None), Decisao::Nada);
    }
}
