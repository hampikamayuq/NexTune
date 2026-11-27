//! Ícone na bandeja, janela que some ao fechar, início com o Windows e abertura de links.
//!
//! Contrato:
//! - Bandeja `principal` com o menu "Abrir o NexTune" / "Sair"; clique esquerdo abre a janela.
//! - Com a bandeja ativa (`Ajustes::bandeja_ativa`), fechar a janela a **destrói** (libera o
//!   WebView2); "Abrir" recria a janela `main` a partir de `tauri.conf.json`.
//! - `autostart(ligar)`: tarefa agendada `NexTune` (logon, privilégio mais alto) que roda
//!   `"<exe>" --bandeja`, criada por XML (`schtasks /XML`) para rodar na bateria e sem limite de
//!   tempo; o XML vai para `<Windows>\Temp` (via `GetSystemDirectoryW`) com nome novo e é apagado.
//!   Recusa quando o executável não está sob `%ProgramFiles%`/`%ProgramFiles(x86)%` (nunca
//!   aponta para pasta gravável pelo usuário). `autostart_estado()` consulta a tarefa.
//! - `abrir_url(url)`: só `https://<host>/...` ou `ms-windows-store://pdp/?ProductId=<12>`; abre por
//!   `<Windows>\explorer.exe "<url>"` (pasta via `GetSystemDirectoryW`; o explorer entrega o link
//!   ao shell do usuário, então o navegador abre sem elevação), sem shell intermediário e sem
//!   janela de console.

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

/// Pasta do Windows a partir de `GetSystemDirectoryW` (pai de System32), nunca de `%SystemRoot%`:
/// o usuário controla as variáveis de ambiente e o app roda elevado.
fn pasta_windows() -> PathBuf {
    crate::host::pasta_system32()
        .parent()
        .map_or_else(|| PathBuf::from(r"C:\Windows"), Path::to_path_buf)
}

/// Processo de System32 sem janela de console.
fn comando_oculto(nome: &str) -> Command {
    comando_oculto_em(system32(nome))
}

/// Processo sem janela de console a partir de um caminho absoluto.
fn comando_oculto_em(exe: PathBuf) -> Command {
    #[allow(unused_mut)] // só o Windows usa `creation_flags`
    let mut cmd = Command::new(exe);
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
    // `<Windows>\explorer.exe`, não System32: o explorer repassa o link à instância do shell do
    // usuário (token sem elevação); o rundll32 herdaria o token elevado do NexTune.
    let mut cmd = comando_oculto_em(pasta_windows().join("explorer.exe"));
    // Entre aspas: o explorer trata vírgula como separador de opções. `url_permitida` já barra aspas.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.raw_arg(format!("\"{url}\""));
    }
    #[cfg(not(windows))]
    cmd.arg(url.as_str());
    let mut filho = cmd
        .spawn()
        .map_err(|e| format!("não foi possível abrir o link: {e}"))?;
    // O explorer sai logo depois de entregar o link; espera fora da thread do comando.
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
    let s = crate::caminhos::sistema();
    exe_sob(exe, &[s.program_files.clone(), s.program_files_x86.clone()])
}

/// Escapa texto para conteúdo de elemento XML.
fn escapar_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// Definição da tarefa de início com o Windows. Os padrões do `schtasks /SC ONLOGON` (só na
/// tomada, parar ao passar para a bateria, limite de 72 h) matariam o NexTune em notebook.
fn xml_tarefa(exe: &str) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><MultipleInstances>IgnoreNew</MultipleInstances><StartWhenAvailable>true</StartWhenAvailable><AllowHardTerminate>false</AllowHardTerminate></Settings>
  <Actions Context="Author"><Exec><Command>"{}"</Command><Arguments>--bandeja</Arguments></Exec></Actions>
</Task>
"#,
        escapar_xml(exe)
    )
}

/// Link simbólico ou junção (reparse point de nome).
fn e_link(p: &Path) -> bool {
    std::fs::symlink_metadata(p).is_ok_and(|m| m.file_type().is_symlink())
}

/// Grava o XML da tarefa em `pasta` com nome novo (UTF-16 LE com BOM, formato que o
/// `schtasks /XML` sempre aceita) e devolve o caminho.
fn gravar_xml_tarefa(pasta: &Path, texto: &str) -> std::io::Result<PathBuf> {
    use std::io::Write;
    if !pasta.is_absolute() {
        return Err(std::io::Error::other("pasta temporária sem caminho absoluto"));
    }
    std::fs::create_dir_all(pasta)?;
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos());
    let caminho = pasta.join(format!("autostart-{}-{nanos}.xml", std::process::id()));
    if pasta.parent().is_some_and(e_link) || e_link(pasta) || e_link(&caminho) {
        return Err(std::io::Error::other("a pasta temporária é um link"));
    }
    let mut bytes = vec![0xFF, 0xFE];
    bytes.extend(texto.encode_utf16().flat_map(u16::to_le_bytes));
    // `create_new`: falha se alguém já pôs um arquivo (ou link) com esse nome.
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&caminho)?
        .write_all(&bytes)?;
    Ok(caminho)
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
    let mut cmd = comando_oculto("schtasks.exe");
    let mut xml = None;
    if ligar {
        // `<Windows>\Temp` por chamada de sistema, não %APPDATA%/%ProgramData% (o usuário controla
        // o ambiente): ali outro processo do usuário não altera o arquivo que o schtasks elevado lê.
        let texto = xml_tarefa(&exe.to_string_lossy());
        let c = gravar_xml_tarefa(&pasta_windows().join("Temp"), &texto)
            .map_err(|e| format!("não foi possível gravar a definição da tarefa: {e}"))?;
        cmd.args(["/Create", "/TN", "NexTune", "/XML"])
            .arg(&c)
            .arg("/F");
        xml = Some(c);
    } else {
        cmd.args(["/Delete", "/TN", "NexTune", "/F"]);
    }
    let s = cmd.stdout(Stdio::null()).stderr(Stdio::null()).status();
    if let Some(c) = &xml {
        let _ = std::fs::remove_file(c);
    }
    let s = s.map_err(|e| format!("falha ao rodar schtasks: {e}"))?;
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
    fn escapar_xml_troca_os_cinco_caracteres() {
        assert_eq!(
            escapar_xml(r#"C:\A&B <x> "y" 'z'"#),
            r#"C:\A&amp;B &lt;x&gt; &quot;y&quot; &apos;z&apos;"#
        );
        assert_eq!(escapar_xml("sem nada"), "sem nada");
    }

    #[test]
    fn xml_tarefa_roda_na_bateria_sem_limite_e_com_o_exe_escapado() {
        let x = xml_tarefa(r"C:\Program Files\R&D\NexTune.exe");
        assert!(x.contains("<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>"));
        assert!(x.contains("<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"));
        assert!(x.contains("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"));
        assert!(x.contains("<RunLevel>HighestAvailable</RunLevel>"));
        assert!(x.contains(r#"<Command>"C:\Program Files\R&amp;D\NexTune.exe"</Command>"#));
        assert!(x.contains("<Arguments>--bandeja</Arguments>"));
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
