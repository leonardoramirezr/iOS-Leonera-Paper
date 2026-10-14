# Leonera Paper

App de iOS (SwiftUI, sin dependencias externas) para guardar artículos web y PDF
como Markdown, leerlos con varios estilos, resaltarlos y consultar el diccionario.

## Funciones

- **Guardar artículos** desde Safari (botón Compartir › *Leonera Paper*) o pegando
  una URL (botón **+**).
- **Conversión a Markdown con imágenes**: la página se carga en un `WKWebView`
  oculto, `App/Import/extractor.js` localiza el contenido principal (heurística al
  estilo Readability) y lo convierte a Markdown; las imágenes se descargan a la
  carpeta del artículo.
- **PDF a Markdown**: también acepta PDF, desde el botón **+** (*Elegir PDF…*), con
  *Abrir en Leonera Paper* desde Archivos, Mail o cualquier app que comparta un PDF,
  o pegando/compartiendo el enlace a un PDF (se detecta por la extensión o por el
  tipo de contenido que devuelve el servidor). `App/Import/PDFConverter.swift` lo
  convierte con PDFKit: agrupa las líneas en párrafos según su posición, detecta
  títulos (por tamaño de letra o negrita), listas, bloques de código (fuente
  monoespaciada), negritas y cursivas; quita encabezados, pies y números de página
  repetidos y une las palabras cortadas con guion. Las páginas escaneadas pasan por
  el OCR de Vision (y, si no tienen texto, se guardan como imagen) y las imágenes
  incrustadas se extraen a `images/`. El PDF original se guarda junto al Markdown y
  se puede ver desde el menú del artículo (*Ver PDF original*).
- **Almacenamiento local** en *Archivos › En mi iPhone › Leonera Paper*: una carpeta
  por artículo con `<artículo>.md` (con *front matter* YAML), `images/` y, si viene
  de un PDF, `<artículo>.pdf`.
- **Google Drive (opcional)**: copia cada artículo en la carpeta *Leonera Paper* de
  tu Drive y actualiza el Markdown cuando cambian los resaltados.
- **Resaltado**: al seleccionar texto aparece, justo debajo (o encima si la palabra
  está muy abajo), un menú con un único icono para resaltar. El resaltado se guarda
  en el Markdown como `==texto resaltado==`; sobre un texto ya resaltado, el mismo
  icono lo quita.
- **Estilos de lectura**: Papel y Sepia (claros), Noche, Pizarra y Negro (oscuros) y
  Tinta electrónica (sin color, sombras ni animaciones). Tipografía, tamaño,
  interlineado y márgenes ajustables.
- **Diccionario**: al seleccionar una palabra se abre, a todo el ancho y en el lado
  (arriba o abajo) con más espacio libre, un panel con su definición en
  **Oxford English–Spanish** y, si no está ahí, en **Oxford Dictionary of English**.
  Desde el propio panel se puede cambiar de diccionario.

### Sobre el diccionario

Oxford no ofrece una API gratuita, así que hay dos modos:

1. **Oxford Dictionaries API** (exacto): en *Ajustes › Diccionario* introduce el
   App ID y la App Key de [developer.oxforddictionaries.com](https://developer.oxforddictionaries.com).
   El panel consulta `translations/en/es` (Oxford English–Spanish) y, si la palabra
   no existe, `entries/en-gb` (Oxford Dictionary of English), con búsqueda del lema
   («running» → «run»).
2. **Diccionarios de iOS** (sin clave): el panel muestra el diccionario del sistema,
   cuyos diccionarios de inglés-español y de inglés británico son los de Oxford.
   Actívalos en *Ajustes › General › Diccionario* («Español – Inglés» e «Inglés
   (Reino Unido)»).

### Google Drive

1. En [Google Cloud Console](https://console.cloud.google.com/) habilita la
   *Google Drive API* y crea un ID de cliente OAuth de tipo **iOS** con el bundle
   ID `com.leonardoramirezr.leonerapaper`.
2. Ponlo en la app (*Ajustes › Google Drive*) o guárdalo en la variable de
   repositorio `GOOGLE_CLIENT_ID` (*Settings › Secrets and variables › Actions ›
   Variables*) para incluirlo en cada build.
3. Pulsa *Conectar con Google Drive*. La app usa el alcance `drive.file`: solo ve
   los archivos que crea.

## Estructura

| Ruta | Contenido |
| --- | --- |
| `project.yml` | Proyecto de [XcodeGen](https://github.com/yonaskolb/XcodeGen) (app + extensión de compartir). |
| `App/` | App SwiftUI: biblioteca, importación (web y PDF), lector, diccionario y Google Drive. |
| `App/Markdown/` | Intérprete de Markdown con mapa de posiciones (para escribir `==…==` en el sitio exacto). |
| `ShareExtension/` | Extensión «Compartir» de Safari. |
| `Shared/` | Código común: cola de enlaces pendientes en un grupo de llavero. |
| `Config/` | `Info.plist` y entitlements. |
| `scripts/` | Validación de App Store Connect, verificación del IPA y publicación en Pages. |

La extensión no usa App Groups: deja la URL en un grupo de llavero compartido
(`keychain-access-groups`, que no requiere registrar nada en el portal) y abre la
app con `leonerapaper://import?url=…`; si no consigue abrirla, la app importa los
enlaces pendientes la próxima vez que se abre.

## Desarrollo local

```sh
brew install xcodegen
xcodegen generate
open LeoneraPaper.xcodeproj
```

Selecciona tu equipo en *Signing & Capabilities* (o pasa `DEVELOPMENT_TEAM=…` a
`xcodebuild`). Los identificadores son build settings (`APP_BUNDLE_ID`,
`SHARE_EXTENSION_BUNDLE_ID`), así que se pueden cambiar sin tocar el proyecto.

## Compilación y despliegue (GitHub Actions)

`.github/workflows/build.yml` se ejecuta en cada push (salvo a `gh-pages`) y con
*Run workflow*, en `macos-15`:

1. Calcula la etiqueta: en `main`, `0.x.0` (incrementa el número intermedio respecto
   a la última etiqueta) y se publica como release estable *Latest*; en otras ramas,
   `build-<run_number>-<sha7>` como pre-release. Ningún build se cancela.
2. Valida la clave con la API de App Store Connect (`scripts/asc.py`, solo
   biblioteca estándar + `openssl`) y que haya al menos un iPhone registrado.
3. Genera el proyecto con XcodeGen y hace `xcodebuild archive` con firma automática
   (`-allowProvisioningUpdates` y la clave de API): Xcode registra los App IDs y crea
   los perfiles.
4. Exporta con `method=release-testing` (Ad Hoc) usando el certificado de
   distribución gestionado en la nube y comprueba que cada bundle lleva un perfil
   Ad Hoc con los dispositivos registrados.
5. Publica el IPA en GitHub Pages y crea la release con el IPA adjunto. El enlace de
   instalación aparece en el resumen de la ejecución y en las notas de la release.
6. Siempre, al final, revoca el certificado «Apple Development» temporal que
   xcodebuild crea en cada ejecución.

### Secrets necesarios

En *Settings › Secrets and variables › Actions › Repository secrets* (secrets del
repositorio, no de una organización):

| Secret | Valor |
| --- | --- |
| `ASC_KEY_ID` | Key ID de la clave de API de App Store Connect. |
| `ASC_ISSUER_ID` | Issuer ID (en *Users and Access › Integrations › App Store Connect API*). |
| `ASC_KEY_P8` | Contenido completo del archivo `AuthKey_XXXX.p8`. Debe ser una **Team Key** con rol **Admin**. |
| `APPLE_TEAM_ID` | Team ID de Apple Developer. |

Sin ningún secret se genera un IPA **sin firmar** (como artefacto de la ejecución,
sin publicarlo). Si solo hay algunos, el workflow falla indicando cuáles faltan.

### Activar GitHub Pages

Después del **primer build firmado** (que crea la rama `gh-pages`), ve a
*Settings › Pages* y elige *Deploy from a branch* con la rama **`gh-pages`** y la
carpeta **`/ (root)`**. La web queda en
`https://leonardoramirezr.github.io/iOS-Leonera-Paper/`:

- La portada lista todos los builds y tiene un botón para la última versión estable.
- Cada build tiene su carpeta con el IPA, `manifest.plist`, `build.json` y una página
  con el botón de instalación (`itms-services://`).
- La rama se reescribe en cada publicación como un único commit, conservando todas
  las versiones de `main` y los últimos 20 builds de otras ramas.

Para instalar, abre la página en **Safari** en el iPhone y pulsa *Instalar*.

### Añadir un iPhone

Registra su UDID en [Apple Developer › Devices](https://developer.apple.com/account/resources/devices/list)
y haz push: el siguiente build genera perfiles Ad Hoc que lo incluyen.
