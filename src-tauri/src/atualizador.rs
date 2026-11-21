//! Atualizador do NexTune (`tauri-plugin-updater`, assinatura minisign).
//!
//! Contrato com a UI:
//! - `atualizacao_verificar() -> {versao, notas} | null`: `null` sem atualização, no modo
//!   demonstração ou quando a verificação falha (ainda não há `latest.json` publicado até o
//!   Plano 6; o erro vai só para o log).
//! - `atualizacao_instalar()`: baixa, confere a assinatura com a chave pública de
//!   `tauri.conf.json`, instala e reinicia o programa. Erro em português se não houver
//!   atualização; recusa no modo demonstração.

use crate::comandos::Estado;
use serde::Serialize;
use tauri::{AppHandle, State};
use tauri_plugin_updater::UpdaterExt;

#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Atualizacao {
    pub versao: String,
    pub notas: Option<String>,
}

#[tauri::command]
pub async fn atualizacao_verificar(
    app: AppHandle,
    estado: State<'_, Estado>,
) -> Result<Option<Atualizacao>, String> {
    if estado.demo {
        return Ok(None);
    }
    match app.updater().map_err(|e| e.to_string())?.check().await {
        Ok(Some(u)) => Ok(Some(Atualizacao {
            versao: u.version.clone(),
            notas: u.body.clone(),
        })),
        Ok(None) => Ok(None),
        Err(e) => {
            eprintln!("atualizador: {e}");
            Ok(None)
        }
    }
}

#[tauri::command]
pub async fn atualizacao_instalar(
    app: AppHandle,
    estado: State<'_, Estado>,
) -> Result<(), String> {
    if estado.demo {
        return Err("demo".into());
    }
    let Some(u) = app
        .updater()
        .map_err(|e| e.to_string())?
        .check()
        .await
        .map_err(|e| e.to_string())?
    else {
        return Err("nenhuma atualização disponível".into());
    };
    u.download_and_install(|_chunk, _total| {}, || {})
        .await
        .map_err(|e| e.to_string())?;
    app.restart()
}
