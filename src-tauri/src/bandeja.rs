//! Ícone na bandeja, janela que some ao fechar, início com o Windows e abertura de links.
//!
//! Contrato:
//! - Bandeja `principal` com o menu "Abrir o NexTune" / "Sair"; clique esquerdo abre a janela.
//! - Com a bandeja ativa (`Ajustes::bandeja_ativa`), fechar a janela a **destrói** (libera o
//!   WebView2); "Abrir" recria a janela `main` a partir de `tauri.conf.json`.
//! - `autostart(ligar)`: tarefa agendada `NexTune` (ONLOGON, HIGHEST) que roda `"<exe>" --bandeja`;
//!   recusa quando o executável não está sob `%ProgramFiles%`/`%ProgramFiles(x86)%` (nunca aponta
//!   para pasta gravável pelo usuário). `autostart_estado()` consulta a tarefa.
//! - `abrir_url(url)`: só `https://<host>/...` ou `ms-windows-store://pdp/?ProductId=<12>`; abre por
//!   `rundll32.exe url.dll,FileProtocolHandler` sem shell e sem janela de console.

use crate::caminhos::env_ou;
use crate::comandos::Estado;
use regex::Regex;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, CloseRequestApi, Manager, State, WebviewWindowBuilder, Window};

/// Id do ícone da bandeja.
pub const ID: &str = "principal";
const MAX_URL: usize = 2048;

/// Cria o ícone da bandeja; não faz nada se ele já existe.
pub fn criar_bandeja(app: &AppHandle) -> tauri::Result<()> {
    if app.tray_by_id(ID).is_some() {
        return Ok(());
    }
    let menu = Menu::with_items(
        app,
        &[
            &MenuItem::with_id(app, "abrir", "Abrir o NexTune", true, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, "sair", "Sair", true, None::<&str>)?,
        ],
    )?;
    let mut b = TrayIconBuilder::with_id(ID)
        .tooltip("NexTune")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, ev| match ev.id().as_ref() {
            "abrir" => abrir_janela(app),
            "sair" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, ev| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = ev
            {
                abrir_janela(tray.app_handle());
            }
        });
    if let Some(icone) = app.default_window_icon().cloned() {
        b = b.icon(icone);
    }
    b.build(app)?;
    Ok(())
}

pub fn remover_bandeja(app: &AppHandle) {
    let _ = app.remove_tray_by_id(ID);
}

/// Mostra e foca a janela `main`; se ela foi destruída, recria a partir da configuração.
pub fn abrir_janela(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    let Some(cfg) = app.config().app.windows.first().cloned() else {
        eprintln!("bandeja: tauri.conf.json sem janela configurada");
        return;
    };
    let app = app.clone();
    // No Windows, criar janela dentro de um handler síncrono trava o WebView2: cria fora dele.
    tauri::async_runtime::spawn(async move {
        if let Err(e) = WebviewWindowBuilder::from_config(&app, &cfg).and_then(|b| b.build()) {
            eprintln!("bandeja: não foi possível abrir a janela: {e}");
        }
    });
}

/// Com a bandeja ativa, fechar destrói a janela (o processo segue na bandeja).
pub fn tratar_fechar(window: &Window, api: &CloseRequestApi, bandeja_ativa: bool) {
    if bandeja_ativa {
        api.prevent_close();
        let w = window.clone();
        tauri::async_runtime::spawn(async move {
            let _ = w.destroy();
        });
    }
}

fn re_url() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^(https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/.*)?|ms-windows-store://pdp/\?ProductId=[A-Z0-9]{12})$",
        )
        .expect("regex válida")
    })
}

/// Links que a interface pode abrir (RF6): https com host, ou página de produto da Microsoft Store.
pub fn url_permitida(url: &str) -> bool {
    url.len() <= MAX_URL
        && !url.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"')
        && re_url().is_match(url)
}

/// `<System32>\<nome>`: binários do sistema por caminho absoluto (política do `host.rs`).
pub(crate) fn system32(nome: &str) -> PathBuf {
    crate::host::pasta_system32().join(nome)
}

/// Processo de System32 sem janela de console.
fn comando_oculto(nome: &str) -> Command {
    #[allow(unused_mut)] // só o Windows usa `creation_flags`
    let mut cmd = Command::new(system32(nome));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(crate::host::CREATE_NO_WINDOW);
    }
    cmd
}

#[tauri::command]
pub fn abrir_url(url: String, estado: State<'_, Estado>) -> Result<(), String> {
    if !url_permitida(&url) {
        return Err("url não permitida".into());
    }
    if estado.demo {
        return Ok(());
    }
    let mut filho = comando_oculto("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", url.as_str()])
        .spawn()
        .map_err(|e| format!("não foi possível abrir o link: {e}"))?;
    // O rundll32 sai logo depois de entregar o link; espera fora da thread do comando.
    std::thread::spawn(move || {
        let _ = filho.wait();
    });
    Ok(())
}

/// `exe` está dentro de uma das `raizes` (comparação sem diferenciar caixa).
fn exe_sob(exe: &Path, raizes: &[PathBuf]) -> bool {
    let e = exe.to_string_lossy().to_lowercase();
    raizes.iter().any(|r| {
        let r = r.to_string_lossy().trim_end_matches('\\').to_lowercase();
        !r.is_empty() && e.starts_with(&format!("{r}\\"))
    })
}

/// O executável está instalado (sob `%ProgramFiles%` ou `%ProgramFiles(x86)%`).
pub fn exe_em_program_files(exe: &Path) -> bool {
    exe_sob(
        exe,
        &[
            env_ou("ProgramFiles", r"C:\Program Files"),
            env_ou("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        ],
    )
}

fn autostart_estado_interno() -> bool {
    comando_oculto("schtasks.exe")
        .args(["/Query", "/TN", "NexTune"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Liga/desliga o início com o Windows; devolve o estado real da tarefa depois da mudança.
#[tauri::command]
pub fn autostart(ligar: bool, estado: State<'_, Estado>) -> Result<bool, String> {
    if estado.demo {
        return Ok(ligar);
    }
    let exe = std::env::current_exe().map_err(|e| format!("executável desconhecido: {e}"))?;
    if ligar && !exe_em_program_files(&exe) {
        return Err("instalação de desenvolvimento: autostart só com o programa instalado".into());
    }
    let tr = format!("\"{}\" --bandeja", exe.display());
    let mut cmd = comando_oculto("schtasks.exe");
    if ligar {
        cmd.args([
            "/Create",
            "/TN",
            "NexTune",
            "/SC",
            "ONLOGON",
            "/RL",
            "HIGHEST",
            "/TR",
            tr.as_str(),
            "/F",
        ]);
    } else {
        cmd.args(["/Delete", "/TN", "NexTune", "/F"]);
    }
    let s = cmd
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("falha ao rodar schtasks: {e}"))?;
    if !s.success() {
        return Err(format!(
            "schtasks terminou com código {}",
            s.code().unwrap_or(-1)
        ));
    }
    Ok(autostart_estado_interno())
}

#[tauri::command]
pub fn autostart_estado(estado: State<'_, Estado>) -> bool {
    !estado.demo && autostart_estado_interno()
}

#[cfg(test)]
mod testes {
    use super::*;

    #[test]
    fn url_permitida_aceita() {
        assert!(url_permitida("https://support.lenovo.com/br/pt/x"));
        assert!(url_permitida("ms-windows-store://pdp/?ProductId=9WZDNCRFHVFW"));
        let limite = format!("https://a.com/{}", "a".repeat(MAX_URL - 14));
        assert_eq!(limite.len(), MAX_URL);
        assert!(url_permitida(&limite));
    }

    #[test]
    fn url_permitida_recusa() {
        for ruim in [
            "http://a.com",
            "https://",
            "https:///x",
            "javascript:alert(1)",
            "file:///C:/x",
            "https://a.com/x y",
            "https://a.com/\n",
            "https://a.com/x\"y",
            "ms-windows-store://pdp/?ProductId=abc",
        ] {
            assert!(!url_permitida(ruim), "{ruim:?}");
        }
        let longa = format!("https://a.com/{}", "a".repeat(MAX_URL - 13));
        assert_eq!(longa.len(), 2049);
        assert!(!url_permitida(&longa));
    }

    #[test]
    fn exe_sob_program_files() {
        let raizes = [
            PathBuf::from(r"C:\Program Files"),
            PathBuf::from(r"C:\Program Files (x86)"),
        ];
        assert!(exe_sob(Path::new(r"C:\Program Files\NexTune\nextune.exe"), &raizes));
        assert!(exe_sob(Path::new(r"c:\PROGRAM FILES\NexTune\NexTune.exe"), &raizes));
        assert!(exe_sob(Path::new(r"C:\Program Files (x86)\X\x.exe"), &raizes));
        assert!(!exe_sob(
            Path::new(r"C:\Users\x\AppData\Local\Programs\NexTune\nextune.exe"),
            &raizes
        ));
        assert!(!exe_sob(Path::new(r"D:\dev\target\release\nextune.exe"), &raizes));
        assert!(!exe_sob(Path::new(r"C:\Program Files Falso\x.exe"), &raizes));
    }

    #[test]
    fn system32_e_caminho_absoluto_no_windows() {
        let p = system32("schtasks.exe");
        assert!(p.ends_with("schtasks.exe"));
        if cfg!(windows) {
            assert!(p.is_absolute(), "{p:?}");
        }
    }
}
