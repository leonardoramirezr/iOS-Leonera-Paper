#!/usr/bin/env node
// Genera las 8 opciones de icono (SVG + PNG 1024×1024) y sus vistas con la máscara de iOS.
// Uso: NODE_PATH=$(npm root -g) node design/icon-options/build.cjs
const fs = require('fs');
const path = require('path');

const OUT = __dirname;
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

function bez(t, a, b, c, d) {
  const u = 1 - t;
  return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
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
// 1 · Marcador — hoja sobre azul tinta y un rotulador recién usado
// =====================================================================
function icon1() {
  const r = rng(101);
  const P = { x: 214, y: 148, w: 560, h: 728, rx: 30 };
  const L = P.x + 64, R = P.x + P.w - 64;
  let text = '';
  text += row(L, L + 340, 238, 32, r, '#1D222A', { minW: 100, maxW: 170, gap: 18 });
  text += row(L, L + 230, 286, 32, r, '#1D222A', { minW: 90, maxW: 140, gap: 18 });
  text += row(L, L + 190, 340, 14, r, '#9BA1AA', { minW: 40, maxW: 70, gap: 12 });
  const ys = Array.from({ length: 8 }, (_, i) => 404 + i * 54);
  ys.forEach((y, i) => {
    const end = i === ys.length - 1 ? L + (R - L) * 0.48 : R;
    text += row(L, end, y, 16, r, '#3A4049', { minW: 28, maxW: 92, gap: 14 });
  });
  const hy = ys[3];
  const tipX = L + (R - L) * 0.80;

  const pen = `
    <path d="M2,-13 L40,-22 L40,22 L9,13 Q-1,0 2,-13Z" fill="url(#p1tip)"/>
    <path d="M2,-13 L40,-22 L40,-12 L6,-5Z" fill="#fff" opacity=".35"/>
    <path d="M38,-27 L96,-44 L96,44 L38,27Z" fill="url(#p1nose)"/>
    <path d="M92,-50 H318 A50,50 0 0 1 318,50 H92Z" fill="url(#p1body)"/>
    <rect x="92" y="-51" width="20" height="102" fill="url(#p1band)"/>
    <rect x="126" y="-50" width="150" height="100" fill="url(#p1label)" opacity=".9"/>
    <rect x="146" y="-14" width="100" height="9" rx="4.5" fill="#1D222A" opacity=".55"/>
    <rect x="146" y="4" width="64" height="7" rx="3.5" fill="#1D222A" opacity=".35"/>
    <rect x="276" y="-50" width="8" height="100" fill="#C08B00" opacity=".55"/>
    <rect x="300" y="-50" width="5" height="100" fill="#B98600" opacity=".45"/>
    <rect x="112" y="-41" width="236" height="11" rx="5.5" fill="#fff" opacity=".55" filter="url(#b2)"/>
    <rect x="112" y="33" width="226" height="5" rx="2.5" fill="#FFF6C8" opacity=".35"/>`;
  const penSil = `<path d="M2,-13 L40,-22 L96,-44 L92,-50 H318 A50,50 0 0 1 318,50 H92 L96,44 L40,22 L9,13Z"/>`;

  const defs = commonDefs() + `
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#36507A"/><stop offset=".55" stop-color="#1C2A44"/><stop offset="1" stop-color="#0E1628"/></linearGradient>
    <radialGradient id="bgGlow" cx=".42" cy="-.05" r=".85"><stop offset="0" stop-color="#8FB0F0" stop-opacity=".55"/><stop offset="1" stop-color="#8FB0F0" stop-opacity="0"/></radialGradient>
    <linearGradient id="paper" x1="0" y1="0" x2=".25" y2="1"><stop offset="0" stop-color="#FFFEFA"/><stop offset="1" stop-color="#EFE9DC"/></linearGradient>
    <radialGradient id="sheen" cx=".15" cy=".05" r=".9"><stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <clipPath id="pageClip"><rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" rx="${P.rx}"/></clipPath>
    <linearGradient id="p1tip" x1="0" y1="-1" x2="0" y2="1" gradientUnits="objectBoundingBox"><stop offset="0" stop-color="#FFE45A"/><stop offset=".6" stop-color="#F5C000"/><stop offset="1" stop-color="#D99A00"/></linearGradient>
    <linearGradient id="p1nose" x1="0" y1="-44" x2="0" y2="44" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#A7AEB8"/><stop offset=".3" stop-color="#717883"/><stop offset=".75" stop-color="#2F333A"/><stop offset="1" stop-color="#5A616C"/></linearGradient>
    <linearGradient id="p1body" x1="0" y1="-50" x2="0" y2="50" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFF4A6"/><stop offset=".22" stop-color="#FFE34B"/><stop offset=".55" stop-color="#FFCF00"/><stop offset=".85" stop-color="#E2A800"/><stop offset="1" stop-color="#B98400"/></linearGradient>
    <linearGradient id="p1band" x1="0" y1="-50" x2="0" y2="50" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#F2CE3A"/><stop offset=".5" stop-color="#C99A00"/><stop offset="1" stop-color="#8C6400"/></linearGradient>
    <linearGradient id="p1label" x1="0" y1="-50" x2="0" y2="50" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFFFFF"/><stop offset=".55" stop-color="#F2F0EA"/><stop offset="1" stop-color="#BDB7A6"/></linearGradient>
  `;
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#bgGlow)"/>
    <g transform="rotate(-5 512 512)">
      <rect x="${P.x + 18}" y="${P.y + 40}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#040812" opacity=".55" filter="url(#b30)"/>
      <rect x="${P.x + 3}" y="${P.y + 7}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#040812" opacity=".45" filter="url(#b6)"/>
      <rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="url(#paper)"/>
      <g clip-path="url(#pageClip)">
        <rect width="1024" height="1024" filter="url(#grain)" opacity=".35"/>
        <rect width="1024" height="1024" filter="url(#fibers)" opacity=".25"/>
        <rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" fill="url(#sheen)" opacity=".5"/>
        ${text}
        ${marker(L - 14, tipX + 6, hy, 44)}
        <g transform="translate(${f(tipX + 20)} ${hy + 34}) rotate(36)" fill="#2A1E00" opacity=".38" filter="url(#b12)">${penSil}</g>
      </g>
      <rect x="${P.x + 0.75}" y="${P.y + 0.75}" width="${P.w - 1.5}" height="${P.h - 1.5}" rx="${P.rx}" fill="none" stroke="#fff" stroke-opacity=".8" stroke-width="1.5"/>
      <g transform="translate(${f(tipX + 34)} ${hy + 54}) rotate(36)" fill="#020510" opacity=".45" filter="url(#b16)">${penSil}</g>
      <g transform="translate(${f(tipX)} ${hy}) rotate(36)">${pen}</g>
    </g>`;
  return svgWrap(defs, body);
}

// =====================================================================
// 2 · Libro — libro abierto con páginas curvas, cinta y una línea resaltada
// =====================================================================
function icon2() {
  const r = rng(202);
  const top = [[150, 262], [270, 224], [430, 228], [512, 302]];
  const bot = [[150, 784], [270, 752], [430, 756], [512, 806]];
  const at = (curve, u) => [bez(u, curve[0][0], curve[1][0], curve[2][0], curve[3][0]), bez(u, curve[0][1], curve[1][1], curve[2][1], curve[3][1])];
  const map = (u, v, mirror) => {
    const a = at(top, u), b = at(bot, u);
    const x = a[0] + (b[0] - a[0]) * v, y = a[1] + (b[1] - a[1]) * v;
    return mirror ? [1024 - x, y] : [x, y];
  };
  const pagePath = (mirror) => {
    const m = (p) => (mirror ? [1024 - p[0], p[1]] : p);
    const T = top.map(m), B = bot.map(m);
    return `M${T[0]} C${T[1]} ${T[2]} ${T[3]} L${B[3]} C${B[2]} ${B[1]} ${B[0]} Z`;
  };
  const curvedRow = (v, u0, u1, sw, color, mirror, opts) => {
    // las palabras se generan en «unidades» de 0–1000 y se mapean a la página curva
    return words(u0 * 1000, u1 * 1000, r, opts)
      .map(([x, w]) => {
        const a = (x + sw * 0.9) / 1000, b = (x + w - sw * 0.9) / 1000;
        if (b <= a) return '';
        const pts = Array.from({ length: 7 }, (_, i) => map(a + ((b - a) * i) / 6, v, mirror).map(f).join(','));
        return `<polyline points="${pts.join(' ')}" fill="none" stroke="${color}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round"/>`;
      })
      .join('');
  };
  const ink = '#3B3A36';
  let leftText = '', rightText = '';
  leftText += curvedRow(0.13, 0.14, 0.62, 26, '#23221F', false, { minW: 120, maxW: 200, gap: 40 });
  const vs = Array.from({ length: 11 }, (_, i) => 0.24 + i * 0.064);
  vs.forEach((v, i) => {
    const end = i === vs.length - 1 ? 0.5 : 0.86;
    leftText += curvedRow(v, 0.14, end, 13, ink, false, { minW: 40, maxW: 120, gap: 28 });
  });
  const rv = Array.from({ length: 13 }, (_, i) => 0.12 + i * 0.064);
  rv.forEach((v, i) => {
    const start = i === 4 ? 0.3 : 0.14;
    rightText += curvedRow(v, start, 0.86, 13, ink, true, { minW: 40, maxW: 120, gap: 28 });
  });
  // resaltado sobre la línea 6 de la página derecha
  const hv = rv[6];
  const hpts = Array.from({ length: 12 }, (_, i) => map(0.2 + (0.66 * i) / 11, hv, true).map(f).join(','));
  const highlight = `<g style="mix-blend-mode:multiply"><polyline points="${hpts.join(' ')}" fill="none" stroke="#FFE04A" stroke-width="40" stroke-linecap="butt" filter="url(#marker)" opacity=".92"/></g>`;

  const edges = (mirror) => {
    const out = [];
    for (let k = 4; k >= 1; k--) {
      const dx = (mirror ? 1 : -1) * k * 2.2, dy = k * 4.5;
      out.push(`<path d="${pagePath(mirror)}" transform="translate(${dx} ${dy})" fill="${k % 2 ? '#E6DCC6' : '#EFE7D4'}" stroke="#CDBF9F" stroke-width="1"/>`);
    }
    return out.join('');
  };

  const defs = commonDefs() + `
    <linearGradient id="bg" x1="0" y1="0" x2=".3" y2="1"><stop offset="0" stop-color="#3C8268"/><stop offset=".6" stop-color="#1D4E3E"/><stop offset="1" stop-color="#0F2F25"/></linearGradient>
    <radialGradient id="bgGlow" cx=".5" cy=".05" r=".8"><stop offset="0" stop-color="#B9F0D4" stop-opacity=".38"/><stop offset="1" stop-color="#B9F0D4" stop-opacity="0"/></radialGradient>
    <linearGradient id="cover" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8A5530"/><stop offset="1" stop-color="#4B2914"/></linearGradient>
    <linearGradient id="gutL" x1="150" y1="0" x2="512" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#6B4A1E" stop-opacity=".10"/><stop offset=".1" stop-color="#6B4A1E" stop-opacity="0"/><stop offset=".72" stop-color="#6B4A1E" stop-opacity="0"/><stop offset=".9" stop-color="#6B4A1E" stop-opacity=".14"/><stop offset="1" stop-color="#3E2A0C" stop-opacity=".45"/></linearGradient>
    <linearGradient id="gutR" x1="874" y1="0" x2="512" y2="0" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#6B4A1E" stop-opacity=".08"/><stop offset=".1" stop-color="#6B4A1E" stop-opacity="0"/><stop offset=".72" stop-color="#6B4A1E" stop-opacity="0"/><stop offset=".9" stop-color="#6B4A1E" stop-opacity=".12"/><stop offset="1" stop-color="#3E2A0C" stop-opacity=".40"/></linearGradient>
    <linearGradient id="ribbon" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#9E1F17"/><stop offset=".35" stop-color="#E14A3B"/><stop offset=".6" stop-color="#D23B2D"/><stop offset="1" stop-color="#8E1810"/></linearGradient>
    <clipPath id="pagesClip"><path d="${pagePath(false)}"/><path d="${pagePath(true)}"/></clipPath>
  `;
  const ribbon = 'M508,300 L538,302 C546,500 556,700 566,814 L575,936 L560,918 L545,940 L536,816 C526,700 516,500 508,300Z';
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#bgGlow)"/>
    <rect x="120" y="262" width="784" height="590" rx="28" fill="#03140E" opacity=".55" filter="url(#b30)" transform="translate(0 30)"/>
    <rect x="116" y="246" width="792" height="594" rx="26" fill="url(#cover)"/>
    <rect x="116" y="246" width="792" height="594" rx="26" fill="none" stroke="#B07A4C" stroke-opacity=".45" stroke-width="2"/>
    <rect x="116" y="246" width="792" height="594" rx="26" filter="url(#grain)" opacity=".25" clip-path="inset(0 round 26px)"/>
    <rect x="505" y="246" width="14" height="594" fill="#2E170A" opacity=".55"/>
    ${edges(false)}${edges(true)}
    <path d="${pagePath(false)}" fill="#FBF6EA"/>
    <path d="${pagePath(true)}" fill="#FCF8EE"/>
    <g clip-path="url(#pagesClip)">
      <rect width="1024" height="1024" filter="url(#grain)" opacity=".3"/>
      <rect width="1024" height="1024" filter="url(#fibers)" opacity=".2"/>
      ${leftText}${rightText}
      ${highlight}
      <path d="${pagePath(false)}" fill="url(#gutL)"/>
      <path d="${pagePath(true)}" fill="url(#gutR)"/>
      <path d="${ribbon}" fill="#2B1300" opacity=".35" filter="url(#b4)" transform="translate(7 3)"/>
    </g>
    <path d="M566,814 L575,936 L560,918 L545,940 L536,816Z" fill="#000" opacity=".35" filter="url(#b6)" transform="translate(8 6)"/>
    <path d="${ribbon}" fill="url(#ribbon)"/>
    <path d="M520,302 C528,500 538,700 548,816 L554,930" fill="none" stroke="#FF8A7A" stroke-opacity=".45" stroke-width="3"/>
  `;
  return svgWrap(defs, body);
}

// =====================================================================
// 3 · Esquina — pila de hojas y una esquina que se levanta
// =====================================================================
function icon3() {
  const r = rng(303);
  const P = { x: 222, y: 164, w: 580, h: 696, rx: 24 };
  const L = P.x + 62, R = P.x + P.w - 62;
  const crease = 1440; // x + y = crease
  let text = '';
  text += row(L, L + 300, 252, 34, r, '#1C2433', { minW: 110, maxW: 180, gap: 18 });
  text += row(L, L + 210, 304, 34, r, '#1C2433', { minW: 90, maxW: 130, gap: 18 });
  const ys = Array.from({ length: 9 }, (_, i) => 380 + i * 52);
  ys.forEach((y, i) => {
    const end = i === 3 ? L + (R - L) * 0.6 : R;
    text += row(L, end, y, 16, r, '#465063', { minW: 30, maxW: 96, gap: 14 });
  });
  const hy = ys[1];
  // hoja inferior: líneas y un resaltado que asoma bajo la esquina
  const r2 = rng(33);
  let text2 = '';
  for (let i = 0; i < 9; i++) text2 += row(L, R, 380 + i * 52, 16, r2, '#7F8BA0', { minW: 30, maxW: 96, gap: 14 });

  const C = [P.x + P.w, P.y + P.h];
  const P1 = [C[0], crease - C[0]], P2 = [crease - C[1], C[1]];
  const Cp = [crease - C[1], crease - C[0]];
  const flap = `M${P1} C${P1[0] - 46},${P1[1] - 12} ${Cp[0] + 40},${Cp[1] - 22} ${Cp[0] + 10},${Cp[1] - 4} C${Cp[0] - 8},${Cp[1] + 8} ${Cp[0] - 4},${Cp[1] + 40} ${Cp[0] - 2},${Cp[1] + 56} C${Cp[0] + 6},${P2[1] - 60} ${P2[0] + 4},${P2[1] - 30} ${P2} Z`;
  const mid = [(P1[0] + P2[0]) / 2, (P1[1] + P2[1]) / 2];

  const defs = commonDefs({ grainColor: '0.25 0.3 0.4' }) + `
    <linearGradient id="bg" x1="0" y1="0" x2=".6" y2="1"><stop offset="0" stop-color="#6CC0FF"/><stop offset=".55" stop-color="#2F7BF0"/><stop offset="1" stop-color="#1A4FCC"/></linearGradient>
    <radialGradient id="bgGlow" cx=".2" cy=".05" r=".8"><stop offset="0" stop-color="#fff" stop-opacity=".45"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
    <linearGradient id="paper" x1="0" y1="0" x2=".3" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#F0F3F8"/></linearGradient>
    <linearGradient id="flapG" x1="${f(mid[0])}" y1="${f(mid[1])}" x2="${Cp[0] + 6}" y2="${Cp[1] + 6}" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#C7D0DE"/><stop offset=".18" stop-color="#E9EEF5"/><stop offset=".42" stop-color="#FFFFFF"/><stop offset=".8" stop-color="#F2F5FA"/><stop offset="1" stop-color="#DCE3EE"/></linearGradient>
    <clipPath id="frontClip"><path clip-rule="evenodd" d="M-50,-50H1074V1074H-50Z M${P1} L${C[0] + 40},${P1[1] - 40} L${C[0] + 40},${C[1] + 40} L${P2[0] - 40},${C[1] + 40} L${P2}Z"/></clipPath>
    <clipPath id="frontPage"><rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" rx="${P.rx}"/></clipPath>
    <clipPath id="sheet2"><rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" rx="${P.rx}"/></clipPath>
  `;
  const sheet = (fill) => `<rect x="${P.x}" y="${P.y}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="${fill}"/>`;
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#bgGlow)"/>
    <g transform="rotate(7 512 520) translate(14 -6)">
      <rect x="${P.x + 10}" y="${P.y + 30}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#0A2A70" opacity=".35" filter="url(#b22)"/>
      ${sheet('#DCE6F4')}
    </g>
    <g transform="translate(10 12)">
      <rect x="${P.x + 10}" y="${P.y + 30}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#0A2A70" opacity=".35" filter="url(#b22)"/>
      ${sheet('#F4F7FC')}
      <g clip-path="url(#sheet2)">${text2}${marker(L - 10, R + 10, 380 + 8 * 52, 42)}</g>
    </g>
    <g clip-path="url(#frontClip)">
      <rect x="${P.x + 14}" y="${P.y + 34}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#0A2A70" opacity=".4" filter="url(#b30)"/>
      <rect x="${P.x + 2}" y="${P.y + 6}" width="${P.w}" height="${P.h}" rx="${P.rx}" fill="#0A2A70" opacity=".3" filter="url(#b6)"/>
      ${sheet('url(#paper)')}
      <g clip-path="url(#frontPage)">
        <rect width="1024" height="1024" filter="url(#grain)" opacity=".18"/>
        ${text}
        ${marker(L - 12, R - 40, hy, 44)}
      </g>
    </g>
    <line x1="${P1[0]}" y1="${P1[1]}" x2="${P2[0]}" y2="${P2[1]}" stroke="#0A2A70" stroke-opacity=".45" stroke-width="10" filter="url(#b8)" transform="translate(6 6)"/>
    <path d="${flap}" fill="#0A2A70" opacity=".32" filter="url(#b12)" transform="translate(-14 -12)"/>
    <path d="${flap}" fill="url(#flapG)"/>
    <path d="${flap}" fill="none" stroke="#fff" stroke-opacity=".9" stroke-width="1.5"/>
  `;
  return svgWrap(defs, body);
}

// =====================================================================
// 4 · Monograma — una «P» recortada de una página impresa y resaltada
// =====================================================================
function icon4() {
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

// =====================================================================
// 5 · Cristal — hoja de vidrio (Liquid Glass) con un resaltado que brilla
// =====================================================================
function icon5() {
  const r = rng(505);
  const S = { x: 208, y: 226, w: 572, h: 632, rx: 76 };
  const L = S.x + 68, R = S.x + S.w - 68;
  let text = '';
  text += row(L, L + 300, 312, 30, r, '#fff', { minW: 110, maxW: 170, gap: 18 });
  const ys = Array.from({ length: 8 }, (_, i) => 392 + i * 54);
  const hi = 3;
  ys.forEach((y, i) => {
    const end = i === ys.length - 1 ? L + (R - L) * 0.5 : R;
    text += row(L, end, y, 16, r, i === hi ? '#5A3B00' : '#fff', { minW: 30, maxW: 96, gap: 14 });
  });
  const hy = ys[hi];
  const back = `transform="rotate(11 600 470) translate(96 -58)"`;
  const sheetRect = (extra = '') => `<rect x="${S.x}" y="${S.y}" width="${S.w}" height="${S.h}" rx="${S.rx}" ${extra}/>`;
  const defs = commonDefs() + `
    <linearGradient id="bg" x1="0" y1="0" x2=".45" y2="1"><stop offset="0" stop-color="#7C86FF"/><stop offset=".5" stop-color="#4436D0"/><stop offset="1" stop-color="#1D1660"/></linearGradient>
    <radialGradient id="bgGlow" cx=".5" cy="-.05" r=".85"><stop offset="0" stop-color="#E4E8FF" stop-opacity=".55"/><stop offset="1" stop-color="#E4E8FF" stop-opacity="0"/></radialGradient>
    <radialGradient id="bgWarm" cx=".5" cy="1.05" r=".7"><stop offset="0" stop-color="#FF7AD9" stop-opacity=".45"/><stop offset="1" stop-color="#FF7AD9" stop-opacity="0"/></radialGradient>
    <linearGradient id="glassFill" x1="0" y1="0" x2=".25" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".36"/><stop offset=".55" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity=".10"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="1"/><stop offset=".28" stop-color="#fff" stop-opacity=".35"/><stop offset=".6" stop-color="#fff" stop-opacity=".06"/><stop offset="1" stop-color="#fff" stop-opacity=".75"/></linearGradient>
    <linearGradient id="hiG" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFF3B0"/><stop offset=".45" stop-color="#FFD43D"/><stop offset="1" stop-color="#FFAE1A"/></linearGradient>
    <clipPath id="glass">${sheetRect()}</clipPath>
    <clipPath id="glass2">${sheetRect(back)}</clipPath>
  `;
  const scene = `<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#bgGlow)"/><rect width="1024" height="1024" fill="url(#bgWarm)"/>`;
  const body = `
    ${scene}
    ${sheetRect(`${back} fill="#0B0830" opacity=".35" filter="url(#b30)"`)}
    <g clip-path="url(#glass2)">
      <g filter="url(#b30)">${scene}</g>
      <rect width="1024" height="1024" fill="url(#glassFill)" opacity=".75"/>
    </g>
    ${sheetRect(`${back} fill="none" stroke="url(#rim)" stroke-width="3" opacity=".8"`)}
    <rect x="${S.x + 8}" y="${S.y + 40}" width="${S.w}" height="${S.h}" rx="${S.rx}" fill="#0B0830" opacity=".5" filter="url(#b30)"/>
    <g clip-path="url(#glass)">
      <g filter="url(#b40)">
        ${scene}
        ${sheetRect(`${back} fill="#fff" opacity=".35"`)}
      </g>
      <rect width="1024" height="1024" fill="url(#glassFill)"/>
      <rect width="1024" height="1024" filter="url(#grain)" opacity=".05"/>
      <rect x="${L - 60}" y="${hy - 60}" width="${f(R - L + 120)}" height="120" rx="60" fill="#FFB52E" opacity=".55" filter="url(#b30)"/>
      <rect x="${L - 24}" y="${hy - 29}" width="${f(R - L + 48)}" height="58" rx="29" fill="#FFC53A" opacity=".9" filter="url(#b12)"/>
      <rect x="${L - 24}" y="${hy - 29}" width="${f(R - L + 48)}" height="58" rx="29" fill="url(#hiG)"/>
      <rect x="${L - 8}" y="${hy - 24}" width="${f(R - L + 16)}" height="13" rx="6.5" fill="#fff" opacity=".6" filter="url(#b2)"/>
      ${text}
      ${sheetRect(`fill="none" stroke="#fff" stroke-width="26" opacity=".14" filter="url(#b8)"`)}
    </g>
    <rect x="${S.x + 1.5}" y="${S.y + 1.5}" width="${S.w - 3}" height="${S.h - 3}" rx="${S.rx - 1.5}" fill="none" stroke="url(#rim)" stroke-width="3"/>
  `;
  return svgWrap(defs, body);
}

// =====================================================================
// 6 · Lupa — página sepia y una lupa que amplía la frase resaltada
// =====================================================================
function icon6() {
  const r = rng(606);
  const cx = 440, cy = 412, rg = 228, mag = 1.75;
  const ys = Array.from({ length: 15 }, (_, i) => 92 + i * 62);
  const hiRow = 5; // y = 402
  let text = '';
  ys.forEach((y, i) => {
    const short = i === 3 || i === 10;
    const x0 = i === 4 || i === 11 ? 150 : 92;
    text += row(x0, short ? 560 : 936, y, 17, r, '#5B4630', { minW: 30, maxW: 110, gap: 16 });
  });
  const hl = marker(80, 760, ys[hiRow], 46, '#FFD93F');
  const page = `<rect width="1024" height="1024" fill="url(#paper)"/><rect width="1024" height="1024" filter="url(#grain)" opacity=".4"/><rect width="1024" height="1024" filter="url(#fibers)" opacity=".35"/>${text}${hl}`;
  const ang = 45 * Math.PI / 180;
  const ringOuter = rg + 38;
  const handle = `
    <rect x="${ringOuter - 8}" y="-36" width="70" height="72" rx="10" fill="url(#brass)"/>
    <rect x="${ringOuter + 4}" y="-36" width="6" height="72" fill="#7A5418" opacity=".55"/>
    <rect x="${ringOuter + 46}" y="-36" width="6" height="72" fill="#7A5418" opacity=".55"/>
    <path d="M${ringOuter + 58},-40 H${ringOuter + 340} A44,44 0 0 1 ${ringOuter + 340},48 H${ringOuter + 58}Z" fill="url(#wood)"/>
    <path d="M${ringOuter + 66},-30 H${ringOuter + 336}" stroke="#fff" stroke-opacity=".35" stroke-width="7" stroke-linecap="round" filter="url(#b2)"/>`;
  const handleSil = `<rect x="${ringOuter - 8}" y="-38" width="400" height="88" rx="44"/>`;
  const defs = commonDefs({ grainColor: '0.42 0.30 0.15' }) + `
    <radialGradient id="paper" cx=".45" cy=".4" r=".85"><stop offset="0" stop-color="#FBF2E0"/><stop offset=".7" stop-color="#F1E3C6"/><stop offset="1" stop-color="#DCC59C"/></radialGradient>
    <clipPath id="lens"><circle cx="${cx}" cy="${cy}" r="${rg}"/></clipPath>
    <radialGradient id="lensEdge" cx=".5" cy=".5" r=".5"><stop offset=".78" stop-color="#4A3210" stop-opacity="0"/><stop offset=".96" stop-color="#4A3210" stop-opacity=".22"/><stop offset="1" stop-color="#2A1C08" stop-opacity=".45"/></radialGradient>
    <linearGradient id="rimG" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#A9AFBA"/><stop offset=".3" stop-color="#5B616B"/><stop offset=".55" stop-color="#25282E"/><stop offset=".8" stop-color="#4D525B"/><stop offset="1" stop-color="#8E949E"/></linearGradient>
    <linearGradient id="brassRing" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFE7A8"/><stop offset=".45" stop-color="#C8963C"/><stop offset="1" stop-color="#7A5418"/></linearGradient>
    <linearGradient id="brass" x1="0" y1="-36" x2="0" y2="36" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFE9AE"/><stop offset=".35" stop-color="#D9A64A"/><stop offset=".75" stop-color="#8E621E"/><stop offset="1" stop-color="#B98A3A"/></linearGradient>
    <linearGradient id="wood" x1="0" y1="-40" x2="0" y2="48" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#8A5636"/><stop offset=".35" stop-color="#5E3520"/><stop offset=".8" stop-color="#2E170B"/><stop offset="1" stop-color="#4A2816"/></linearGradient>
    <radialGradient id="glare" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff" stop-opacity=".75"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
  `;
  const sx = 30, sy = 40;
  const body = `
    ${page}
    <g opacity=".42" filter="url(#b12)" fill="#3B2508" transform="translate(${sx} ${sy})">
      <circle cx="${cx}" cy="${cy}" r="${rg + 19}" fill="none" stroke="#3B2508" stroke-width="40"/>
      <g transform="translate(${cx} ${cy}) rotate(45)">${handleSil}</g>
    </g>
    <circle cx="${cx + sx * 1.1}" cy="${cy + sy * 1.1}" r="${rg - 10}" fill="#3B2508" opacity=".08" filter="url(#b16)"/>
    <ellipse cx="${cx + sx + 40}" cy="${cy + sy + 50}" rx="90" ry="70" fill="#FFF8DC" opacity=".55" filter="url(#b30)"/>
    <g clip-path="url(#lens)">
      <g transform="translate(${cx} ${cy}) scale(${mag}) translate(${-cx} ${-cy})">${page}</g>
      <circle cx="${cx}" cy="${cy}" r="${rg}" fill="url(#lensEdge)"/>
      <ellipse cx="${cx - 92}" cy="${cy - 118}" rx="130" ry="46" transform="rotate(-38 ${cx - 92} ${cy - 118})" fill="url(#glare)" opacity=".8"/>
      <circle cx="${cx + 120}" cy="${cy + 140}" r="60" fill="url(#glare)" opacity=".25"/>
    </g>
    <circle cx="${cx}" cy="${cy}" r="${rg - 3}" fill="none" stroke="#fff" stroke-opacity=".6" stroke-width="3"/>
    <g transform="translate(${cx} ${cy}) rotate(45)">${handle}</g>
    <circle cx="${cx}" cy="${cy}" r="${rg + 19}" fill="none" stroke="url(#rimG)" stroke-width="38"/>
    <circle cx="${cx}" cy="${cy}" r="${rg + 3}" fill="none" stroke="url(#brassRing)" stroke-width="7"/>
    <circle cx="${cx}" cy="${cy}" r="${rg + 37}" fill="none" stroke="#fff" stroke-opacity=".35" stroke-width="2"/>
    <path d="M${cx - 200},${cy - 110} A${rg + 19},${rg + 19} 0 0 1 ${cx - 60},${cy - 236}" fill="none" stroke="#fff" stroke-opacity=".6" stroke-width="7" stroke-linecap="round" filter="url(#b2)"/>
  `;
  return svgWrap(defs, body);
}

// =====================================================================
// 7 · Recorte — recorte de periódico clavado en un corcho
// =====================================================================
function icon7() {
  const r = rng(707);
  const X0 = 206, X1 = 818, Y0 = 214, Y1 = 852;
  const tr = rng(77);
  const jag = (n, a, b, fn) => Array.from({ length: n + 1 }, (_, i) => fn(a + ((b - a) * i) / n, (tr() - 0.5) * 12));
  const topEdge = jag(60, X0, X1, (x, d) => `${f(x)},${f(Y0 + d)}`);
  const rightEdge = jag(64, Y0, Y1, (y, d) => `${f(X1 + d)},${f(y)}`);
  const outline = `M${X0},${Y1} L${X0},${Y0} L${topEdge.slice(1).join(' L')} L${rightEdge.join(' L')} Z`;

  const L = X0 + 38, R = X1 - 38, mid = 512;
  let content = '';
  content += `<rect x="${L}" y="252" width="118" height="14" rx="3" fill="#B8322A"/>`;
  content += row(L, R, 306, 42, r, '#141518', { minW: 110, maxW: 210, gap: 20 });
  content += row(L, L + 360, 362, 42, r, '#141518', { minW: 110, maxW: 190, gap: 20 });
  content += `<rect x="${L}" y="404" width="${R - L}" height="3" fill="#141518"/>`;
  // foto de trama (semitono)
  const img = { x: L, y: 426, w: mid - 14 - L, h: 200 };
  let dots = '';
  const step = 9;
  for (let y = img.y + step / 2; y < img.y + img.h; y += step) {
    for (let x = img.x + step / 2; x < img.x + img.w; x += step) {
      const u = (x - img.x) / img.w, v = (y - img.y) / img.h;
      const sun = Math.exp(-(((u - 0.68) ** 2 + (v - 0.32) ** 2) / 0.012));
      const hill = v > 0.62 + 0.12 * Math.sin(u * 7) ? 0.85 : 0;
      const hill2 = v > 0.5 + 0.18 * Math.cos(u * 4 + 1) ? 0.55 : 0;
      const sky = 0.18 + 0.2 * v;
      const dark = Math.min(1, Math.max(hill, hill2, sky) * (1 - sun));
      const rad = Math.sqrt(dark) * step * 0.55;
      if (rad > 0.4) dots += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(rad)}"/>`;
    }
  }
  content += `<g fill="#26272B">${dots}</g>`;
  content += row(img.x, img.x + img.w - 40, 648, 9, r, '#6A6C72', { minW: 24, maxW: 70, gap: 9 });
  const colRows = (x0, x1, y0, n, skipShort = []) => {
    let s = '';
    for (let i = 0; i < n; i++) {
      const end = skipShort.includes(i) ? x0 + (x1 - x0) * 0.55 : x1;
      s += row(x0, end, y0 + i * 32, 11, r, '#34363B', { minW: 22, maxW: 74, gap: 10 });
    }
    return s;
  };
  content += colRows(L, mid - 14, 684, 6, [5]);
  content += colRows(mid + 14, R, 434, 13, [5]);
  const hy = 434 + 7 * 32;
  content += marker(mid + 4, R + 8, hy, 26);
  content += marker(mid + 4, mid + 160, hy + 32, 26);

  const defs = commonDefs({ grainColor: '0.3 0.3 0.32' }) + `
    <filter id="cork" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <feTurbulence type="fractalNoise" baseFrequency="0.075" numOctaves="4" seed="21" result="n"/>
      <feColorMatrix in="n" type="matrix" values="0 0 0 0 0.33  0 0 0 0 0.19  0 0 0 0 0.08  -3.2 0 0 0 1.62" result="dark"/>
      <feTurbulence type="fractalNoise" baseFrequency="0.2" numOctaves="2" seed="4" result="n2"/>
      <feColorMatrix in="n2" type="matrix" values="0 0 0 0 0.98  0 0 0 0 0.84  0 0 0 0 0.6  3.2 0 0 0 -1.85" result="light"/>
      <feMerge><feMergeNode in="dark"/><feMergeNode in="light"/></feMerge>
    </filter>
    <filter id="fray" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <feTurbulence type="fractalNoise" baseFrequency="0.25" numOctaves="2" seed="2" result="n"/>
      <feDisplacementMap in="SourceGraphic" in2="n" scale="7" xChannelSelector="R" yChannelSelector="G"/>
    </filter>
    <linearGradient id="bg" x1="0" y1="0" x2=".4" y2="1"><stop offset="0" stop-color="#D7AA6E"/><stop offset="1" stop-color="#A9743D"/></linearGradient>
    <radialGradient id="light" cx=".3" cy=".1" r=".9"><stop offset="0" stop-color="#FFF3D6" stop-opacity=".45"/><stop offset=".6" stop-color="#FFF3D6" stop-opacity="0"/></radialGradient>
    <radialGradient id="vig" cx=".5" cy=".5" r=".72"><stop offset=".7" stop-color="#3A1E05" stop-opacity="0"/><stop offset="1" stop-color="#3A1E05" stop-opacity=".45"/></radialGradient>
    <linearGradient id="news" x1="0" y1="0" x2=".3" y2="1"><stop offset="0" stop-color="#F4EFE2"/><stop offset="1" stop-color="#E6DFCB"/></linearGradient>
    <radialGradient id="pinHead" cx=".38" cy=".32" r=".7"><stop offset="0" stop-color="#FF8A7C"/><stop offset=".35" stop-color="#F0362B"/><stop offset=".85" stop-color="#A3100E"/><stop offset="1" stop-color="#6E0806"/></radialGradient>
    <radialGradient id="pinBase" cx=".4" cy=".35" r=".7"><stop offset="0" stop-color="#E5392D"/><stop offset="1" stop-color="#7E0B08"/></radialGradient>
    <clipPath id="clip"><path d="${outline}"/></clipPath>
  `;
  const pinX = 512, pinY = 252;
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" filter="url(#cork)" opacity=".9"/>
    <rect width="1024" height="1024" fill="url(#light)"/>
    <rect width="1024" height="1024" fill="url(#vig)"/>
    <g transform="rotate(-6 512 250)">
      <path d="${outline}" fill="#2B1503" opacity=".5" filter="url(#b16)" transform="translate(${512 * -0.03 + 12} ${250 * -0.05 + 18}) scale(1.03 1.05)"/>
      <path d="${outline}" fill="#2B1503" opacity=".35" filter="url(#b4)" transform="translate(3 6)"/>
      <path d="${outline}" fill="#FFFFFF" filter="url(#fray)" transform="translate(-2 -3) scale(1.004)"/>
      <path d="${outline}" fill="url(#news)"/>
      <g clip-path="url(#clip)">
        <rect width="1024" height="1024" filter="url(#grain)" opacity=".45"/>
        <rect width="1024" height="1024" filter="url(#fibers)" opacity=".3"/>
        ${content}
      </g>
      <ellipse cx="${pinX + 20}" cy="${pinY + 26}" rx="42" ry="36" fill="#1C0A00" opacity=".45" filter="url(#b8)"/>
      <circle cx="${pinX}" cy="${pinY}" r="40" fill="url(#pinBase)"/>
      <circle cx="${pinX}" cy="${pinY}" r="40" fill="none" stroke="#5A0604" stroke-opacity=".5" stroke-width="2"/>
      <circle cx="${pinX - 5}" cy="${pinY - 7}" r="27" fill="#5A0604" opacity=".35" filter="url(#b4)" transform="translate(4 6)"/>
      <circle cx="${pinX - 5}" cy="${pinY - 7}" r="27" fill="url(#pinHead)"/>
      <ellipse cx="${pinX - 14}" cy="${pinY - 18}" rx="10" ry="6" transform="rotate(-35 ${pinX - 14} ${pinY - 18})" fill="#fff" opacity=".85" filter="url(#b2)"/>
    </g>
  `;
  return svgWrap(defs, body);
}

// =====================================================================
// 8 · Selección — selección de iOS con el menú de resaltar de la app
// =====================================================================
function icon8() {
  const r = rng(808);
  const C = { x: 168, y: 192, w: 688, h: 668, rx: 58 };
  const L = C.x + 64, R = C.x + C.w - 64;
  let text = '';
  text += row(L, L + 380, 292, 38, r, '#1C1C1E', { minW: 120, maxW: 200, gap: 20 });
  const ys = [380, 452, 524, 596, 812];
  const lines = ys.map((y, i) => words(L, i === 4 ? L + (R - L) * 0.42 : R, r, { minW: 40, maxW: 120, gap: 18 }));
  // selección alineada con palabras: desde la 3.ª palabra de la línea 2 hasta la 3.ª de la línea 3
  const sx = lines[1][2][0] - 8, ex = lines[2][2][0] + lines[2][2][1] + 8;
  const hiBands =
    `<rect x="${f(sx)}" y="${ys[1] - 28}" width="${f(R - sx + 12)}" height="56" rx="8" fill="#FFD84A"/>` +
    `<rect x="${L - 12}" y="${ys[2] - 28}" width="${f(ex - L + 12)}" height="56" rx="8" fill="#FFD84A"/>`;
  lines.forEach((ws, i) => {
    text += ws.map(([x, w]) => `<rect x="${f(x)}" y="${ys[i] - 11}" width="${f(w)}" height="22" rx="11" fill="#3A3A3C"/>`).join('');
  });
  const handle = (x, y0, y1, knobTop) => `
    <rect x="${x - 5}" y="${y0}" width="10" height="${y1 - y0}" rx="5" fill="#0A84FF"/>
    <circle cx="${x}" cy="${knobTop ? y0 - 12 : y1 + 12}" r="19" fill="#0A84FF"/>
    <circle cx="${x - 5}" cy="${knobTop ? y0 - 17 : y1 + 7}" r="6" fill="#fff" opacity=".45"/>`;
  // menú flotante con el icono de resaltar
  const mx = f((sx + ex) / 2), my = 704, mw = 196, mh = 104;
  const menu = `
    <rect x="${mx - mw / 2 + 4}" y="${my - mh / 2 + 18}" width="${mw}" height="${mh}" rx="${mh / 2}" fill="#3A1400" opacity=".45" filter="url(#b16)"/>
    <rect x="${mx - mw / 2}" y="${my - mh / 2}" width="${mw}" height="${mh}" rx="${mh / 2}" fill="url(#pill)"/>
    <rect x="${mx - mw / 2 + 1}" y="${my - mh / 2 + 1}" width="${mw - 2}" height="${mh - 2}" rx="${mh / 2}" fill="none" stroke="url(#pillRim)" stroke-width="2"/>
    <g transform="translate(${mx} ${my})">
      <rect x="-40" y="22" width="64" height="12" rx="4" fill="#FFD84A"/>
      <g transform="rotate(40)">
        <path d="M-11,-44 H11 A4,4 0 0 1 15,-40 V6 H-15 V-40 A4,4 0 0 1 -11,-44Z" fill="#fff"/>
        <path d="M-15,10 H15 L9,24 H-9Z" fill="#fff"/>
        <path d="M-8,28 H8 L4,38 H-6Z" fill="#FFD84A"/>
      </g>
    </g>`;
  const defs = commonDefs() + `
    <linearGradient id="bg" x1="0" y1="0" x2=".5" y2="1"><stop offset="0" stop-color="#FFC94D"/><stop offset=".55" stop-color="#FF8A2B"/><stop offset="1" stop-color="#F2553A"/></linearGradient>
    <radialGradient id="bgGlow" cx=".3" cy="0" r=".8"><stop offset="0" stop-color="#FFF6D0" stop-opacity=".6"/><stop offset="1" stop-color="#FFF6D0" stop-opacity="0"/></radialGradient>
    <linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#F3F2F0"/></linearGradient>
    <linearGradient id="pill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#48484C"/><stop offset=".5" stop-color="#2C2C2F"/><stop offset="1" stop-color="#1C1C1E"/></linearGradient>
    <linearGradient id="pillRim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".45"/><stop offset=".5" stop-color="#fff" stop-opacity=".05"/><stop offset="1" stop-color="#fff" stop-opacity=".15"/></linearGradient>
    <clipPath id="cardClip"><rect x="${C.x}" y="${C.y}" width="${C.w}" height="${C.h}" rx="${C.rx}"/></clipPath>
  `;
  const body = `
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#bgGlow)"/>
    <rect x="${C.x + 6}" y="${C.y + 36}" width="${C.w}" height="${C.h}" rx="${C.rx}" fill="#7A2200" opacity=".45" filter="url(#b30)"/>
    <rect x="${C.x}" y="${C.y + 6}" width="${C.w}" height="${C.h}" rx="${C.rx}" fill="#7A2200" opacity=".25" filter="url(#b6)"/>
    <rect x="${C.x}" y="${C.y}" width="${C.w}" height="${C.h}" rx="${C.rx}" fill="url(#card)"/>
    <g clip-path="url(#cardClip)">
      <rect width="1024" height="1024" filter="url(#grain)" opacity=".12"/>
      ${hiBands}
      ${text}
    </g>
    ${handle(sx - 2, ys[1] - 34, ys[1] + 32, true)}
    ${handle(ex + 2, ys[2] - 32, ys[2] + 34, false)}
    ${menu}
  `;
  return svgWrap(defs, body);
}

const ICONS = [
  ['01-marcador', icon1],
  ['02-libro', icon2],
  ['03-esquina', icon3],
  ['04-monograma', icon4],
  ['05-cristal', icon5],
  ['06-lupa', icon6],
  ['07-recorte', icon7],
  ['08-seleccion', icon8],
];

async function main() {
  const only = process.argv.slice(2);
  const { chromium } = require('playwright');
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
  const sq = squircle();
  for (const [name, fn] of ICONS) {
    if (only.length && !only.some((o) => name.startsWith(o))) continue;
    const svg = fn();
    fs.mkdirSync(path.join(OUT, 'svg'), { recursive: true });
    fs.mkdirSync(path.join(OUT, 'png'), { recursive: true });
    fs.mkdirSync(path.join(OUT, 'preview'), { recursive: true });
    fs.writeFileSync(path.join(OUT, 'svg', `${name}.svg`), svg);
    await page.setContent(`<!doctype html><html><body style="margin:0;background:#fff">${svg}</body></html>`);
    await page.screenshot({ path: path.join(OUT, 'png', `${name}.png`) });
    // vista previa a 512 px con la máscara de esquinas continuas de iOS
    const masked = svg
      .replace('width="1024" height="1024"', 'width="512" height="512"')
      .replace('<defs>', `<defs><clipPath id="iosMask"><path d="${sq}"/></clipPath>`)
      .replace(/<\/defs>([\s\S]*)<\/svg>$/, '</defs><g clip-path="url(#iosMask)">$1</g></svg>');
    await page.setContent(`<!doctype html><html><body style="margin:0;background:transparent">${masked}</body></html>`);
    await page.screenshot({ path: path.join(OUT, 'preview', `${name}.png`), omitBackground: true, clip: { x: 0, y: 0, width: 512, height: 512 } });
    console.log('ok', name);
  }
  await browser.close();
}

main().catch((e) => { console.error(e); process.exit(1); });
