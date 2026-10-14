// Leonera Paper — extracción de artículos.
//
// Se ejecuta con WKWebView.callAsyncJavaScript como cuerpo de una función, en un
// mundo de contenido aislado, sobre la página ya cargada. Localiza el contenido
// principal (heurística al estilo Readability), lo convierte a Markdown y devuelve
// un JSON con el texto, los metadatos y las URLs de las imágenes. En el Markdown,
// cada imagen se referencia como `leonera-image:<índice>` para que la app la
// sustituya por la ruta local una vez descargada.

const doc = document;
const baseURI = doc.baseURI || window.location.href;

const UNLIKELY = /-ad-|^ad-|\bads?\b|ai2html|banner|breadcrumb|combx|comment|community|cover-wrap|disqus|extra|footer|gdpr|header|legends|menu|related|remark|replies|rss|shoutbox|sidebar|skyscraper|social|sponsor|supplemental|ad-break|agegate|pagination|pager|popup|yom-remote|newsletter|subscribe|share|sharing|promo|cookie|consent|signup|sign-up|modal|outbrain|taboola|recirc|trending|most-popular|paywall|toolbar|masthead/i;
const MAYBE = /and|article|body|column|content|main|shadow|story|post|entry|text|prose/i;
const POSITIVE = /article|body|content|entry|hentry|h-entry|main|page|post|text|blog|story|prose/i;
const NEGATIVE = /-ad-|hidden|^hid$| hid$| hid |^hid |banner|combx|comment|com-|contact|foot|footer|footnote|gdpr|masthead|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags|tool|widget|newsletter|subscribe/i;
const JUNK_TEXT = /^(advertisement|publicidad|anuncio|sponsored|patrocinado|read more|leer más|share|compartir|continue reading|seguir leyendo)$/i;
const BLOCK_SELECTOR = 'address,article,aside,blockquote,dd,div,dl,dt,fieldset,figcaption,figure,footer,form,h1,h2,h3,h4,h5,h6,header,hr,li,main,nav,ol,p,pre,section,table,ul';
const ROLES_TO_REMOVE = ['menu', 'menubar', 'complementary', 'navigation', 'alert', 'alertdialog', 'dialog', 'banner', 'contentinfo'];

const absolute = (value) => {
  if (!value) return null;
  const trimmed = String(value).trim();
  if (!trimmed || /^(javascript|about|mailto|tel):/i.test(trimmed)) return null;
  try { return new URL(trimmed, baseURI).href; } catch (e) { return null; }
};

const meta = (...names) => {
  for (const name of names) {
    const el = doc.querySelector(`meta[property="${name}"], meta[name="${name}"], meta[itemprop="${name}"]`);
    const value = el && el.getAttribute('content');
    if (value && value.trim()) return value.trim();
  }
  return null;
};

const textOf = (el) => (el ? (el.textContent || '').replace(/\s+/g, ' ').trim() : '');
const classAndId = (el) => `${typeof el.className === 'string' ? el.className : ''} ${el.id || ''}`;

const linkDensity = (el) => {
  const length = textOf(el).length;
  if (!length) return 0;
  let links = 0;
  for (const a of el.querySelectorAll('a')) {
    const href = a.getAttribute('href') || '';
    links += textOf(a).length * (href.startsWith('#') ? 0.3 : 1);
  }
  return links / length;
};

const classWeight = (el) => {
  const str = classAndId(el);
  let weight = 0;
  if (NEGATIVE.test(str)) weight -= 25;
  if (POSITIVE.test(str)) weight += 25;
  return weight;
};

// ---------------------------------------------------------------- Metadatos

const jsonLD = (() => {
  const result = {};
  for (const script of doc.querySelectorAll('script[type="application/ld+json"]')) {
    let data;
    try { data = JSON.parse(script.textContent); } catch (e) { continue; }
    const items = [];
    const collect = (node) => {
      if (!node) return;
      if (Array.isArray(node)) { node.forEach(collect); return; }
      if (typeof node !== 'object') return;
      items.push(node);
      if (node['@graph']) collect(node['@graph']);
    };
    collect(data);
    for (const item of items) {
      const type = [].concat(item['@type'] || []).join(' ');
      if (!/Article|BlogPosting|Report|NewsArticle|WebPage/i.test(type)) continue;
      if (!result.title && typeof item.headline === 'string') result.title = item.headline;
      if (!result.published && item.datePublished) result.published = String(item.datePublished);
      if (!result.author && item.author) {
        const names = [].concat(item.author).map((a) => (typeof a === 'string' ? a : a && a.name)).filter(Boolean);
        if (names.length) result.author = names.join(', ');
      }
      if (!result.siteName && item.publisher && item.publisher.name) result.siteName = item.publisher.name;
      if (!result.image && item.image) {
        const image = [].concat(item.image)[0];
        result.image = typeof image === 'string' ? image : image && image.url;
      }
    }
  }
  return result;
})();

const cleanTitle = (title) => {
  if (!title) return '';
  let result = title.replace(/\s+/g, ' ').trim();
  const parts = result.split(/\s[|\-–—·»:]\s/);
  if (parts.length > 1 && parts[0].length >= 15) result = parts[0];
  return result;
};

const title = (() => {
  const h1 = textOf(doc.querySelector('article h1, main h1, h1'));
  const ogTitle = meta('og:title', 'twitter:title');
  if (h1 && h1.length < 300 && [ogTitle, doc.title, jsonLD.title].some((t) => t && t.includes(h1))) return h1;
  const candidates = [ogTitle, jsonLD.title, h1];
  for (const candidate of candidates) if (candidate && candidate.trim()) return cleanTitle(candidate);
  return cleanTitle(doc.title) || window.location.hostname;
})();
const byline = jsonLD.author || meta('author', 'article:author', 'parsely-author', 'sailthru.author')
  || textOf(doc.querySelector('[rel="author"], [itemprop="author"], .byline, .author')) || null;
const siteName = meta('og:site_name', 'application-name') || jsonLD.siteName || window.location.hostname.replace(/^www\./, '');
const published = jsonLD.published || meta('article:published_time', 'datePublished', 'date', 'parsely-pub-date', 'pubdate')
  || (doc.querySelector('time[datetime]') && doc.querySelector('time[datetime]').getAttribute('datetime')) || null;
const leadImage = absolute(meta('og:image', 'og:image:url', 'twitter:image', 'twitter:image:src') || jsonLD.image);
const description = meta('og:description', 'description', 'twitter:description');
const lang = (doc.documentElement.getAttribute('lang') || '').trim() || null;

// ---------------------------------------------------------------- Limpieza

// Marca lo oculto en el DOM real (en la copia ya no hay estilos calculados).
if (doc.body) {
  for (const el of doc.body.getElementsByTagName('*')) {
    if (el.hasAttribute('hidden')) { el.setAttribute('data-lp-hidden', '1'); continue; }
    let style = null;
    try { style = window.getComputedStyle(el); } catch (e) { style = null; }
    if (style && (style.display === 'none' || style.visibility === 'hidden')) {
      if (textOf(el).length < 400 || !el.querySelector('p')) el.setAttribute('data-lp-hidden', '1');
    }
  }
}

const root = doc.body ? doc.body.cloneNode(true) : doc.createElement('div');
for (const el of [...root.querySelectorAll('[data-lp-hidden]')]) el.remove();
if (doc.body) for (const el of doc.body.querySelectorAll('[data-lp-hidden]')) el.removeAttribute('data-lp-hidden');

// Imágenes con carga diferida que solo existen dentro de <noscript>.
for (const noscript of [...root.querySelectorAll('noscript')]) {
  const html = noscript.textContent || noscript.innerHTML || '';
  if (!/<img/i.test(html)) { noscript.remove(); continue; }
  const template = doc.createElement('template');
  template.innerHTML = html;
  const img = template.content.querySelector('img');
  if (!img) { noscript.remove(); continue; }
  const previous = noscript.previousElementSibling;
  if (previous && previous.tagName === 'IMG') previous.remove();
  noscript.replaceWith(img);
}

for (const el of [...root.querySelectorAll('script,style,link,meta,iframe,form,button,input,select,textarea,nav,aside,svg,canvas,object,embed,dialog,template,audio,video,source:not(picture > source)')]) {
  el.remove();
}
for (const role of ROLES_TO_REMOVE) {
  for (const el of [...root.querySelectorAll(`[role="${role}"]`)]) el.remove();
}
for (const el of [...root.querySelectorAll('*')]) {
  if (!root.contains(el)) continue;
  const tag = el.tagName;
  if (tag === 'BODY' || tag === 'ARTICLE' || tag === 'MAIN' || tag === 'A' || tag === 'IMG' || tag === 'PICTURE') continue;
  if (el.closest('table, pre, code')) continue;
  const str = classAndId(el);
  if (UNLIKELY.test(str) && !MAYBE.test(str)) el.remove();
}
for (const sup of [...root.querySelectorAll('sup')]) {
  if (/^\[?(\d{1,3}|[a-z]|citation needed|cita requerida|nota \d+)\]?$/i.test(textOf(sup)) && sup.querySelector('a')) sup.remove();
}
for (const header of [...root.querySelectorAll('header, footer')]) {
  if (root.contains(header) && (header.querySelector('nav') || linkDensity(header) > 0.4)) header.remove();
}

// ---------------------------------------------------------------- Contenido principal

const pickBySelector = () => {
  const selectors = ['[itemprop="articleBody"]', '.article-body', '.article__body', '.articleBody', '.article-content',
    '.post-content', '.entry-content', '.story-body', '.c-entry-content', '.post-body', '#article-body', '.content-body',
    '.article__content', '.post__content', '.markdown-body', '.prose'];
  let best = null;
  let bestLength = 0;
  for (const selector of selectors) {
    for (const el of root.querySelectorAll(selector)) {
      const length = [...el.querySelectorAll('p')].reduce((sum, p) => sum + textOf(p).length, 0);
      if (length > bestLength) { best = el; bestLength = length; }
    }
  }
  if (best && bestLength >= 400) return best;
  const articles = [...root.querySelectorAll('article')];
  if (articles.length) {
    const scored = articles.map((el) => [el, [...el.querySelectorAll('p')].reduce((s, p) => s + textOf(p).length, 0)]);
    scored.sort((a, b) => b[1] - a[1]);
    const total = [...root.querySelectorAll('p')].reduce((s, p) => s + textOf(p).length, 0);
    if (scored[0][1] >= 400 && scored[0][1] >= total * 0.5) return scored[0][0];
  }
  return null;
};

const pickByScore = () => {
  const scores = new Map();
  const initial = (el) => {
    let score = classWeight(el);
    switch (el.tagName) {
      case 'DIV': score += 5; break;
      case 'ARTICLE': case 'MAIN': case 'SECTION': score += 8; break;
      case 'PRE': case 'TD': case 'BLOCKQUOTE': score += 3; break;
      case 'ADDRESS': case 'OL': case 'UL': case 'DL': case 'DD': case 'DT': case 'LI': case 'FORM': score -= 3; break;
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': case 'TH': score -= 5; break;
      default: break;
    }
    return score;
  };
  const units = [...root.querySelectorAll('p, pre, td, blockquote')];
  for (const div of root.querySelectorAll('div')) if (!div.querySelector(BLOCK_SELECTOR)) units.push(div);
  for (const unit of units) {
    const text = textOf(unit);
    if (text.length < 25) continue;
    const contentScore = 1 + (text.split(/[,，、]/).length - 1) + Math.min(Math.floor(text.length / 100), 3);
    let ancestor = unit.parentElement;
    for (let level = 0; ancestor && level < 3; level += 1, ancestor = ancestor.parentElement) {
      if (!scores.has(ancestor)) scores.set(ancestor, initial(ancestor));
      const divider = level === 0 ? 1 : level === 1 ? 2 : level * 3;
      scores.set(ancestor, scores.get(ancestor) + contentScore / divider);
    }
  }
  const ranked = [];
  for (const [el, score] of scores) {
    const final = score * (1 - linkDensity(el));
    scores.set(el, final);
    ranked.push([el, final]);
  }
  ranked.sort((a, b) => b[1] - a[1]);
  if (!ranked.length) return null;
  let [top, topScore] = ranked[0];

  // Si varios de los mejores candidatos comparten un antepasado, el artículo es ese antepasado
  // (p. ej. artículos divididos en <section>).
  const alternatives = ranked.slice(1, 6).filter(([, score]) => score >= topScore * 0.75).map(([el]) => el);
  if (alternatives.length >= 2) {
    for (let ancestor = top.parentElement; ancestor && ancestor !== root.parentElement; ancestor = ancestor.parentElement) {
      const contained = alternatives.filter((el) => ancestor.contains(el)).length;
      if (contained >= 2) {
        top = ancestor;
        topScore = Math.max(topScore, scores.get(ancestor) || 0);
        break;
      }
    }
  }
  while (top.parentElement && top.parentElement !== root && top.parentElement.children.length === 1) {
    top = top.parentElement;
  }

  const parent = top.parentElement;
  if (!parent) return top;
  const container = doc.createElement('div');
  const threshold = Math.max(10, topScore * 0.2);
  for (const sibling of [...parent.children]) {
    let append = sibling === top;
    if (!append) {
      const bonus = sibling.className && sibling.className === top.className ? topScore * 0.2 : 0;
      if (scores.has(sibling) && scores.get(sibling) + bonus >= threshold) {
        append = true;
      } else if (sibling.tagName === 'P') {
        const text = textOf(sibling);
        const density = linkDensity(sibling);
        append = (text.length > 80 && density < 0.25) || (text.length > 0 && density === 0 && /\.( |$)/.test(text));
      } else if (sibling.tagName === 'FIGURE' || sibling.tagName === 'PICTURE') {
        append = true;
      }
    }
    if (append) container.appendChild(sibling);
  }
  return container;
};

let content = pickBySelector() || pickByScore() || root;
if (textOf(content).length < 250 && textOf(root).length > textOf(content).length * 3) content = root;

// Limpieza condicional dentro del contenido elegido.
for (const el of [...content.querySelectorAll('div, section, ul, ol, table, header, footer, figure')].reverse()) {
  if (!content.contains(el) || el === content) continue;
  const text = textOf(el);
  const images = el.getElementsByTagName('img').length;
  if (JUNK_TEXT.test(text) && !images) { el.remove(); continue; }
  if (el.tagName === 'FIGURE' || el.closest('pre, code')) continue;
  const density = linkDensity(el);
  const weight = classWeight(el);
  if (density > 0.5 && text.length < 2000 && !(el.tagName === 'TABLE')) { el.remove(); continue; }
  if (weight < 0 && text.length < 600 && !images && !el.querySelector('pre, blockquote, table')) { el.remove(); continue; }
}

// ---------------------------------------------------------------- Markdown

const images = [];
const imageIndex = new Map();
const addImage = (url) => {
  if (!imageIndex.has(url)) { imageIndex.set(url, images.length); images.push(url); }
  return imageIndex.get(url);
};

const escapeText = (text) => text
  .replace(/[\\`*_[\]<]/g, '\\$&')
  .replace(/==/g, '=\\=')
  .replace(/~~/g, '~\\~');

const escapeURL = (url) => url.replace(/ /g, '%20').replace(/\(/g, '%28').replace(/\)/g, '%29');

const wrap = (marker, value) => {
  const match = value.match(/^(\s*)([\s\S]*?)(\s*)$/);
  if (!match || !match[2]) return value;
  return `${match[1]}${marker}${match[2]}${marker}${match[3]}`;
};

const escapeLineStart = (line) => {
  if (/^(#{1,6}(\s|$)|>|[-+](\s|$)|-{3,}|\||`{3,}|~{3,})/.test(line)) return `\\${line}`;
  if (/^\d+[.)](\s|$)/.test(line)) return line.replace(/^(\d+)([.)])/, '$1\\$2');
  return line;
};

const finishParagraph = (buffer) => buffer
  .replace(/[ \t\r\n\f\v]+/g, ' ')
  .split('\u2028')
  .map((segment) => segment.trim())
  .filter((segment, index, all) => segment || (index > 0 && index < all.length - 1))
  .join('\\\n')
  .replace(/^(\\\n)+|(\\\n)+$/g, '')
  .split('\n')
  .map(escapeLineStart)
  .join('\n')
  .trim();

class Writer {
  constructor(context = {}) {
    this.blocks = [];
    this.buffer = '';
    this.context = context;
  }

  flush() {
    // Dos <br> seguidos separan párrafos.
    for (const part of this.buffer.split(/\u2028[ \t]*(?:\u2028[ \t]*)+/)) {
      const paragraph = finishParagraph(part);
      if (paragraph && !JUNK_TEXT.test(paragraph)) this.blocks.push(paragraph);
    }
    this.buffer = '';
  }

  block(value) {
    this.flush();
    if (value && value.trim()) this.blocks.push(value);
  }

  child(extraContext = {}) {
    return new Writer({ ...this.context, ...extraContext });
  }

  result() {
    this.flush();
    return this.blocks;
  }
}

const bestImageURL = (img) => {
  const sized = [];
  const plain = [];
  const parseSrcset = (value) => {
    for (const part of value.split(/,\s+(?=\S)/)) {
      const [url, descriptor] = part.trim().split(/\s+/);
      const resolved = absolute(url);
      if (!resolved || resolved.startsWith('data:')) continue;
      let width = 0;
      if (descriptor && /w$/.test(descriptor)) width = parseInt(descriptor, 10) || 0;
      else if (descriptor && /x$/.test(descriptor)) width = (parseFloat(descriptor) || 1) * 800;
      if (width) sized.push([resolved, width]); else plain.push(resolved);
    }
  };
  for (const attr of ['srcset', 'data-srcset', 'data-lazy-srcset']) {
    const value = img.getAttribute(attr);
    if (value) parseSrcset(value);
  }
  const picture = img.parentElement && img.parentElement.tagName === 'PICTURE' ? img.parentElement : null;
  if (picture) {
    for (const source of picture.querySelectorAll('source')) {
      const type = source.getAttribute('type') || '';
      const value = source.getAttribute('srcset') || source.getAttribute('data-srcset');
      if (value && !/svg/i.test(type)) parseSrcset(value);
    }
  }
  if (sized.length) {
    sized.sort((a, b) => a[1] - b[1]);
    const good = sized.find(([, width]) => width >= 1000);
    return (good || sized[sized.length - 1])[0];
  }
  for (const attr of ['data-src', 'data-lazy-src', 'data-original', 'data-url', 'data-hi-res-src', 'data-full-src', 'data-lazy', 'src']) {
    const value = img.getAttribute(attr);
    if (!value) continue;
    if (value.startsWith('data:')) {
      if (value.length > 2000 && !/^data:image\/svg/i.test(value)) return value;
      continue;
    }
    const resolved = absolute(value);
    if (resolved) return resolved;
  }
  return plain[0] || null;
};

const imageMarkdown = (img) => {
  const str = classAndId(img);
  const alt = (img.getAttribute('alt') || '').replace(/\s+/g, ' ').trim();
  const width = parseInt(img.getAttribute('width') || '0', 10);
  const height = parseInt(img.getAttribute('height') || '0', 10);
  if (/emoji/i.test(str)) return { inline: escapeText(alt) };
  if ((width && width <= 2) || (height && height <= 2)) return null;
  if (/avatar|author-image|logo|icon|sprite|badge/i.test(str)) return null;
  const url = bestImageURL(img);
  if (!url || /(pixel|spacer|blank|transparent|tracking|1x1)\.(gif|png)/i.test(url)) return null;
  return { block: `![${escapeText(alt)}](leonera-image:${addImage(url)})` };
};

const inlineWrap = (el, marker, key, writer) => {
  if (writer.context[key]) { walk(el, writer); return; }
  const inner = writer.child({ [key]: true });
  walk(el, inner);
  if (inner.blocks.length) {
    writer.flush();
    writer.blocks.push(...inner.result());
  } else {
    writer.buffer += wrap(marker, inner.buffer);
  }
};

const codeSpan = (el) => {
  const text = (el.textContent || '').replace(/\n/g, ' ');
  if (!text.trim()) return '';
  const longest = Math.max(0, ...(text.match(/`+/g) || []).map((run) => run.length));
  const fence = '`'.repeat(longest + 1);
  const pad = text.startsWith('`') || text.endsWith('`') ? ' ' : '';
  return `${fence}${pad}${text}${pad}${fence}`;
};

const codeBlock = (pre) => {
  const clone = pre.cloneNode(true);
  for (const br of [...clone.querySelectorAll('br')]) br.replaceWith('\n');
  for (const line of [...clone.querySelectorAll('div, p')]) line.append('\n');
  const text = (clone.textContent || '').replace(/\n+$/, '').replace(/^\n+/, '');
  if (!text.trim()) return '';
  const code = pre.querySelector('code') || pre;
  const languageMatch = `${code.className || ''} ${pre.className || ''}`.match(/(?:lang|language)-([\w+#-]+)/);
  const longest = Math.max(2, ...(text.match(/`+/g) || []).map((run) => run.length));
  const fence = '`'.repeat(longest + 1);
  return `${fence}${languageMatch ? languageMatch[1] : ''}\n${text}\n${fence}`;
};

const isListBlock = (block) => /^(- |\d+\. )/.test(block);

const list = (el, writer) => {
  const ordered = el.tagName === 'OL';
  let number = parseInt(el.getAttribute('start') || '1', 10) || 1;
  const lines = [];
  for (const item of el.children) {
    if (item.tagName !== 'LI') continue;
    const inner = writer.child();
    walk(item, inner);
    const blocks = inner.result();
    const marker = ordered ? `${number}. ` : '- ';
    number += 1;
    if (!blocks.length) continue;
    const indent = ' '.repeat(marker.length);
    let text = marker + blocks[0].replace(/\n/g, `\n${indent}`);
    for (const block of blocks.slice(1)) {
      const indented = indent + block.replace(/\n/g, `\n${indent}`);
      text += isListBlock(block) ? `\n${indented}` : `\n\n${indented}`;
    }
    lines.push(text);
  }
  return lines.join('\n');
};

const table = (el, writer) => {
  const rows = [...el.rows || []];
  const columns = Math.max(0, ...rows.map((row) => row.cells.length));
  if (!rows.length) return;
  if (columns <= 1 || el.querySelector('table, pre, ul, ol, img') || textOf(el).length > 6000) {
    walkChildren(el, writer);
    return;
  }
  const cell = (c) => {
    const inner = writer.child();
    walk(c, inner);
    return inner.result().join(' ').replace(/\\\n/g, ' ').replace(/\n+/g, ' ').replace(/\|/g, '\\|').trim();
  };
  const lines = rows.map((row) => `| ${[...row.cells].map(cell).join(' | ')} |`);
  lines.splice(1, 0, `|${' --- |'.repeat(columns)}`);
  writer.block(lines.join('\n'));
};

const figure = (el, writer) => {
  const imgs = [...el.querySelectorAll('img')];
  if (!imgs.length) {
    const clone = el.cloneNode(true);
    for (const caption of [...clone.querySelectorAll('figcaption')]) caption.remove();
    walkChildren(clone, writer);
  }
  for (const img of imgs) {
    const md = imageMarkdown(img);
    if (md && md.block) writer.block(md.block);
  }
  const caption = el.querySelector('figcaption');
  if (caption) {
    const inner = writer.child({ italic: true });
    walk(caption, inner);
    const text = inner.result().join(' ').replace(/\\\n/g, ' ').trim();
    if (text) writer.block(`*${text}*`);
  }
};

const heading = (el, writer) => {
  const inner = writer.child({ heading: true });
  walk(el, inner);
  const blocks = inner.result();
  const text = blocks.filter((b) => !b.startsWith('![')).join(' ').replace(/\\\n/g, ' ').trim();
  const level = Math.min(Math.max(parseInt(el.tagName.slice(1), 10), 2), 4);
  if (text) writer.block(`${'#'.repeat(level)} ${text.replace(/^\\(?=#)/, '')}`);
  for (const block of blocks.filter((b) => b.startsWith('!['))) writer.block(block);
};

const walkChildren = (el, writer) => {
  writer.flush();
  walk(el, writer);
  writer.flush();
};

function walk(node, writer) {
  for (const child of node.childNodes) {
    if (child.nodeType === 3) {
      writer.buffer += escapeText((child.nodeValue || '').replace(/[\s\u00a0]+/g, ' '));
      continue;
    }
    if (child.nodeType !== 1) continue;
    const tag = child.tagName;
    switch (tag) {
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
        heading(child, writer); break;
      case 'BR':
        writer.buffer += '\u2028'; break;
      case 'HR':
        writer.block('---'); break;
      case 'PRE':
        writer.block(codeBlock(child)); break;
      case 'BLOCKQUOTE': {
        const inner = writer.child();
        walk(child, inner);
        const quoted = inner.result().map((block) => block.split('\n').map((line) => (line ? `> ${line}` : '>')).join('\n'));
        writer.block(quoted.join('\n>\n'));
        break;
      }
      case 'UL': case 'OL':
        writer.block(list(child, writer)); break;
      case 'TABLE':
        table(child, writer); break;
      case 'FIGURE':
        figure(child, writer); break;
      case 'IMG': {
        const md = imageMarkdown(child);
        if (md && md.block) writer.block(md.block);
        else if (md && md.inline) writer.buffer += md.inline;
        break;
      }
      case 'PICTURE': {
        const img = child.querySelector('img');
        const md = img && imageMarkdown(img);
        if (md && md.block) writer.block(md.block);
        break;
      }
      case 'STRONG': case 'B':
        inlineWrap(child, '**', 'bold', writer); break;
      case 'EM': case 'I': case 'CITE': case 'DFN': case 'VAR':
        inlineWrap(child, '*', 'italic', writer); break;
      case 'MARK':
        inlineWrap(child, '==', 'highlight', writer); break;
      case 'DEL': case 'S': case 'STRIKE':
        inlineWrap(child, '~~', 'strike', writer); break;
      case 'CODE': case 'KBD': case 'SAMP': case 'TT':
        writer.buffer += codeSpan(child); break;
      case 'Q':
        writer.buffer += '“'; walk(child, writer); writer.buffer += '”'; break;
      case 'A': {
        const href = absolute(child.getAttribute('href'));
        const inner = writer.child({ link: true });
        walk(child, inner);
        if (inner.blocks.length) {
          writer.flush();
          writer.blocks.push(...inner.result());
        } else if (!href || writer.context.link || /^#/.test(child.getAttribute('href') || '')
                   || href.split('#')[0] === baseURI.split('#')[0]) {
          writer.buffer += inner.buffer;
        } else if (inner.buffer.trim()) {
          const match = inner.buffer.match(/^(\s*)([\s\S]*?)(\s*)$/);
          writer.buffer += `${match[1]}[${match[2]}](${escapeURL(href)})${match[3]}`;
        }
        break;
      }
      case 'P': case 'DIV': case 'SECTION': case 'ARTICLE': case 'MAIN': case 'HEADER': case 'FOOTER':
      case 'ADDRESS': case 'DETAILS': case 'SUMMARY': case 'DL': case 'DT': case 'DD': case 'CENTER':
      case 'FIGCAPTION': case 'HGROUP': case 'LI': case 'TBODY': case 'THEAD': case 'TFOOT': case 'TR':
      case 'TD': case 'TH': case 'CAPTION': case 'FIELDSET':
        walkChildren(child, writer); break;
      case 'SUP': case 'SUB': case 'SPAN': case 'FONT': case 'ABBR': case 'TIME': case 'SMALL': case 'U':
      case 'INS': case 'LABEL': case 'BDI': case 'BDO': case 'DATA': case 'RUBY': case 'NOBR':
        walk(child, writer); break;
      default:
        if (child.querySelector && child.querySelector(BLOCK_SELECTOR)) walkChildren(child, writer);
        else walk(child, writer);
    }
  }
}

const writer = new Writer();
walk(content, writer);
let blocks = writer.result();

// Quita el título repetido y los encabezados vacíos.
const normalized = (value) => value.replace(/\\(.)/g, '$1').replace(/[*_=~`#]/g, '').replace(/\s+/g, ' ').trim().toLowerCase();
const normalizedTitle = normalized(title);
blocks = blocks.filter((block, index) => !(index < 6 && /^#{1,6} /.test(block) && normalized(block) === normalizedTitle));

if (!images.length && leadImage) {
  blocks.unshift(`![](leonera-image:${addImage(leadImage)})`);
}

const markdown = blocks.join('\n\n').replace(/\n{3,}/g, '\n\n').trim();
const plain = (value) => value
  .replace(/!\[[^\]]*\]\([^)]*\)/g, '')
  .replace(/\[((?:\\.|[^\]\\])*)\]\([^)]*\)/g, '$1')
  .replace(/\\\n/g, ' ')
  .replace(/\\(.)/g, '$1')
  .replace(/(\*\*|==|~~|[*`])/g, '')
  .replace(/\s+/g, ' ')
  .trim();
const firstParagraph = blocks.find((block) => !/^(#|!\[|>|- |\d+\. |\||```)/.test(block) && block.length > 60) || '';
const excerpt = (description || plain(firstParagraph)).slice(0, 280);

return JSON.stringify({
  title,
  byline: byline && byline.length < 200 ? byline : null,
  siteName,
  published,
  excerpt,
  lang,
  leadImage,
  url: window.location.href,
  markdown,
  images,
});
