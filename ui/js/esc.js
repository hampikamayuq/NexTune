'use strict';

// Escapa texto para HTML. Tudo que vem do motor e entra em innerHTML passa por aqui.
const ESC_TABELA = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;', '`': '&#96;' };
function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"'`]/g, (c) => ESC_TABELA[c]);
}

// Construtor de nós do DOM. Filhos que são texto viram nós de texto (nunca HTML).
// Atributos: class, text, on<evento> (função), vars (propriedades CSS), demais viram atributos.
function h(tag, attrs, ...filhos) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'vars') for (const [n, x] of Object.entries(v)) el.style.setProperty(n, x);
      else if (k.startsWith('on') && typeof v === 'function') el.addEventListener(k.slice(2), v);
      else if (v === true) el.setAttribute(k, '');
      else el.setAttribute(k, v);
    }
  }
  for (const f of filhos.flat()) {
    if (f == null || f === false) continue;
    el.append(typeof f === 'object' ? f : document.createTextNode(String(f)));
  }
  return el;
}
