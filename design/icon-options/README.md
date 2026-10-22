# Opciones de icono

Ocho propuestas para el icono de Leonera Paper sobre cuatro ideas: **papel**,
**resaltar**, **leer** y **real**.

| # | Opción | Idea |
| --- | --- | --- |
| 1 | Marcador | Hoja sobre azul tinta y un rotulador justo al final de la línea que acaba de resaltar. |
| 2 | Libro | Libro abierto con páginas curvas, cinta y una línea resaltada, sobre verde. |
| 3 | Esquina | Pila de hojas; la esquina levantada deja ver un resaltado en la hoja de abajo. |
| 4 | Monograma | Una «P» recortada de una página impresa y resaltada, sobre negro. |
| 5 | Cristal | Hojas de vidrio esmerilado (estilo Liquid Glass) con una línea resaltada que brilla. |
| 6 | Lupa | Página sepia y una lupa que amplía la frase resaltada. |
| 7 | Recorte | Recorte de periódico con dos líneas resaltadas, clavado en un corcho. |
| 8 | Selección | Tiradores de selección de iOS y el menú de resaltar de la app. |

- `png/`: 1024×1024, a sangre y sin transparencia, listos para `AppIcon.appiconset`.
- `svg/`: originales vectoriales.
- `preview/`: 512×512 con la máscara de esquinas continuas de iOS.

`build.cjs` genera todo con Chromium (Playwright); `glyphs.json` guarda el contorno
de la «P» (Fraunces ExtraBold, licencia OFL) para no depender de la fuente:

```sh
NODE_PATH=$(npm root -g) node design/icon-options/build.cjs        # todas
NODE_PATH=$(npm root -g) node design/icon-options/build.cjs 03 06  # solo algunas
```
