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
- **Cambiar el título**: el título se toma solo al guardar, pero se puede editar
  desde el menú de un artículo (mantener pulsado en la biblioteca, o *«⋯»* en el
  lector). Se actualiza en la lista, en el *front matter* y el encabezado del
  Markdown y, si está en Google Drive, en la copia subida. La carpeta y el archivo
  conservan su nombre.
- **Blogs para descubrir artículos**: la pestaña *Blogs* (barra inferior, junto a
  *Artículos*) guarda enlaces a la portada o el archivo de blogs, newsletters,
  Medium, Substack… Al pegar la URL (botón **+** de esa pestaña) se obtienen el
  título y el icono de la página, editables antes de guardar. Se muestran en una
  lista con el icono a la izquierda y el título a la derecha; tocar uno lo abre.
- **YouTube video summaries**: paste a YouTube link (**+** button) or share it from
  the YouTube app or Safari. The app downloads the audio, transcribes it with Whisper
  on Groq and has the LLM provider you choose (Gemini, Claude, OpenAI, Groq, NVIDIA,
  Cloudflare and others) write a *Main takeaways* summary. The video is saved as an
  article in the list: its thumbnail, channel, length and the first lines of the
  summary show in the list, and the article holds the summary. When you paste a
  YouTube link you choose its size (short, medium by default, or long). The
  transcript is not saved. See [YouTube summaries](#youtube-summaries).
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

### YouTube summaries

1. Create an API key for [Groq](https://console.groq.com/keys), which transcribes the
   audio with Whisper, and one for the LLM provider that writes the summary.
2. Enter them in *Ajustes › Resúmenes de YouTube* and *Modelo de lenguaje*. They are
   stored in the iPhone keychain and never go into the build: the IPA is public on
   GitHub Pages. Each *Probar clave* button checks its key: Groq lists its models and
   confirms that the Whisper model is among them, and the LLM provider answers a
   one-word request sent with the chosen model.
3. Choose the provider and its model. Every provider is reached through its
   OpenAI-compatible chat completions API:

   | Provider | Base URL | Default model |
   | --- | --- | --- |
   | Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-3.8-flash` |
   | Groq | `https://api.groq.com/openai/v1` | `openai/gpt-oss-120b` |
   | NVIDIA | `https://integrate.api.nvidia.com/v1` | `meta/llama-3.3-70b-instruct` |
   | OpenAI | `https://api.openai.com/v1` | `gpt-5-mini` |
   | Claude | `https://api.anthropic.com/v1` | `claude-opus-5-5` |
   | Cloudflare Workers AI | `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1` | `@cf/openai/gpt-oss-120b` |
   | Mistral | `https://api.mistral.ai/v1` | `mistral-small-latest` |
   | OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-5-mini` |
   | DeepSeek | `https://api.deepseek.com` | `deepseek-flash` |
   | xAI (Grok) | `https://api.x.ai/v1` | `grok-4.7` |
   | Other | the base URL you enter | the model you enter |

   Cloudflare needs your account ID, and *Other* needs its base URL. Switching provider
   restores that provider's default model. Once the key is entered, Settings lists the
   chat models the account can use, read from the provider's model list (Cloudflare's
   Workers AI text generation catalog); providers without a list, or a model that is not
   listed, can still be typed in. Claude goes
   through Anthropic's OpenAI SDK compatibility layer, which Anthropic presents as a way
   to test models rather than a production interface.
4. Optional settings: the Whisper model (the Whisper models Groq lists for your key,
   `whisper-large-v3-turbo` until they load) and the summary language (the video's
   language by default, Spanish or English).

How an import works (`App/YouTube/`):

1. `YouTubeLink` recognizes `watch?v=`, `youtu.be/`, `/shorts/`, `/live/` and
   `/embed/` links and normalizes them, so the same video is not saved twice.
2. `YouTubeClient` asks YouTube's InnerTube player API for the video with the same
   clients yt-dlp uses without JavaScript (`VISIONOS`, then `ANDROID_VR`), whose stream
   URLs need no signature deciphering or PO token. It downloads the smallest AAC
   audio-only stream in 5 MB ranges. If YouTube refuses every audio stream, it
   downloads the video with sound instead and uses its audio track. When YouTube
   changes its clients, update the values in `YouTubeClient.clients` from
   `yt_dlp/extractor/youtube/_base.py`.
3. `AudioChunker` converts the audio to 16 kHz mono AAC with AVFoundation and splits
   it into 30-minute parts, which stay under Groq's 25 MB upload limit.
4. `GroqTranscriber` sends each part to `/openai/v1/audio/transcriptions`
   (`verbose_json`, for the segment times).
5. `LLMSummarizer` sends the transcript to the chat completions endpoint of the chosen
   provider and asks for an overview sentence followed by a numbered `## Main takeaways`
   list. The size chosen in *Añadir artículo* sets the number of takeaways: short 3–5
   with one sentence each, medium 5–10 with one to three sentences, long 10–15 with
   three to five. `LLMProvider` holds each provider's base URL and default model.
6. `YouTubeImporter` writes the Markdown file: front matter, title, channel, link and
   length, thumbnail and summary. The transcript is not written to the article.

The video data, the audio and the transcript are kept in `Caches/YouTube/<id>/` until
the article is saved, and the transcript is deleted with them. If a step fails (for
example, a missing key), *Reintentar* resumes from that step without downloading or
transcribing again, and keeps the size chosen for the link.

## Estructura

| Ruta | Contenido |
| --- | --- |
| `project.yml` | Proyecto de [XcodeGen](https://github.com/yonaskolb/XcodeGen) (app + extensión de compartir). |
| `App/` | App SwiftUI: biblioteca, importación (web y PDF), lector, diccionario y Google Drive. |
| `App/Markdown/` | Intérprete de Markdown con mapa de posiciones (para escribir `==…==` en el sitio exacto). |
| `App/YouTube/` | YouTube summaries: audio download, conversion, Whisper transcription (Groq) and summary (any OpenAI-compatible provider). |
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
