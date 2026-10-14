#!/usr/bin/env python3
"""Genera los archivos de GitHub Pages para instalar los builds Ad Hoc (usado por publish-pages.sh).

  build  Escribe manifest.plist, index.html y build.json en la carpeta de un build.
  index  Elimina builds antiguos de ramas y escribe la portada con todos los builds.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import plistlib
import re
import shutil
import urllib.parse

STYLE = """
:root { color-scheme: light dark; --bg:#f5f5f7; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --accent:#c26a00; --line:#e3e3e8; }
@media (prefers-color-scheme: dark) { :root { --bg:#111418; --card:#1c2128; --text:#e6e6e9; --muted:#9a9aa3; --accent:#f0b43c; --line:#2d333b; } }
* { box-sizing: border-box; }
body { margin:0; font:16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background:var(--bg); color:var(--text); }
main { max-width:720px; margin:0 auto; padding:32px 16px 64px; }
header { display:flex; align-items:center; gap:16px; margin-bottom:24px; }
header img { width:72px; height:72px; border-radius:16px; box-shadow:0 2px 10px rgba(0,0,0,.15); }
h1 { font-size:28px; margin:0; } h2 { font-size:18px; margin:32px 0 12px; }
.muted { color:var(--muted); font-size:14px; }
.button { display:inline-block; background:var(--accent); color:#fff; text-decoration:none; font-weight:600; padding:14px 22px; border-radius:14px; }
.button.small { padding:8px 14px; border-radius:10px; font-size:14px; }
.button.disabled { background:var(--line); color:var(--muted); pointer-events:none; }
.card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:16px; margin:12px 0; }
.row { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:12px 0; border-top:1px solid var(--line); }
.row:first-child { border-top:0; }
.row a.title { color:var(--text); font-weight:600; text-decoration:none; }
dl { display:grid; grid-template-columns:max-content 1fr; gap:6px 16px; margin:0; }
dt { color:var(--muted); } dd { margin:0; word-break:break-all; }
a { color:var(--accent); }
code { font-size:13px; }
"""


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def install_link(manifest_url: str) -> str:
    return "itms-services://?action=download-manifest&url=" + urllib.parse.quote(manifest_url, safe="")


def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>{STYLE}</style>
</head>
<body><main>
{body}
</main></body>
</html>
"""


def version_key(version: str) -> tuple:
    return tuple(int(part) if part.isdigit() else 0 for part in re.split(r"[.-]", version))


def format_date(value: str) -> str:
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return moment.strftime("%Y-%m-%d %H:%M UTC")
    except ValueError:
        return value


def command_build(args: argparse.Namespace) -> None:
    base = args.base_url.rstrip("/") + "/"
    folder = f"{base}{urllib.parse.quote(args.tag)}/"
    manifest_url = f"{folder}manifest.plist"
    ipa_url = f"{folder}{urllib.parse.quote(args.ipa)}"

    manifest = {
        "items": [{
            "assets": [
                {"kind": "software-package", "url": ipa_url},
                {"kind": "display-image", "url": f"{folder}icon-57.png"},
                {"kind": "full-size-image", "url": f"{folder}icon-512.png"},
            ],
            "metadata": {
                "bundle-identifier": args.bundle_id,
                "bundle-version": args.version,
                "kind": "software",
                "title": args.app_name,
            },
        }]
    }
    with open(os.path.join(args.dir, "manifest.plist"), "wb") as handle:
        plistlib.dump(manifest, handle)

    created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    build = {
        "tag": args.tag,
        "version": args.version,
        "build": args.build,
        "channel": args.channel,
        "branch": args.branch,
        "sha": args.sha,
        "created": created,
        "app_name": args.app_name,
        "bundle_id": args.bundle_id,
        "ipa": args.ipa,
        "repo": args.repo,
        "run_url": args.run_url,
        "page_url": folder,
        "manifest_url": manifest_url,
        "install_url": install_link(manifest_url),
    }
    with open(os.path.join(args.dir, "build.json"), "w", encoding="utf-8") as handle:
        json.dump(build, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    channel = "Versión estable" if args.channel == "stable" else "Pre-release"
    commit_url = f"https://github.com/{args.repo}/commit/{args.sha}"
    run = f'<dt>Ejecución</dt><dd><a href="{esc(args.run_url)}">GitHub Actions</a></dd>' if args.run_url else ""
    body = f"""
<header>
  <img src="icon-512.png" alt="">
  <div><h1>{esc(args.app_name)}</h1><div class="muted">{esc(channel)} · {esc(args.version)} ({esc(args.build)})</div></div>
</header>
<p><a class="button" href="{esc(install_link(manifest_url))}">Instalar en el iPhone</a></p>
<p class="muted">Abre esta página en Safari en un iPhone cuyo UDID esté registrado en Apple Developer.</p>
<div class="card"><dl>
  <dt>Etiqueta</dt><dd>{esc(args.tag)}</dd>
  <dt>Versión</dt><dd>{esc(args.version)} ({esc(args.build)})</dd>
  <dt>Rama</dt><dd>{esc(args.branch)}</dd>
  <dt>Commit</dt><dd><a href="{esc(commit_url)}"><code>{esc(args.sha[:7])}</code></a></dd>
  <dt>Fecha</dt><dd>{esc(format_date(created))}</dd>
  <dt>IPA</dt><dd><a href="{esc(args.ipa)}">{esc(args.ipa)}</a></dd>
  {run}
</dl></div>
<p><a href="../">← Todas las versiones</a></p>
"""
    with open(os.path.join(args.dir, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(page(f"{args.app_name} {args.tag}", body))


def command_index(args: argparse.Namespace) -> None:
    site = args.site
    base = args.base_url.rstrip("/") + "/"
    builds = []
    for name in sorted(os.listdir(site)):
        path = os.path.join(site, name)
        if not os.path.isdir(path) or name.startswith("."):
            continue
        try:
            with open(os.path.join(path, "build.json"), encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError):
            shutil.rmtree(path)
            continue
        data["_dir"] = name
        builds.append(data)

    stable = sorted((b for b in builds if b.get("channel") == "stable"),
                    key=lambda b: version_key(str(b.get("version", "0"))), reverse=True)
    prereleases = sorted((b for b in builds if b.get("channel") != "stable"),
                         key=lambda b: (str(b.get("created", "")), int(str(b.get("build", "0")) or 0)), reverse=True)
    for old in prereleases[args.keep_prereleases:]:
        shutil.rmtree(os.path.join(site, old["_dir"]))
    prereleases = prereleases[:args.keep_prereleases]

    def manifest_for(build: dict) -> str:
        return f"{base}{urllib.parse.quote(build['_dir'])}/manifest.plist"

    def rows(items: list[dict]) -> str:
        if not items:
            return '<p class="muted">Todavía no hay builds.</p>'
        result = []
        for build in items:
            meta = f"{esc(build.get('version', ''))} ({esc(build.get('build', ''))}) · {esc(build.get('branch', ''))} · " \
                   f"<code>{esc(str(build.get('sha', ''))[:7])}</code> · {esc(format_date(str(build.get('created', ''))))}"
            result.append(f"""<div class="row">
  <div><a class="title" href="{esc(build['_dir'])}/">{esc(build['_dir'])}</a><div class="muted">{meta}</div></div>
  <a class="button small" href="{esc(install_link(manifest_for(build)))}">Instalar</a>
</div>""")
        return '<div class="card">' + "\n".join(result) + "</div>"

    icon_source = (stable or prereleases or [None])[0]
    icon = f'<img src="{esc(icon_source["_dir"])}/icon-512.png" alt="">' if icon_source else ""
    if stable:
        latest = stable[0]
        cta = (f'<p><a class="button" href="{esc(install_link(manifest_for(latest)))}">'
               f'Instalar la última versión estable ({esc(latest.get("version", ""))})</a></p>')
    else:
        cta = '<p><a class="button disabled" href="#">Aún no hay versión estable</a></p>'

    body = f"""
<header>
  {icon}
  <div><h1>{esc(args.app_name)}</h1><div class="muted">Builds Ad Hoc de <a href="https://github.com/{esc(args.repo)}">{esc(args.repo)}</a></div></div>
</header>
{cta}
<p class="muted">Abre esta página en Safari en un iPhone registrado. Para añadir un iPhone, registra su UDID en Apple Developer y haz push: el siguiente build lo incluirá.</p>
<h2>Versiones estables (main)</h2>
{rows(stable)}
<h2>Builds de otras ramas (últimos {args.keep_prereleases})</h2>
{rows(prereleases)}
"""
    with open(os.path.join(site, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(page(args.app_name, body))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build")
    for name in ("dir", "tag", "ipa", "base-url", "version", "build", "channel", "branch", "sha",
                 "app-name", "bundle-id", "repo"):
        build.add_argument(f"--{name}", required=True)
    build.add_argument("--run-url", default="")

    index = sub.add_parser("index")
    index.add_argument("--site", required=True)
    index.add_argument("--base-url", required=True)
    index.add_argument("--keep-prereleases", type=int, default=20)
    index.add_argument("--app-name", required=True)
    index.add_argument("--repo", required=True)

    args = parser.parse_args()
    if args.command == "build":
        command_build(args)
    else:
        command_index(args)


if __name__ == "__main__":
    main()
