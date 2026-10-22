# Icono de la app

Monograma: una «P» recortada de una página impresa, con una franja resaltada, sobre
negro. Reúne las ideas de **papel**, **resaltar**, **leer** y **real**.

- `icon.svg`: original vectorial.
- `preview.png`: 512×512 con la máscara de esquinas continuas de iOS.
- `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`: el PNG de 1024×1024 que usa la app.

`build.cjs` genera los tres con Chromium (Playwright); `glyphs.json` guarda el contorno
de la «P» (Fraunces ExtraBold, licencia OFL) para no depender de la fuente:

```sh
NODE_PATH=$(npm root -g) node design/app-icon/build.cjs
```
