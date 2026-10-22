#!/usr/bin/env bash
# Publica un IPA firmado (Ad Hoc) en la rama gh-pages para instalarlo desde Safari.
#
# Cada build va en una carpeta con el IPA, manifest.plist, index.html y build.json.
# La rama se reescribe como un único commit huérfano para que los IPA no se acumulen
# en el historial; se conservan todas las versiones de main y los últimos N builds de
# otras ramas. Si otro build publica a la vez, el push con --force-with-lease falla y
# se reintenta partiendo del contenido nuevo.
#
# Uso:
#   scripts/publish-pages.sh --tag TAG --ipa RUTA --base-url URL --version X.Y.Z --build N \
#     --channel stable|prerelease --branch RAMA --sha SHA --icon ICONO_1024.png \
#     [--commit-title TITULO] [--app-name NOMBRE] [--bundle-id ID] [--run-url URL] [--keep-prereleases 20]
#
# Requiere GH_TOKEN (o GITHUB_TOKEN) con permiso de escritura y GITHUB_REPOSITORY.
set -euo pipefail

TAG="" IPA="" BASE_URL="" VERSION="" BUILD="" CHANNEL="" BRANCH="" SHA="" ICON=""
APP_NAME="Leonera Paper" BUNDLE_ID="" RUN_URL="" KEEP_PRERELEASES=20 COMMIT_TITLE=""
REPO="${GITHUB_REPOSITORY:-}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --ipa) IPA="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --sha) SHA="$2"; shift 2 ;;
    --commit-title) COMMIT_TITLE="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --run-url) RUN_URL="$2"; shift 2 ;;
    --keep-prereleases) KEEP_PRERELEASES="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "Argumento desconocido: $1" >&2; exit 2 ;;
  esac
done

for required in TAG IPA BASE_URL VERSION BUILD CHANNEL BRANCH SHA ICON BUNDLE_ID REPO TOKEN; do
  if [ -z "${!required}" ]; then
    echo "::error::publish-pages.sh: falta ${required}" >&2
    exit 2
  fi
done
[ -f "$IPA" ] || { echo "::error::No existe el IPA $IPA" >&2; exit 2; }
[ -f "$ICON" ] || { echo "::error::No existe el icono $ICON" >&2; exit 2; }
case "$CHANNEL" in stable|prerelease) ;; *) echo "::error::Canal no válido: $CHANNEL" >&2; exit 2 ;; esac

BASE_URL="${BASE_URL%/}/"
IPA_NAME="$(basename "$IPA")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${PAGES_REMOTE:-https://x-access-token:${TOKEN}@github.com/${REPO}.git}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- carpeta del build

BUILD_DIR="$WORK/build/$TAG"
mkdir -p "$BUILD_DIR"
cp "$IPA" "$BUILD_DIR/$IPA_NAME"

make_icon() {
  local size="$1" out="$2"
  if command -v sips >/dev/null 2>&1; then
    sips -z "$size" "$size" "$ICON" --out "$out" >/dev/null
  elif python3 -c "import PIL" >/dev/null 2>&1; then
    python3 -c "import sys; from PIL import Image; Image.open(sys.argv[1]).convert('RGB').resize((int(sys.argv[2]),)*2, Image.LANCZOS).save(sys.argv[3])" "$ICON" "$size" "$out"
  else
    cp "$ICON" "$out"
  fi
}
make_icon 57 "$BUILD_DIR/icon-57.png"
make_icon 512 "$BUILD_DIR/icon-512.png"

python3 "$SCRIPT_DIR/pages_site.py" build \
  --dir "$BUILD_DIR" --tag "$TAG" --ipa "$IPA_NAME" --base-url "$BASE_URL" --version "$VERSION" \
  --build "$BUILD" --channel "$CHANNEL" --branch "$BRANCH" --sha "$SHA" --app-name "$APP_NAME" \
  --bundle-id "$BUNDLE_ID" --repo "$REPO" --run-url "$RUN_URL" --commit-title "$COMMIT_TITLE"

# ---------------------------------------------------------------- publicación

# Dentro de un `if`, bash ignora `set -e`: cada paso comprueba su resultado.
publish_attempt() {
  local attempt="$1"
  local site="$WORK/site-$attempt" old="$WORK/old-$attempt" lease=""
  mkdir -p "$site" || return 1

  if git ls-remote --exit-code --heads "$REMOTE" gh-pages >/dev/null 2>&1; then
    git init -q "$old" || return 1
    git -C "$old" fetch -q --depth 1 "$REMOTE" "refs/heads/gh-pages" || return 1
    lease="$(git -C "$old" rev-parse FETCH_HEAD)" || return 1
    git -C "$old" checkout -q --detach FETCH_HEAD || return 1
    # Solo se conservan carpetas de builds: la rama pudo crearse a partir del código.
    for dir in "$old"/*/; do
      [ -d "$dir" ] || continue
      if [ -f "$dir/build.json" ]; then
        cp -R "${dir%/}" "$site/" || return 1
      fi
    done
  fi

  rm -rf "${site:?}/$TAG"
  cp -R "$BUILD_DIR" "$site/$TAG" || return 1
  python3 "$SCRIPT_DIR/pages_site.py" index --site "$site" --base-url "$BASE_URL" \
    --keep-prereleases "$KEEP_PRERELEASES" --app-name "$APP_NAME" --repo "$REPO" || return 1
  touch "$site/.nojekyll" || return 1

  git -C "$site" init -q -b gh-pages || return 1
  # --force: un .gitignore global con *.ipa no debe dejar fuera el IPA.
  git -C "$site" add -A --force || return 1
  git -C "$site" -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "Publicar ${TAG}" || return 1
  git -C "$site" push -q --force-with-lease="refs/heads/gh-pages:${lease}" "$REMOTE" HEAD:refs/heads/gh-pages
}

for attempt in 1 2 3 4 5 6; do
  if publish_attempt "$attempt"; then
    echo "Publicado ${TAG} en ${BASE_URL}${TAG}/"
    exit 0
  fi
  wait_seconds=$(( attempt * 4 + RANDOM % 6 ))
  echo "gh-pages cambió mientras se publicaba (intento ${attempt}); reintentando en ${wait_seconds}s…"
  sleep "$wait_seconds"
done

echo "::error::No se pudo publicar en gh-pages tras varios intentos." >&2
exit 1
