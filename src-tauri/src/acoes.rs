use crate::caminhos;
use regex::Regex;
use serde_json::{Map, Value};
use std::path::Path;
use std::sync::OnceLock;

#[derive(thiserror::Error, Debug)]
pub enum ErroValidacao {
    #[error("ação não permitida: {0}")]
    NaoPermitida(String),
    #[error("parâmetro inválido: {0}")]
    Parametro(String),
}

pub const CATEGORIAS_LIMPEZA: &[&str] = &[
    "temp_usuario",
    "temp_windows",
    "wu_cache",
    "entrega",
    "informes",
    "miniaturas",
    "launchers",
    "navegadores",
    "minidumps",
    "lixeira",
    "shaders",
    "dism_componentes",
    "windows_old",
    "pontos_antigos",
];

const MODULOS: &[&str] = &[
    "host",
    "diagnostico",
    "limpeza",
    "quarentena",
    "sistema",
    "programas",
    "inicializacao",
    "ajusteswin",
];

/// Ações que escrevem no sistema: exigem sessão verificada (`comandos::verificar_sessao`). A UI roda
/// `garantirPonto()` antes das que mexem fora da pasta do app (limpar, desinstalar, restaurar);
/// purgar a quarentena e levar restos para ela só tocam `%ProgramData%\NexTune`.
const ESCRITA: &[(&str, &str)] = &[
    ("limpeza", "limpar"),
    ("programas", "desinstalar"),
    ("programas", "limparRestos"),
    ("quarentena", "restaurar"),
    ("quarentena", "purgar"),
    ("quarentena", "purgarVencidos"),
    ("sistema", "criarPonto"),
    ("sistema", "ligarProtecao"),
    ("inicializacao", "alternar"),
    ("ajusteswin", "aplicar"),
    ("ajusteswin", "restaurar"),
];

/// Tipos de item que `programas/limparRestos` aceita.
const TIPOS_RESTO: &[&str] = &["pasta", "arquivo", "atalho", "chave"];
/// Máximo de ids por chamada de `quarentena/restaurar|purgar`.
const MAX_IDS: usize = 200;
/// Máximo de itens por chamada de `programas/limparRestos`.
const MAX_ITENS: usize = 500;
/// Tamanho máximo (em caracteres) de nomes, editores e caminhos vindos da UI.
const MAX_TEXTO: usize = 260;
/// Tamanho máximo (em caracteres) de um caminho ou chave em `limparRestos`.
const MAX_CAMINHO: usize = 1024;
/// Máximo de ids por chamada de `ajusteswin/aplicar|restaurar`.
const MAX_IDS_AJUSTES: usize = 50;

pub fn modulos_permitidos() -> &'static [&'static str] {
    MODULOS
}

/// `true` para as ações que alteram o sistema (tabela do contrato §Rust do Plano 2).
pub fn e_escrita(modulo: &str, acao: &str) -> bool {
    ESCRITA.contains(&(modulo, acao))
}

fn re_id_quarentena() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\d{8}-\d{6}-[0-9a-f]{4}$").expect("regex válida"))
}

fn re_id_programa() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"^(cl:(hklm64|hklm32|hkcu):.{1,255}|st:.{1,255})$").expect("regex válida")
    })
}

fn re_id_inicio() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"^(run:(hkcu|hklm|hklm32):.{1,255}|pasta:(usuario|todos):.{1,255}|tarefa:\\.{1,255})$",
        )
        .expect("regex válida")
    })
}

fn re_id_ajuste() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-z0-9_]{1,40}$").expect("regex válida"))
}

fn erro(msg: impl Into<String>) -> ErroValidacao {
    ErroValidacao::Parametro(msg.into())
}

fn como_objeto(params: &Value) -> Result<Map<String, Value>, ErroValidacao> {
    match params {
        Value::Null => Ok(Map::new()),
        Value::Object(m) => Ok(m.clone()),
        _ => Err(erro("params deve ser um objeto")),
    }
}

fn so_chaves(m: &Map<String, Value>, permitidas: &[&str]) -> Result<(), ErroValidacao> {
    match m.keys().find(|k| !permitidas.contains(&k.as_str())) {
        Some(k) => Err(erro(format!("chave desconhecida: {k}"))),
        None => Ok(()),
    }
}

fn copiar_bool(
    de: &Map<String, Value>,
    para: &mut Map<String, Value>,
    chave: &str,
) -> Result<(), ErroValidacao> {
    if let Some(v) = de.get(chave) {
        if !v.is_boolean() {
            return Err(erro(format!("{chave} deve ser booleano")));
        }
        para.insert(chave.to_string(), v.clone());
    }
    Ok(())
}

fn tem_controle(s: &str) -> bool {
    s.chars().any(char::is_control)
}

/// Lê `chave` como texto sem caracteres de controle e com até `max` caracteres. `Ok(None)` se ausente.
fn texto_opcional(
    m: &Map<String, Value>,
    chave: &str,
    max: usize,
) -> Result<Option<String>, ErroValidacao> {
    let Some(v) = m.get(chave) else {
        return Ok(None);
    };
    let s = v
        .as_str()
        .ok_or_else(|| erro(format!("{chave} deve ser texto")))?;
    if s.chars().count() > max {
        return Err(erro(format!("{chave} deve ter até {max} caracteres")));
    }
    if tem_controle(s) {
        return Err(erro(format!("{chave} contém caracteres de controle")));
    }
    Ok(Some(s.to_string()))
}

/// Como `texto_opcional`, mas obrigatório e não vazio.
fn texto_obrigatorio(
    m: &Map<String, Value>,
    chave: &str,
    max: usize,
) -> Result<String, ErroValidacao> {
    let s = texto_opcional(m, chave, max)?.ok_or_else(|| erro(format!("{chave} é obrigatório")))?;
    if s.trim().is_empty() {
        return Err(erro(format!("{chave} não pode ser vazio")));
    }
    Ok(s)
}

fn copiar_texto(
    de: &Map<String, Value>,
    para: &mut Map<String, Value>,
    chave: &str,
    max: usize,
) -> Result<(), ErroValidacao> {
    if let Some(s) = texto_opcional(de, chave, max)? {
        para.insert(chave.to_string(), Value::String(s));
    }
    Ok(())
}

/// `confirmado:true` estrito (booleano, não `1` nem `"true"`).
fn exigir_confirmado(m: &Map<String, Value>) -> Result<(), ErroValidacao> {
    if m.get("confirmado") != Some(&Value::Bool(true)) {
        return Err(erro("confirmado:true é obrigatório"));
    }
    Ok(())
}

/// `dias` inteiro em 1..=90 (sem frações nem textos).
fn dias(v: &Value) -> Result<Value, ErroValidacao> {
    match v.as_i64() {
        Some(n) if (1..=90).contains(&n) => Ok(Value::from(n)),
        _ => Err(erro("dias deve ser inteiro entre 1 e 90")),
    }
}

/// `simular` (objeto) só é aceito em modo teste; copia para `saida` quando presente.
fn copiar_simular(
    de: &Map<String, Value>,
    para: &mut Map<String, Value>,
    teste: bool,
) -> Result<(), ErroValidacao> {
    if let Some(s) = de.get("simular") {
        if !teste {
            return Err(erro("simular só é aceito em modo teste"));
        }
        if !s.is_object() {
            return Err(erro("simular deve ser objeto"));
        }
        para.insert("simular".into(), s.clone());
    }
    Ok(())
}

/// `ids`: lista não vazia (até `max`) de textos que casam `re`, sem controle e sem repetição.
fn lista_de_ids(
    m: &Map<String, Value>,
    re: &Regex,
    max: usize,
    rotulo: &str,
) -> Result<Value, ErroValidacao> {
    let ids = m
        .get("ids")
        .and_then(Value::as_array)
        .ok_or_else(|| erro("ids é obrigatório (lista)"))?;
    if ids.is_empty() {
        return Err(erro("ids não pode ser vazio"));
    }
    if ids.len() > max {
        return Err(erro(format!("ids: no máximo {max} por vez")));
    }
    let mut vistos: Vec<&str> = Vec::with_capacity(ids.len());
    for v in ids {
        let id = v.as_str().ok_or_else(|| erro("ids deve conter textos"))?;
        if tem_controle(id) || !re.is_match(id) {
            return Err(erro(format!("id de {rotulo} inválido: {id}")));
        }
        if vistos.contains(&id) {
            return Err(erro(format!("id repetido: {id}")));
        }
        vistos.push(id);
    }
    Ok(Value::Array(ids.clone()))
}

/// `ids`: lista não vazia (até `MAX_IDS`) de ids de quarentena `yyyyMMdd-HHmmss-xxxx`, sem repetição.
fn ids_quarentena(m: &Map<String, Value>) -> Result<Value, ErroValidacao> {
    lista_de_ids(m, re_id_quarentena(), MAX_IDS, "quarentena")
}

/// Id de item de inicialização: `run:<hkcu|hklm|hklm32>:<nome>`, `pasta:<usuario|todos>:<arquivo>` ou
/// `tarefa:\<caminho><nome>`; 1..=255 caracteres após o prefixo, sem controle. O PowerShell resolve o
/// id contra a própria lista; aqui ele nunca vira caminho.
fn id_inicio(m: &Map<String, Value>) -> Result<String, ErroValidacao> {
    let id = m
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| erro("id é obrigatório (texto)"))?;
    if tem_controle(id) || !re_id_inicio().is_match(id) {
        return Err(erro("id de inicialização inválido"));
    }
    Ok(id.to_string())
}

/// Id de programa: `cl:<hklm64|hklm32|hkcu>:<chave>` ou `st:<PackageFullName>`, 1..=255 caracteres
/// após o prefixo, sem caracteres de controle. O PowerShell resolve o id contra a própria lista;
/// aqui ele nunca vira caminho.
fn id_programa(m: &Map<String, Value>) -> Result<String, ErroValidacao> {
    let id = m
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| erro("id é obrigatório (texto)"))?;
    if tem_controle(id) || !re_id_programa().is_match(id) {
        return Err(erro("id de programa inválido"));
    }
    Ok(id.to_string())
}

fn caminho_absoluto(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\'
}

/// Chave de registro aceita em `limparRestos`: `HKCU\...` ou `HKLM\...` (sem diferenciar caixa), ao
/// menos três segmentos não vazios (`HKCU\Software\X`), nunca sob `HKLM\SYSTEM`,
/// `HKLM\SOFTWARE\Microsoft\Windows`, `HKLM\SOFTWARE\Microsoft\Windows NT` (nem os espelhos
/// `WOW6432Node` e `HKCU\Software\Microsoft\Windows[ NT]`).
fn chave_registro_permitida(chave: &str) -> bool {
    let partes: Vec<String> = chave.split('\\').map(str::to_lowercase).collect();
    if partes.len() < 3 || partes.iter().any(|p| p.trim().is_empty()) {
        return false;
    }
    if !matches!(partes[0].as_str(), "hkcu" | "hklm") {
        return false;
    }
    let resto: Vec<&str> = partes[1..].iter().map(String::as_str).collect();
    let comeca =
        |prefixo: &[&str]| resto.len() >= prefixo.len() && resto[..prefixo.len()] == *prefixo;
    if partes[0] == "hklm" && comeca(&["system"]) {
        return false;
    }
    for ms in [
        &["software", "microsoft"][..],
        &["software", "wow6432node", "microsoft"][..],
    ] {
        for win in ["windows", "windows nt"] {
            let mut pre: Vec<&str> = ms.to_vec();
            pre.push(win);
            if comeca(&pre) {
                return false;
            }
        }
    }
    true
}

/// Um item de `limparRestos`: exatamente `{tipo, caminho}`; pasta/arquivo/atalho absolutos e fora de
/// `caminho_protegido` (Review Focus 7); chave conforme `chave_registro_permitida`.
fn item_resto(v: &Value) -> Result<Value, ErroValidacao> {
    let m = v
        .as_object()
        .ok_or_else(|| erro("itens deve conter objetos {tipo, caminho}"))?;
    so_chaves(m, &["tipo", "caminho"])?;
    let tipo = m
        .get("tipo")
        .and_then(Value::as_str)
        .ok_or_else(|| erro("tipo é obrigatório (texto)"))?;
    if !TIPOS_RESTO.contains(&tipo) {
        return Err(erro(format!("tipo desconhecido: {tipo}")));
    }
    let caminho = texto_obrigatorio(m, "caminho", MAX_CAMINHO)?;
    let ok = if tipo == "chave" {
        chave_registro_permitida(&caminho)
    } else {
        caminho_absoluto(&caminho) && !caminhos::caminho_protegido(Path::new(&caminho))
    };
    if !ok {
        return Err(erro(format!("caminho recusado: {caminho}")));
    }
    Ok(serde_json::json!({"tipo": tipo, "caminho": caminho}))
}

fn forcar_perfil(v: &Value) -> Result<Value, ErroValidacao> {
    let m = v
        .as_object()
        .ok_or_else(|| erro("forcarPerfil deve ser objeto"))?;
    so_chaves(m, &["classe", "disco"])?;
    let classe = m.get("classe").and_then(Value::as_str);
    let disco = m.get("disco").and_then(Value::as_str);
    match (classe, disco) {
        (Some(c @ ("basico" | "medio" | "gamer")), Some(d @ ("hdd" | "ssd"))) => {
            Ok(serde_json::json!({"classe": c, "disco": d}))
        }
        _ => Err(erro("forcarPerfil: classe/disco inválidos")),
    }
}

/// Valida a ação contra a allowlist e devolve os params saneados.
pub fn validar(
    modulo: &str,
    acao: &str,
    params: &Value,
    teste: bool,
) -> Result<Value, ErroValidacao> {
    match (modulo, acao) {
        ("host", "ping") => {
            so_chaves(&como_objeto(params)?, &[])?;
            Ok(Value::Object(Map::new()))
        }
        ("diagnostico", "coletar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["simular", "forcarPerfil", "resetarPerfil"])?;
            if m.contains_key("forcarPerfil") && m.contains_key("resetarPerfil") {
                return Err(erro("forcarPerfil e resetarPerfil não podem vir juntos"));
            }
            let mut saida = Map::new();
            copiar_bool(&m, &mut saida, "resetarPerfil")?;
            if let Some(s) = m.get("simular") {
                if !teste {
                    return Err(erro("simular só é aceito em modo teste"));
                }
                if !s.is_object() {
                    return Err(erro("simular deve ser objeto"));
                }
                saida.insert("simular".into(), s.clone());
            }
            if let Some(f) = m.get("forcarPerfil") {
                saida.insert("forcarPerfil".into(), forcar_perfil(f)?);
            }
            Ok(Value::Object(saida))
        }
        ("limpeza", "analisar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["avancado"])?;
            let mut saida = Map::new();
            copiar_bool(&m, &mut saida, "avancado")?;
            Ok(Value::Object(saida))
        }
        ("limpeza", "limpar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["categorias", "confirmado", "avancado", "resetBase"])?;
            let cats = m
                .get("categorias")
                .and_then(Value::as_array)
                .ok_or_else(|| erro("categorias é obrigatório (lista)"))?;
            if cats.is_empty() {
                return Err(erro("categorias não pode ser vazio"));
            }
            let mut vistas: Vec<&str> = Vec::new();
            for c in cats {
                let nome = c
                    .as_str()
                    .ok_or_else(|| erro("categorias deve conter textos"))?;
                if !CATEGORIAS_LIMPEZA.contains(&nome) {
                    return Err(erro(format!("categoria desconhecida: {nome}")));
                }
                if vistas.contains(&nome) {
                    return Err(erro(format!("categoria repetida: {nome}")));
                }
                vistas.push(nome);
            }
            let mut saida = Map::new();
            saida.insert("categorias".into(), Value::Array(cats.clone()));
            for k in ["confirmado", "avancado", "resetBase"] {
                copiar_bool(&m, &mut saida, k)?;
            }
            let perigosa = vistas
                .iter()
                .any(|c| matches!(*c, "windows_old" | "pontos_antigos"));
            if perigosa && saida.get("confirmado") != Some(&Value::Bool(true)) {
                return Err(erro("confirmado:true é obrigatório para esta categoria"));
            }
            Ok(Value::Object(saida))
        }
        ("quarentena", "listar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["dias"])?;
            let mut saida = Map::new();
            if let Some(d) = m.get("dias") {
                saida.insert("dias".into(), dias(d)?);
            }
            Ok(Value::Object(saida))
        }
        ("quarentena", "restaurar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["ids"])?;
            let mut saida = Map::new();
            saida.insert("ids".into(), ids_quarentena(&m)?);
            Ok(Value::Object(saida))
        }
        ("quarentena", "purgar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["ids", "confirmado"])?;
            exigir_confirmado(&m)?;
            let mut saida = Map::new();
            saida.insert("ids".into(), ids_quarentena(&m)?);
            saida.insert("confirmado".into(), Value::Bool(true));
            Ok(Value::Object(saida))
        }
        ("quarentena", "purgarVencidos") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["dias"])?;
            let d = m.get("dias").ok_or_else(|| erro("dias é obrigatório"))?;
            let mut saida = Map::new();
            saida.insert("dias".into(), dias(d)?);
            Ok(Value::Object(saida))
        }
        ("sistema", "protecaoEstado" | "ligarProtecao" | "sessao") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["simular"])?;
            let mut saida = Map::new();
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("sistema", "criarPonto") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["descricao", "simular"])?;
            let mut saida = Map::new();
            copiar_texto(&m, &mut saida, "descricao", 80)?;
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("programas", "listar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["simular"])?;
            let mut saida = Map::new();
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("programas", "desinstalar") => {
            let m = como_objeto(params)?;
            so_chaves(
                &m,
                &["id", "confirmado", "avancado", "desprovisionar", "simular"],
            )?;
            exigir_confirmado(&m)?;
            let mut saida = Map::new();
            saida.insert("id".into(), Value::String(id_programa(&m)?));
            saida.insert("confirmado".into(), Value::Bool(true));
            for k in ["avancado", "desprovisionar"] {
                copiar_bool(&m, &mut saida, k)?;
            }
            if saida.get("desprovisionar") == Some(&Value::Bool(true))
                && saida.get("avancado") != Some(&Value::Bool(true))
            {
                return Err(erro("desprovisionar exige avancado:true"));
            }
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("programas", "restos") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["id", "nome", "editor", "local", "simular"])?;
            let mut saida = Map::new();
            saida.insert("id".into(), Value::String(id_programa(&m)?));
            saida.insert(
                "nome".into(),
                Value::String(texto_obrigatorio(&m, "nome", MAX_TEXTO)?),
            );
            copiar_texto(&m, &mut saida, "editor", MAX_TEXTO)?;
            if let Some(local) = texto_opcional(&m, "local", MAX_TEXTO)? {
                if !caminho_absoluto(&local) {
                    return Err(erro("local deve ser um caminho absoluto (X:\\...)"));
                }
                saida.insert("local".into(), Value::String(local));
            }
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("programas", "limparRestos") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["itens", "confirmado", "nome"])?;
            exigir_confirmado(&m)?;
            let itens = m
                .get("itens")
                .and_then(Value::as_array)
                .ok_or_else(|| erro("itens é obrigatório (lista)"))?;
            if itens.is_empty() {
                return Err(erro("itens não pode ser vazio"));
            }
            if itens.len() > MAX_ITENS {
                return Err(erro(format!("itens: no máximo {MAX_ITENS} por vez")));
            }
            let itens = itens
                .iter()
                .map(item_resto)
                .collect::<Result<Vec<_>, _>>()?;
            let mut saida = Map::new();
            saida.insert("itens".into(), Value::Array(itens));
            saida.insert("confirmado".into(), Value::Bool(true));
            copiar_texto(&m, &mut saida, "nome", MAX_TEXTO)?;
            Ok(Value::Object(saida))
        }
        ("inicializacao", "listar") | ("ajusteswin", "listar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["avancado", "simular"])?;
            let mut saida = Map::new();
            copiar_bool(&m, &mut saida, "avancado")?;
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("inicializacao", "alternar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["id", "ativar", "confirmado", "avancado", "simular"])?;
            exigir_confirmado(&m)?;
            let id = id_inicio(&m)?;
            let ativar = m
                .get("ativar")
                .and_then(Value::as_bool)
                .ok_or_else(|| erro("ativar é obrigatório (booleano)"))?;
            let tarefa = id.starts_with("tarefa:");
            let mut saida = Map::new();
            saida.insert("id".into(), Value::String(id));
            saida.insert("ativar".into(), Value::Bool(ativar));
            saida.insert("confirmado".into(), Value::Bool(true));
            copiar_bool(&m, &mut saida, "avancado")?;
            // Review Focus 2: tarefa agendada só no modo avançado (o script confere de novo).
            if tarefa && saida.get("avancado") != Some(&Value::Bool(true)) {
                return Err(erro("tarefas agendadas exigem avancado:true"));
            }
            copiar_simular(&m, &mut saida, teste)?;
            Ok(Value::Object(saida))
        }
        ("ajusteswin", "aplicar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["ids", "confirmado", "avancado"])?;
            exigir_confirmado(&m)?;
            let mut saida = Map::new();
            saida.insert(
                "ids".into(),
                lista_de_ids(&m, re_id_ajuste(), MAX_IDS_AJUSTES, "ajuste")?,
            );
            saida.insert("confirmado".into(), Value::Bool(true));
            copiar_bool(&m, &mut saida, "avancado")?;
            Ok(Value::Object(saida))
        }
        ("ajusteswin", "restaurar") => {
            let m = como_objeto(params)?;
            so_chaves(&m, &["ids", "confirmado"])?;
            exigir_confirmado(&m)?;
            let mut saida = Map::new();
            saida.insert(
                "ids".into(),
                lista_de_ids(&m, re_id_ajuste(), MAX_IDS_AJUSTES, "ajuste")?,
            );
            saida.insert("confirmado".into(), Value::Bool(true));
            Ok(Value::Object(saida))
        }
        _ => Err(ErroValidacao::NaoPermitida(format!("{modulo}/{acao}"))),
    }
}

#[cfg(test)]
mod testes {
    use super::*;
    use serde_json::json;

    fn parametro<T: std::fmt::Debug>(r: Result<T, ErroValidacao>) {
        assert!(matches!(r, Err(ErroValidacao::Parametro(_))), "{r:?}");
    }

    #[test]
    fn limpar_valido() {
        let p = json!({"categorias":["temp_usuario","lixeira"]});
        assert_eq!(validar("limpeza", "limpar", &p, false).unwrap(), p);
    }

    #[test]
    fn limpar_categorias_invalidas() {
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":[]}),
            false,
        ));
        parametro(validar("limpeza", "limpar", &json!({}), false));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["temp_usuario","temp_usuario"]}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["registro"]}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":[1]}),
            false,
        ));
    }

    #[test]
    fn limpar_exige_confirmacao_para_categorias_perigosas() {
        for c in ["windows_old", "pontos_antigos"] {
            parametro(validar(
                "limpeza",
                "limpar",
                &json!({"categorias":[c]}),
                false,
            ));
            parametro(validar(
                "limpeza",
                "limpar",
                &json!({"categorias":[c],"confirmado":false}),
                false,
            ));
            assert!(
                validar(
                    "limpeza",
                    "limpar",
                    &json!({"categorias":[c],"confirmado":true}),
                    false
                )
                .is_ok()
            );
        }
    }

    #[test]
    fn limpar_chave_extra_e_booleanos() {
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["lixeira"],"extra":1}),
            false,
        ));
        parametro(validar(
            "limpeza",
            "limpar",
            &json!({"categorias":["lixeira"],"avancado":"s"}),
            false,
        ));
        let p = json!({"categorias":["lixeira"],"resetBase":true,"avancado":true});
        assert_eq!(validar("limpeza", "limpar", &p, false).unwrap(), p);
    }

    #[test]
    fn analisar() {
        let p = json!({"avancado":true});
        assert_eq!(validar("limpeza", "analisar", &p, false).unwrap(), p);
        assert_eq!(
            validar("limpeza", "analisar", &json!(null), false).unwrap(),
            json!({})
        );
        parametro(validar("limpeza", "analisar", &json!({"x":1}), false));
    }

    #[test]
    fn nao_permitida() {
        let r = validar("inicio", "listar", &json!({}), false);
        assert!(matches!(r, Err(ErroValidacao::NaoPermitida(ref s)) if s == "inicio/listar"));
        assert!(matches!(
            validar("programas", "apagar", &json!({}), false),
            Err(ErroValidacao::NaoPermitida(_))
        ));
        assert!(matches!(
            validar("quarentena", "listar_tudo", &json!({}), false),
            Err(ErroValidacao::NaoPermitida(_))
        ));
        assert!(matches!(
            validar("limpeza", "apagar", &json!({}), false),
            Err(ErroValidacao::NaoPermitida(_))
        ));
    }

    #[test]
    fn ping() {
        assert_eq!(
            validar("host", "ping", &json!(null), false).unwrap(),
            json!({})
        );
        assert!(validar("host", "ping", &json!({}), false).is_ok());
        parametro(validar("host", "ping", &json!({"a":1}), false));
    }

    #[test]
    fn coletar_simular_so_em_teste() {
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"simular":{}}),
            false,
        ));
        assert!(validar("diagnostico", "coletar", &json!({"simular":{}}), true).is_ok());
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"simular":1}),
            true,
        ));
    }

    #[test]
    fn coletar_forcar_perfil() {
        let p = json!({"forcarPerfil":{"classe":"gamer","disco":"hdd"}});
        assert_eq!(validar("diagnostico", "coletar", &p, false).unwrap(), p);
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"forcarPerfil":{"classe":"x","disco":"hdd"}}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"forcarPerfil":{"classe":"gamer"}}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"outra":1}),
            false,
        ));
        assert!(validar("diagnostico", "coletar", &json!({}), false).is_ok());
    }

    #[test]
    fn coletar_resetar_perfil() {
        let p = json!({"resetarPerfil": true});
        assert_eq!(validar("diagnostico", "coletar", &p, false).unwrap(), p);
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"resetarPerfil": "true"}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"resetarPerfil": 1}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"resetarPerfil": true, "forcarPerfil": {"classe": "gamer", "disco": "ssd"}}),
            false,
        ));
        parametro(validar(
            "diagnostico",
            "coletar",
            &json!({"resetarPerfil": false, "forcarPerfil": {"classe": "gamer", "disco": "ssd"}}),
            false,
        ));
    }

    #[test]
    fn modulos() {
        assert_eq!(modulos_permitidos().len(), 8);
        for m in [
            "host",
            "diagnostico",
            "limpeza",
            "quarentena",
            "sistema",
            "programas",
            "inicializacao",
            "ajusteswin",
        ] {
            assert!(modulos_permitidos().contains(&m), "{m}");
        }
        assert_eq!(CATEGORIAS_LIMPEZA.len(), 14);
    }

    #[test]
    fn tabela_e_escrita() {
        for (m, a) in [
            ("limpeza", "limpar"),
            ("programas", "desinstalar"),
            ("programas", "limparRestos"),
            ("quarentena", "restaurar"),
            ("quarentena", "purgar"),
            ("quarentena", "purgarVencidos"),
            ("sistema", "criarPonto"),
            ("sistema", "ligarProtecao"),
            ("inicializacao", "alternar"),
            ("ajusteswin", "aplicar"),
            ("ajusteswin", "restaurar"),
        ] {
            assert!(e_escrita(m, a), "{m}/{a} é escrita");
        }
        for (m, a) in [
            ("host", "ping"),
            ("diagnostico", "coletar"),
            ("limpeza", "analisar"),
            ("programas", "listar"),
            ("programas", "restos"),
            ("quarentena", "listar"),
            ("sistema", "protecaoEstado"),
            ("sistema", "sessao"),
            ("inicializacao", "listar"),
            ("ajusteswin", "listar"),
            ("limpeza", "Limpar"),
            ("inexistente", "limpar"),
        ] {
            assert!(!e_escrita(m, a), "{m}/{a} é leitura");
        }
    }

    // ---- quarentena ----

    const ID_Q: &str = "20261120-153045-0a1f";

    #[test]
    fn quarentena_listar() {
        assert_eq!(
            validar("quarentena", "listar", &json!(null), false).unwrap(),
            json!({})
        );
        assert_eq!(
            validar("quarentena", "listar", &json!({}), false).unwrap(),
            json!({})
        );
        let p = json!({"dias": 30});
        assert_eq!(validar("quarentena", "listar", &p, false).unwrap(), p);
        for d in [
            json!(0),
            json!(91),
            json!(-1),
            json!(7.5),
            json!("7"),
            json!(true),
            json!(null),
        ] {
            parametro(validar("quarentena", "listar", &json!({"dias": d}), false));
        }
        parametro(validar("quarentena", "listar", &json!({"ids": []}), false));
    }

    #[test]
    fn quarentena_restaurar() {
        let p = json!({"ids": [ID_Q, "20261119-000000-ffff"]});
        assert_eq!(validar("quarentena", "restaurar", &p, false).unwrap(), p);
        parametro(validar("quarentena", "restaurar", &json!({}), false));
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": []}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": ID_Q}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": [1]}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": [ID_Q, ID_Q]}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": [ID_Q], "confirmado": true}),
            false,
        ));
        for ruim in [
            "20261120-153045-0A1F",
            "20261120-153045-0a1",
            "20261120-153045-0a1ff",
            "2026112-0153045-0a1f",
            "..\\20261120-153045-0a1f",
            "20261120-153045-0a1f\\..",
            "",
            " 20261120-153045-0a1f",
            "20261120-153045-0a1f\n",
        ] {
            parametro(validar(
                "quarentena",
                "restaurar",
                &json!({"ids": [ruim]}),
                false,
            ));
        }
    }

    #[test]
    fn quarentena_restaurar_limite_de_ids() {
        let ids: Vec<String> = (0..MAX_IDS)
            .map(|i| format!("20261120-153045-{i:04x}"))
            .collect();
        assert!(validar("quarentena", "restaurar", &json!({"ids": ids}), false).is_ok());
        let demais: Vec<String> = (0..=MAX_IDS)
            .map(|i| format!("20261120-153045-{i:04x}"))
            .collect();
        parametro(validar(
            "quarentena",
            "restaurar",
            &json!({"ids": demais}),
            false,
        ));
    }

    #[test]
    fn quarentena_purgar_exige_confirmado_estrito() {
        let p = json!({"ids": [ID_Q], "confirmado": true});
        assert_eq!(validar("quarentena", "purgar", &p, false).unwrap(), p);
        parametro(validar(
            "quarentena",
            "purgar",
            &json!({"ids": [ID_Q]}),
            false,
        ));
        for c in [json!(false), json!(1), json!("true"), json!(null)] {
            parametro(validar(
                "quarentena",
                "purgar",
                &json!({"ids": [ID_Q], "confirmado": c}),
                false,
            ));
        }
        parametro(validar(
            "quarentena",
            "purgar",
            &json!({"confirmado": true}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "purgar",
            &json!({"ids": ["x"], "confirmado": true}),
            false,
        ));
        parametro(validar(
            "quarentena",
            "purgar",
            &json!({"ids": [ID_Q], "confirmado": true, "dias": 1}),
            false,
        ));
    }

    #[test]
    fn quarentena_purgar_vencidos() {
        for d in [1, 30, 90] {
            let p = json!({"dias": d});
            assert_eq!(
                validar("quarentena", "purgarVencidos", &p, false).unwrap(),
                p
            );
        }
        parametro(validar("quarentena", "purgarVencidos", &json!({}), false));
        parametro(validar("quarentena", "purgarVencidos", &json!(null), false));
        for d in [json!(0), json!(91), json!(30.0), json!("30"), json!([30])] {
            parametro(validar(
                "quarentena",
                "purgarVencidos",
                &json!({"dias": d}),
                false,
            ));
        }
        parametro(validar(
            "quarentena",
            "purgarVencidos",
            &json!({"dias": 30, "confirmado": true}),
            false,
        ));
    }

    // ---- sistema ----

    #[test]
    fn sistema_acoes_sem_parametros() {
        for a in ["protecaoEstado", "ligarProtecao", "sessao"] {
            assert_eq!(
                validar("sistema", a, &json!(null), false).unwrap(),
                json!({})
            );
            assert_eq!(validar("sistema", a, &json!({}), false).unwrap(), json!({}));
            parametro(validar("sistema", a, &json!({"descricao": "x"}), false));
            parametro(validar("sistema", a, &json!({"x": 1}), false));
        }
    }

    #[test]
    fn sistema_criar_ponto() {
        assert_eq!(
            validar("sistema", "criarPonto", &json!({}), false).unwrap(),
            json!({})
        );
        let p = json!({"descricao": "Antes da limpeza (ação do usuário)"});
        assert_eq!(validar("sistema", "criarPonto", &p, false).unwrap(), p);
        let oitenta = "é".repeat(80);
        assert!(
            validar(
                "sistema",
                "criarPonto",
                &json!({"descricao": oitenta}),
                false
            )
            .is_ok()
        );
        let longa = "a".repeat(81);
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"descricao": longa}),
            false,
        ));
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"descricao": "a\nb"}),
            false,
        ));
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"descricao": "a\u{0}b"}),
            false,
        ));
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"descricao": "a\tb"}),
            false,
        ));
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"descricao": 1}),
            false,
        ));
        parametro(validar(
            "sistema",
            "criarPonto",
            &json!({"outra": "x"}),
            false,
        ));
    }

    #[test]
    fn sistema_simular_so_em_teste() {
        for a in ["protecaoEstado", "criarPonto", "ligarProtecao", "sessao"] {
            let p = json!({"simular": {"falharCriar": true}});
            assert_eq!(validar("sistema", a, &p, true).unwrap(), p);
            parametro(validar("sistema", a, &p, false));
            parametro(validar("sistema", a, &json!({"simular": true}), true));
            parametro(validar("sistema", a, &json!({"simular": "x"}), true));
        }
    }

    // ---- programas ----

    const ID_CL: &str = "cl:hklm64:{A1B2C3D4-0000-1111-2222-333344445555}_is1";
    const ID_ST: &str = "st:Fabricante.App_1.2.3.0_x64__8wekyb3d8bbwe";

    #[test]
    fn programas_listar() {
        assert_eq!(
            validar("programas", "listar", &json!(null), false).unwrap(),
            json!({})
        );
        assert_eq!(
            validar("programas", "listar", &json!({}), false).unwrap(),
            json!({})
        );
        parametro(validar("programas", "listar", &json!({"id": ID_CL}), false));
        let sim = json!({"simular": {"classicos": []}});
        assert_eq!(validar("programas", "listar", &sim, true).unwrap(), sim);
        parametro(validar("programas", "listar", &sim, false));
        parametro(validar(
            "programas",
            "listar",
            &json!({"simular": []}),
            true,
        ));
    }

    #[test]
    fn programas_desinstalar_valido() {
        for id in [
            ID_CL,
            ID_ST,
            "cl:hklm32:Nome Com Espaço",
            "cl:hkcu:x",
            "st:x",
        ] {
            let p = json!({"id": id, "confirmado": true});
            assert_eq!(validar("programas", "desinstalar", &p, false).unwrap(), p);
        }
        let p = json!({"id": ID_ST, "confirmado": true, "avancado": true, "desprovisionar": true});
        assert_eq!(validar("programas", "desinstalar", &p, false).unwrap(), p);
        let p =
            json!({"id": ID_ST, "confirmado": true, "avancado": false, "desprovisionar": false});
        assert_eq!(validar("programas", "desinstalar", &p, false).unwrap(), p);
        let p = json!({"id": ID_CL, "confirmado": true, "avancado": true});
        assert_eq!(validar("programas", "desinstalar", &p, false).unwrap(), p);
    }

    #[test]
    fn programas_desinstalar_exige_confirmado_estrito() {
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": ID_CL}),
            false,
        ));
        for c in [json!(false), json!(1), json!("true"), json!(null)] {
            parametro(validar(
                "programas",
                "desinstalar",
                &json!({"id": ID_CL, "confirmado": c}),
                false,
            ));
        }
        // Mesmo com confirmado:true e avancado:true o Rust só confere a forma do id: quem recusa
        // protegidos é o PowerShell (Review Focus 5) — e nada aqui pode “liberar” um id inválido.
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": "C:\\Windows", "confirmado": true, "avancado": true}),
            false,
        ));
    }

    #[test]
    fn programas_desinstalar_id_invalido() {
        let longo = format!("cl:hkcu:{}", "a".repeat(256));
        let limite = format!("cl:hkcu:{}", "a".repeat(255));
        assert!(
            validar(
                "programas",
                "desinstalar",
                &json!({"id": limite, "confirmado": true}),
                false
            )
            .is_ok()
        );
        for id in [
            "",
            "cl:",
            "cl:hklm64:",
            "cl:hklm:Nome",
            "CL:hklm64:Nome",
            "st:",
            "xx:Nome",
            "Nome",
            "cl:hkcu:a\rb",
            "cl:hkcu:a\nb",
            "cl:hkcu:a\u{0}b",
            "st:a\tb",
            longo.as_str(),
        ] {
            parametro(validar(
                "programas",
                "desinstalar",
                &json!({"id": id, "confirmado": true}),
                false,
            ));
        }
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": 5, "confirmado": true}),
            false,
        ));
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"confirmado": true}),
            false,
        ));
    }

    #[test]
    fn programas_desinstalar_desprovisionar_exige_avancado() {
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": ID_ST, "confirmado": true, "desprovisionar": true}),
            false,
        ));
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": ID_ST, "confirmado": true, "avancado": false, "desprovisionar": true}),
            false,
        ));
        for k in ["avancado", "desprovisionar"] {
            parametro(validar(
                "programas",
                "desinstalar",
                &json!({"id": ID_ST, "confirmado": true, k: "sim"}),
                false,
            ));
        }
        parametro(validar(
            "programas",
            "desinstalar",
            &json!({"id": ID_ST, "confirmado": true, "forcar": true}),
            false,
        ));
        let sim = json!({"id": ID_ST, "confirmado": true, "simular": {"codigo": 0}});
        assert_eq!(
            validar("programas", "desinstalar", &sim, true).unwrap(),
            sim
        );
        parametro(validar("programas", "desinstalar", &sim, false));
    }

    #[test]
    fn programas_restos() {
        let p = json!({"id": ID_CL, "nome": "App"});
        assert_eq!(validar("programas", "restos", &p, false).unwrap(), p);
        let p = json!({
            "id": ID_CL, "nome": "App", "editor": "Editora Ltda.",
            "local": "C:\\Program Files\\Editora\\App"
        });
        assert_eq!(validar("programas", "restos", &p, false).unwrap(), p);
        let sim = json!({"id": ID_CL, "nome": "App", "simular": {}});
        assert_eq!(validar("programas", "restos", &sim, true).unwrap(), sim);
        parametro(validar("programas", "restos", &sim, false));

        parametro(validar(
            "programas",
            "restos",
            &json!({"nome": "App"}),
            false,
        ));
        parametro(validar("programas", "restos", &json!({"id": ID_CL}), false));
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": ID_CL, "nome": ""}),
            false,
        ));
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": ID_CL, "nome": "   "}),
            false,
        ));
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": ID_CL, "nome": 1}),
            false,
        ));
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": "x", "nome": "App"}),
            false,
        ));
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": ID_CL, "nome": "App", "x": 1}),
            false,
        ));
        let longo = "a".repeat(261);
        for k in ["nome", "editor"] {
            parametro(validar(
                "programas",
                "restos",
                &json!({"id": ID_CL, "nome": "App", k: longo}),
                false,
            ));
            parametro(validar(
                "programas",
                "restos",
                &json!({"id": ID_CL, "nome": "App", k: "a\nb"}),
                false,
            ));
        }
        for local in [
            "Editora\\App",
            "\\\\srv\\share",
            "C:/Editora",
            "",
            "C:\\x\ty",
        ] {
            parametro(validar(
                "programas",
                "restos",
                &json!({"id": ID_CL, "nome": "App", "local": local}),
                false,
            ));
        }
        parametro(validar(
            "programas",
            "restos",
            &json!({"id": ID_CL, "nome": "App", "local": format!("C:\\{}", "a".repeat(260))}),
            false,
        ));
    }

    fn limpar_restos(itens: Value) -> Result<Value, ErroValidacao> {
        validar(
            "programas",
            "limparRestos",
            &json!({"itens": itens, "confirmado": true}),
            false,
        )
    }

    #[test]
    fn limpar_restos_valido() {
        let itens = json!([
            {"tipo": "pasta", "caminho": "C:\\Users\\Ana\\AppData\\Local\\Editora\\App"},
            {"tipo": "arquivo", "caminho": "D:\\Jogos\\App\\config.ini"},
            {"tipo": "atalho", "caminho": "C:\\Users\\Ana\\Desktop\\App.lnk"},
            {"tipo": "chave", "caminho": "HKCU\\Software\\Editora\\App"},
            {"tipo": "chave", "caminho": "HKLM\\SOFTWARE\\Editora\\App"},
            {"tipo": "chave", "caminho": "hkcu\\software\\Editora"}
        ]);
        let r = limpar_restos(itens.clone()).unwrap();
        assert_eq!(r, json!({"itens": itens, "confirmado": true}));
        let p = json!({"itens": [{"tipo": "arquivo", "caminho": "D:\\a\\b.txt"}],
            "confirmado": true, "nome": "App"});
        assert_eq!(validar("programas", "limparRestos", &p, false).unwrap(), p);
    }

    #[test]
    fn limpar_restos_exige_confirmado_e_forma() {
        let item = json!([{"tipo": "arquivo", "caminho": "D:\\a\\b.txt"}]);
        parametro(validar(
            "programas",
            "limparRestos",
            &json!({"itens": item}),
            false,
        ));
        for c in [json!(false), json!(1), json!("true")] {
            parametro(validar(
                "programas",
                "limparRestos",
                &json!({"itens": item, "confirmado": c}),
                false,
            ));
        }
        parametro(validar(
            "programas",
            "limparRestos",
            &json!({"confirmado": true}),
            false,
        ));
        parametro(limpar_restos(json!([])));
        parametro(limpar_restos(json!("D:\\a")));
        parametro(limpar_restos(json!(["D:\\a"])));
        parametro(limpar_restos(json!([{"tipo": "arquivo"}])));
        parametro(limpar_restos(json!([{"caminho": "D:\\a"}])));
        parametro(limpar_restos(
            json!([{"tipo": "arquivo", "caminho": "D:\\a", "x": 1}]),
        ));
        parametro(limpar_restos(json!([{"tipo": "exe", "caminho": "D:\\a"}])));
        parametro(limpar_restos(
            json!([{"tipo": "Pasta", "caminho": "D:\\a"}]),
        ));
        parametro(limpar_restos(json!([{"tipo": "arquivo", "caminho": 1}])));
        parametro(limpar_restos(
            json!([{"tipo": "arquivo", "caminho": "D:\\a\nb"}]),
        ));
        parametro(validar(
            "programas",
            "limparRestos",
            &json!({"itens": item, "confirmado": true, "nome": "a\u{7f}b"}),
            false,
        ));
        parametro(validar(
            "programas",
            "limparRestos",
            &json!({"itens": item, "confirmado": true, "id": ID_CL}),
            false,
        ));
    }

    #[test]
    fn limpar_restos_limite_de_itens() {
        let muitos: Vec<Value> = (0..MAX_ITENS)
            .map(|i| json!({"tipo": "arquivo", "caminho": format!("D:\\restos\\{i}.txt")}))
            .collect();
        assert!(limpar_restos(Value::Array(muitos.clone())).is_ok());
        let mut demais = muitos;
        demais.push(json!({"tipo": "arquivo", "caminho": "D:\\restos\\mais.txt"}));
        parametro(limpar_restos(Value::Array(demais)));
    }

    /// Review Focus 7: caminho de resto dentro de pasta protegida é recusado pelo Rust.
    #[test]
    fn limpar_restos_recusa_caminho_protegido() {
        for caminho in [
            "C:\\Program Files\\Common Files\\X",
            "C:\\Program Files (x86)\\Common Files\\X\\y.dll",
            "C:\\Windows",
            "C:\\Windows\\Temp\\x",
            "C:\\Windows\\System32\\drivers\\x.sys",
            "C:\\Program Files",
            "C:\\Program Files\\WindowsApps\\X",
            "C:\\Program Files\\Microsoft\\EdgeWebView\\x",
            "C:\\Program Files\\Editora\\..\\..\\Windows\\x",
            "C:\\",
            "C:",
        ] {
            for tipo in ["pasta", "arquivo", "atalho"] {
                parametro(limpar_restos(json!([{"tipo": tipo, "caminho": caminho}])));
            }
        }
        // Um item ruim derruba a lista inteira (nada é “parcialmente” aceito).
        parametro(limpar_restos(json!([
            {"tipo": "arquivo", "caminho": "D:\\a\\b.txt"},
            {"tipo": "pasta", "caminho": "C:\\Program Files\\Common Files\\X"}
        ])));
    }

    #[test]
    fn limpar_restos_recusa_caminho_relativo_ou_sem_unidade() {
        for caminho in [
            "Editora\\App",
            "\\Editora\\App",
            "\\\\servidor\\share\\x",
            "C:/Editora/App",
            "C:Editora",
            "%LOCALAPPDATA%\\Editora",
            "~\\Editora",
            "",
            "   ",
            "1:\\x",
        ] {
            parametro(limpar_restos(
                json!([{"tipo": "pasta", "caminho": caminho}]),
            ));
        }
    }

    #[test]
    fn limpar_restos_chaves_de_registro() {
        for ok in [
            "HKCU\\Software\\Editora\\App",
            "HKCU\\Software\\Editora",
            "HKLM\\SOFTWARE\\Editora\\App",
            "HKLM\\SOFTWARE\\WOW6432Node\\Editora\\App",
            "hklm\\software\\editora",
            "HKCU\\Software\\Classes\\.ext",
            "HKLM\\SOFTWARE\\Microsoft\\Office",
            "HKCU\\Software\\Editora\\App (x64) é\\Sub",
        ] {
            assert!(
                limpar_restos(json!([{"tipo": "chave", "caminho": ok}])).is_ok(),
                "{ok}"
            );
        }
        for ruim in [
            "HKCU",
            "HKCU\\",
            "HKCU\\Software",
            "HKCU\\Software\\",
            "HKLM\\SOFTWARE",
            "HKLM\\SYSTEM",
            "HKLM\\SYSTEM\\CurrentControlSet\\Services\\X",
            "hklm\\system\\x",
            "HKLM\\SOFTWARE\\Microsoft\\Windows",
            "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run",
            "hklm\\software\\microsoft\\windows\\currentversion\\uninstall\\x",
            "HKLM\\SOFTWARE\\Microsoft\\Windows NT",
            "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon",
            "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run",
            "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
            "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion",
            "HKEY_CURRENT_USER\\Software\\Editora",
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Editora",
            "HKU\\S-1-5-21\\Software\\Editora",
            "HKCR\\.ext",
            "HKCC\\System\\x",
            "HKCU\\\\Software\\Editora",
            "HKCU\\Software\\ \\Editora",
            "HKCU\\Software\\Editora\\App\n",
            "HKCU\\Software\\Edi\u{0}tora",
            "Software\\Editora",
            "C:\\Users\\x",
            "..\\HKCU\\Software\\Editora",
        ] {
            parametro(limpar_restos(json!([{"tipo": "chave", "caminho": ruim}])));
        }
        // Chave com tipo de arquivo (e vice-versa) não passa.
        parametro(limpar_restos(
            json!([{"tipo": "arquivo", "caminho": "HKCU\\Software\\Editora"}]),
        ));
        parametro(limpar_restos(
            json!([{"tipo": "chave", "caminho": "D:\\a\\b.txt"}]),
        ));
    }

    // ---- inicializacao ----

    #[test]
    fn inicializacao_e_ajusteswin_listar() {
        for (m, a) in [("inicializacao", "listar"), ("ajusteswin", "listar")] {
            assert_eq!(validar(m, a, &json!(null), false).unwrap(), json!({}));
            let p = json!({"avancado": true});
            assert_eq!(validar(m, a, &p, false).unwrap(), p);
            parametro(validar(m, a, &json!({"avancado": "s"}), false));
            parametro(validar(m, a, &json!({"x": 1}), false));
            let sim = json!({"simular": {"tarefas": []}});
            assert_eq!(validar(m, a, &sim, true).unwrap(), sim);
            parametro(validar(m, a, &sim, false));
        }
    }

    #[test]
    fn inicializacao_alternar_valido() {
        for id in [
            "run:hkcu:Spotify",
            "run:hklm32:Nome Com Espaço (x64) ção",
            "run:hklm:X",
            "pasta:usuario:App.lnk",
            "pasta:todos:App.lnk",
        ] {
            for ativar in [true, false] {
                let p = json!({"id": id, "ativar": ativar, "confirmado": true});
                assert_eq!(validar("inicializacao", "alternar", &p, false).unwrap(), p);
            }
        }
        let p = json!({"id": "tarefa:\\Positivo\\Updater", "ativar": false, "confirmado": true, "avancado": true});
        assert_eq!(validar("inicializacao", "alternar", &p, false).unwrap(), p);
        let sim = json!({"id": "run:hkcu:X", "ativar": true, "confirmado": true, "simular": {"tarefas": []}});
        assert_eq!(validar("inicializacao", "alternar", &sim, true).unwrap(), sim);
        parametro(validar("inicializacao", "alternar", &sim, false));
    }

    /// Review Focus 2 (lado Rust): tarefa agendada só com `avancado:true`; quem recusa protegidos é o
    /// PowerShell, e nada aqui pode “liberar” um id fora da forma.
    #[test]
    fn inicializacao_alternar_recusa() {
        let alt = |p: Value| validar("inicializacao", "alternar", &p, false);
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": true})));
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": true, "confirmado": "true"})));
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": true, "confirmado": 1})));
        parametro(alt(json!({"id": "run:hkcu:X", "confirmado": true})));
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": 1, "confirmado": true})));
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": "true", "confirmado": true})));
        parametro(alt(json!({"ativar": true, "confirmado": true})));
        parametro(alt(json!({"id": 5, "ativar": true, "confirmado": true})));
        parametro(alt(json!({"id": "run:hkcu:X", "ativar": true, "confirmado": true, "x": 1})));
        let longo = format!("run:hkcu:{}", "a".repeat(256));
        let limite = format!("run:hkcu:{}", "a".repeat(255));
        assert!(alt(json!({"id": limite, "ativar": true, "confirmado": true})).is_ok());
        for id in [
            "",
            "run:hklm:",
            "run:hkey:X",
            "run:hklm64:X",
            "RUN:hkcu:X",
            "pasta:outro:X",
            "pasta:usuario:",
            "tarefa:Sem\\Barra",
            "tarefa:",
            "tarefa:\\",
            "run:hkcu:a\nb",
            "run:hkcu:a\u{0}b",
            "pasta:todos:a\tb",
            "cl:hkcu:X",
            longo.as_str(),
        ] {
            parametro(alt(json!({"id": id, "ativar": true, "confirmado": true})));
        }
        parametro(alt(json!({"id": "tarefa:\\X", "ativar": false, "confirmado": true})));
        parametro(alt(json!({"id": "tarefa:\\X", "ativar": false, "confirmado": true, "avancado": false})));
        assert!(alt(json!({"id": "tarefa:\\X", "ativar": false, "confirmado": true, "avancado": true})).is_ok());
    }

    // ---- ajusteswin ----

    #[test]
    fn ajusteswin_aplicar_e_restaurar() {
        let p = json!({"ids": ["id_publicidade", "efeitos_visuais"], "confirmado": true});
        assert_eq!(validar("ajusteswin", "aplicar", &p, false).unwrap(), p);
        assert_eq!(validar("ajusteswin", "restaurar", &p, false).unwrap(), p);
        let av = json!({"ids": ["historico_atividades"], "confirmado": true, "avancado": true});
        assert_eq!(validar("ajusteswin", "aplicar", &av, false).unwrap(), av);
        parametro(validar("ajusteswin", "restaurar", &av, false));
        let longo41 = "a".repeat(41);
        for a in ["aplicar", "restaurar"] {
            let v = |p: Value| validar("ajusteswin", a, &p, false);
            parametro(v(json!({"ids": ["x"]})));
            parametro(v(json!({"ids": ["x"], "confirmado": "true"})));
            parametro(v(json!({"confirmado": true})));
            parametro(v(json!({"ids": [], "confirmado": true})));
            parametro(v(json!({"ids": "x", "confirmado": true})));
            parametro(v(json!({"ids": [1], "confirmado": true})));
            parametro(v(json!({"ids": ["x", "x"], "confirmado": true})));
            for ruim in ["", "Maiusculo", "com-hifen", "com espaco", "ção", "a\nb", longo41.as_str()] {
                parametro(v(json!({"ids": [ruim], "confirmado": true})));
            }
            let muitos: Vec<String> = (0..MAX_IDS_AJUSTES).map(|i| format!("a{i}")).collect();
            assert!(v(json!({"ids": muitos, "confirmado": true})).is_ok());
            let demais: Vec<String> = (0..=MAX_IDS_AJUSTES).map(|i| format!("a{i}")).collect();
            parametro(v(json!({"ids": demais, "confirmado": true})));
            parametro(validar("ajusteswin", a, &json!({"ids": ["x"], "confirmado": true, "simular": {}}), true));
        }
    }
}
