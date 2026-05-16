#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-"$ROOT_DIR/dist"}"
TMP_DIR="$DIST_DIR/.publishing-tmp"
BOOK_SOURCE="$TMP_DIR/book-source.md"
EPUB_SOURCE="$TMP_DIR/epub-source.md"
GUIDE_BODY="$TMP_DIR/guide-body.md"
VERSION_TEX="$TMP_DIR/version.tex"
PDF_OUT="$DIST_DIR/claude-architect-exam-guide.pdf"
EPUB_OUT="$DIST_DIR/claude-architect-exam-guide.epub"
COVER_IMAGE="$ROOT_DIR/publishing/cover.svg"
REPOSITORY_URL="https://github.com/daronyondem/claude-architect-exam-guide"

mkdir -p "$TMP_DIR"

if ! command -v pandoc >/dev/null 2>&1; then
  echo "pandoc is required to build release assets." >&2
  exit 1
fi

if [[ -n "${RELEASE_VERSION:-}" ]]; then
  BOOK_VERSION="$RELEASE_VERSION"
elif [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
  BOOK_VERSION="${GITHUB_REF#refs/tags/}"
elif [[ -n "${GITHUB_REF_NAME:-}" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  BOOK_VERSION="$GITHUB_REF_NAME"
elif git -C "$ROOT_DIR" describe --tags --exact-match >/dev/null 2>&1; then
  BOOK_VERSION="$(git -C "$ROOT_DIR" describe --tags --exact-match)"
else
  BOOK_VERSION="dev"
fi

awk 'NR == 1 && $0 ~ /^# / { next } { print }' \
  "$ROOT_DIR/exam-preparation-guide.md" > "$GUIDE_BODY"

cat "$ROOT_DIR/publishing/frontmatter.md" "$GUIDE_BODY" > "$BOOK_SOURCE"

cat > "$EPUB_SOURCE" <<EOF
## Claude Certified Architect - Foundations

<p class="book-subtitle">Exam Preparation Guide</p>
<p class="book-version">Version: $BOOK_VERSION</p>
<p class="book-author">Daron Yondem</p>
<p class="book-updates"><a href="$REPOSITORY_URL">Repository and updates</a></p>

EOF
cat "$ROOT_DIR/publishing/frontmatter.md" "$GUIDE_BODY" >> "$EPUB_SOURCE"

printf '\\def\\BookVersion{\\detokenize{%s}}\n' "$BOOK_VERSION" > "$VERSION_TEX"

if command -v rsvg-convert >/dev/null 2>&1; then
  COVER_IMAGE="$TMP_DIR/cover.png"
  rsvg-convert \
    --width 1600 \
    --height 2560 \
    --output "$COVER_IMAGE" \
    "$ROOT_DIR/publishing/cover.svg"
fi

COMMON_ARGS=(
  "--from=gfm+smart"
  "--metadata-file=$ROOT_DIR/publishing/metadata.yml"
  "--metadata=release-version:$BOOK_VERSION"
  "--shift-heading-level-by=-1"
  "--toc"
  "--toc-depth=2"
  "--resource-path=$ROOT_DIR:$ROOT_DIR/publishing"
)

pandoc "$EPUB_SOURCE" "${COMMON_ARGS[@]}" \
  "--css=$ROOT_DIR/publishing/epub.css" \
  "--epub-cover-image=$COVER_IMAGE" \
  "--epub-title-page=false" \
  "--split-level=1" \
  -o "$EPUB_OUT"

if command -v xelatex >/dev/null 2>&1; then
  pandoc "$BOOK_SOURCE" "${COMMON_ARGS[@]}" \
    "--pdf-engine=xelatex" \
    "--top-level-division=chapter" \
    "--lua-filter=$ROOT_DIR/publishing/fit-tables.lua" \
    "--include-in-header=$VERSION_TEX" \
    "--include-in-header=$ROOT_DIR/publishing/pdf-header.tex" \
    "--syntax-highlighting=tango" \
    -o "$PDF_OUT"
elif [[ "${SKIP_PDF_ON_MISSING_ENGINE:-0}" == "1" ]]; then
  echo "xelatex not found; skipped PDF build because SKIP_PDF_ON_MISSING_ENGINE=1." >&2
else
  echo "xelatex is required to build the PDF. Install a TeX distribution or run with SKIP_PDF_ON_MISSING_ENGINE=1 to build EPUB only." >&2
  exit 1
fi

rm -rf "$TMP_DIR"

echo "Built release assets:"
[[ -f "$PDF_OUT" ]] && echo "  $PDF_OUT"
echo "  $EPUB_OUT"
