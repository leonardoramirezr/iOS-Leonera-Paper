#!/usr/bin/env node
// Genera el icono de la app (monograma «P»): el SVG, el PNG 1024×1024 del catálogo de
// recursos y una vista previa con la máscara de iOS.
// Uso: NODE_PATH=$(npm root -g) node design/app-icon/build.cjs
const fs = require('fs');
const path = require('path');

const OUT = __dirname;
const APP_ICON = path.join(OUT, '../../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
const glyphs = require('./glyphs.json');

// ---------- utilidades ----------
const f = (n) => +n.toFixed(1);

function rng(seed) {
  return function () {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Palabras de una línea de texto como segmentos [x, ancho].
function words(x0, x1, r, { minW = 28, maxW = 96, gap = 14 } = {}) {
  const out = [];
  let x = x0;
  while (x < x1 - minW * 0.6) {
    let w = minW + r() * (maxW - minW);
    if (x + w > x1) w = x1 - x;
    if (w < minW * 0.55) break;
    out.push([x, w]);
    x += w + gap;
  }
  return out;
}

function row(x0, x1, y, h, r, fill, opts) {
  return words(x0, x1, r, opts)
    .map(([x, w]) => `<rect x="${f(x)}" y="${f(y - h / 2)}" width="${f(w)}" height="${h}" rx="${h / 2}" fill="${fill}"/>`)
    .join('');
}

function squircle(size = 1024, n = 5, steps = 720) {
  const a = size / 2;
  const pts = [];
  for (let i = 0; i < steps; i++) {
    const th = (i / steps) * Math.PI * 2;
    const c = Math.cos(th), s = Math.sin(th);
    pts.push(`${f(a + a * Math.sign(c) * Math.abs(c) ** (2 / n))},${f(a + a * Math.sign(s) * Math.abs(s) ** (2 / n))}`);
  }
  return `M${pts.join('L')}Z`;
}

// Filtros compartidos: grano de papel, fibras, trazo de marcador y desenfoques.
function commonDefs({ grainColor = '0.35 0.28 0.18', markerStreak = '0.95 0.66 0.05' } = {}) {
  const [gr, gg, gb] = grainColor.split(' ');
  const [mr, mg, mb] = markerStreak.split(' ');
  const R = 'filterUnits="userSpaceOnUse" x="-300" y="-300" width="1624" height="1624"';
  return `
  <filter id="grain" ${R}>
    <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="3" seed="11" stitchTiles="stitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 ${gr}  0 0 0 0 ${gg}  0 0 0 0 ${gb}  1.7 0 0 0 -0.78"/>
  </filter>
  <filter id="fibers" ${R}>
    <feTurbulence type="fractalNoise" baseFrequency="0.012" numOctaves="3" seed="5"/>
    <feColorMatrix type="matrix" values="0 0 0 0 ${gr}  0 0 0 0 ${gg}  0 0 0 0 ${gb}  0.9 0 0 0 -0.38"/>
  </filter>
  <filter id="marker" ${R}>
    <feTurbulence type="fractalNoise" baseFrequency="0.035 0.55" numOctaves="2" seed="3" result="n1"/>
    <feDisplacementMap in="SourceGraphic" in2="n1" scale="9" xChannelSelector="R" yChannelSelector="G" result="d"/>
    <feTurbulence type="fractalNoise" baseFrequency="0.0035 0.11" numOctaves="3" seed="8" result="n2"/>
    <feColorMatrix in="n2" type="matrix" values="0 0 0 0 ${mr}  0 0 0 0 ${mg}  0 0 0 0 ${mb}  1.5 0 0 0 -0.55" result="streak"/>
    <feComposite in="streak" in2="d" operator="in" result="s2"/>
    <feMerge><feMergeNode in="d"/><feMergeNode in="s2"/></feMerge>
  </filter>
  ${[2, 4, 6, 8, 12, 16, 22, 30, 40, 60].map((s) => `<filter id="b${s}" ${R}><feGaussianBlur stdDeviation="${s}"/></filter>`).join('')}
  `;
}

const svgWrap = (defs, body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>${defs}</defs>${body}</svg>`;

// Trazo de marcador fluorescente (rectángulo con bordes irregulares y vetas).
const marker = (x0, x1, y, h, color = '#FFE24D', extra = '') =>
  `<g style="mix-blend-mode:multiply" ${extra}><rect x="${f(x0)}" y="${f(y - h / 2)}" width="${f(x1 - x0)}" height="${h}" rx="${h * 0.22}" fill="${color}" filter="url(#marker)" opacity="0.92"/></g>`;

// =====================================================================
// Monograma — una «P» recortada de una página impresa y resaltada
// =====================================================================
function icon() {
  const r = rng(404);
  const s = 0.47;
  const tx = 512 - 687.5 * s - 6, base = 850;
  const glyph = `<path d="${glyphs.fraunces}" transform="translate(${f(tx)} ${base}) scale(${s} ${-s})"/>`;
  let text = '';
  for (let i = 0; i < 34; i++) text += row(150, 920, 190 + i * 21, 7, r, '#555A63', { minW: 16, maxW: 62, gap: 7 });
  const defs = commonDefs() + `
    <radialGradient id="bg" cx=".5" cy=".28" r=".85"><stop offset="0" stop-color="#3A3D46"/><stop offset=".55" stop-color="#1A1C21"/><stop offset="1" stop-color="#0A0B0D"/></radialGradient>
    <linearGradient id="paper" x1="0" y1="0" x2=".4" y2="1"><stop offset="0" stop-color="#FFFDF6"/><stop offset="1" stop-color="#EDE5D3"/></linearGradient>
    <clipPath id="pClip">${glyph}</clipPath>
  `;
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" filter="url(#grain)" opacity=".18"/>
    <g transform="rotate(-4 512 512)">
      <g fill="#000" opacity=".65" filter="url(#b30)" transform="translate(10 36)">${glyph}</g>
      <g fill="#000" opacity=".5" filter="url(#b4)" transform="translate(2 6)">${glyph}</g>
      <g fill="#B9AE95" transform="translate(0 7)">${glyph}</g>
      <g clip-path="url(#pClip)">
        <rect width="1024" height="1024" fill="url(#paper)"/>
        <rect width="1024" height="1024" filter="url(#grain)" opacity=".35"/>
        <rect width="1024" height="1024" filter="url(#fibers)" opacity=".3"/>
        ${text}
        ${marker(150, 940, 190 + 9.5 * 21, 50)}
      </g>
      <g fill="none" stroke="#fff" stroke-opacity=".75" stroke-width="2" clip-path="url(#pClip)">${glyph}</g>
    </g>
  `;
  return svgWrap(defs, body);
}


async function main() {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const svg = icon();
  fs.writeFileSync(path.join(OUT, 'icon.svg'), svg);
  await page.setContent(`<!doctype html><html><body style="margin:0;background:#fff">${svg}</body></html>`);
  await page.screenshot({ path: APP_ICON });
  // vista previa a 512 px con la máscara de esquinas continuas de iOS
  const masked = svg
    .replace('width="1024" height="1024"', 'width="512" height="512"')
    .replace('<defs>', `<defs><clipPath id="iosMask"><path d="${squircle()}"/></clipPath>`)
    .replace(/<\/defs>([\s\S]*)<\/svg>$/, '</defs><g clip-path="url(#iosMask)">$1</g></svg>');
  await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${masked}</body></html>`);
  await page.screenshot({ path: path.join(OUT, 'preview.png'), omitBackground: true, clip: { x: 0, y: 0, width: 512, height: 512 } });
  await browser.close();
  console.log(`Icono guardado en ${APP_ICON}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
