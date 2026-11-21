pub mod acoes;
pub mod ajustes;
pub mod bandeja;
pub mod caminhos;
pub mod comandos;
pub mod host;
pub mod perfil;
pub mod protocolo;
pub mod vigia;

use tauri::Manager;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let demo = std::env::args().any(|a| a == "--demo") || !cfg!(windows);
    let app = tauri::Builder::default()
        .setup(move |app| {
            let pastas = caminhos::pastas(app.handle());
            let versao = app.package_info().version.to_string();
            let a = ajustes::ler(&pastas);
            app.manage(comandos::Estado::novo(pastas, demo, versao));
            // `--bandeja` (início com o Windows) abre só na bandeja; o ícone existe mesmo com a
            // bandeja desligada nos ajustes, senão o app ficaria inalcançável.
            let so_bandeja = std::env::args().any(|x| x == "--bandeja");
            if a.bandeja_ativa() || so_bandeja {
                bandeja::criar_bandeja(app.handle())?;
            }
            if so_bandeja && let Some(w) = app.get_webview_window("main") {
                let _ = w.destroy();
            }
            vigia::iniciar(app.handle().clone());
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                let a = ajustes::ler(&window.state::<comandos::Estado>().pastas);
                bandeja::tratar_fechar(window, api, a.bandeja_ativa());
            }
        })
        .invoke_handler(tauri::generate_handler![
            comandos::executar,
            comandos::cancelar,
            comandos::ajustes_ler,
            comandos::ajustes_gravar,
            comandos::dados,
            comandos::info,
            comandos::ponto_sessao,
            bandeja::abrir_url,
            bandeja::autostart,
            bandeja::autostart_estado,
        ])
        .build(tauri::generate_context!())
        .expect("erro ao construir o aplicativo Tauri");

    app.run(|app, evento| match evento {
        // Sem janela (`code: None`) o processo segue enquanto houver ícone na bandeja; "Sair" usa
        // `exit(0)` e passa.
        tauri::RunEvent::ExitRequested {
            api, code: None, ..
        } if app.tray_by_id(bandeja::ID).is_some() => api.prevent_exit(),
        tauri::RunEvent::Exit => {
            if let Some(estado) = app.try_state::<comandos::Estado>() {
                tauri::async_runtime::block_on(async {
                    let host = estado.host.lock().await.clone();
                    host.encerrar().await;
                });
            }
        }
        _ => {}
    });
}
