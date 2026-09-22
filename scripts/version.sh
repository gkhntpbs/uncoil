#!/bin/bash
# Uncoil sürüm durumu — tek doğruluk kaynağı project.yml, geri kalan ona uymalı.
#
#   scripts/version.sh              # durumu göster + tutarlılığı denetle
#   scripts/version.sh --set 0.2.0  # MARKETING_VERSION'ı ayarla, build'i 1 artır
#   scripts/version.sh --bump-build # sadece build'i 1 artır, sürümü elleme
#
# Build numarası derlemeyi değil YAYINI sayar. Her xcodebuild'de artsaydı
# sayının anlamı kalmazdı; Sparkle'ın karşılaştırdığı tek sayı odur ve tek
# sorusu "bu, kullanıcıdakinden yeni mi". Bu yüzden yalnız iki yerde artar:
# --set ile yeni sürüm keserken, ve sürüm değişmeden yeniden yayınlarken
# --bump-build ile. İkisi de yayının kendisi değil, hazırlığıdır.
#
# Hiçbir şey commit etmez, tag atmaz, yayınlamaz.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

read_marketing() { grep -E '^[[:space:]]+MARKETING_VERSION:' project.yml | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }
read_build()     { grep -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed 's/.*: *"\(.*\)"/\1/'; }

set_build() { /usr/bin/sed -i '' -e "s/^\([[:space:]]*CURRENT_PROJECT_VERSION:\) .*/\1 \"$1\"/" project.yml; }

# Bir tag'in gösterdiği commit'te build numarası kaçtı. Yayınlanmış build'i
# tahmin etmenin tek dürüst yolu bu: appcast başka repoda, ama tag burada ve
# project.yml o commit'in içinde duruyor.
build_at_tag() {
  git show "$1:project.yml" 2>/dev/null \
    | grep -E '^[[:space:]]+CURRENT_PROJECT_VERSION:' | head -1 | sed 's/.*: *"\(.*\)"/\1/'
}

highest_release_build() {
  local highest=0 tag build
  while IFS= read -r tag; do
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-edge\.[0-9]+)?$ ]] || continue
    build="$(build_at_tag "$tag")" || {
      echo "Cannot read the build number from release tag $tag" >&2
      return 1
    }
    [[ "$build" =~ ^[1-9][0-9]*$ ]] || {
      echo "Invalid build number in release tag $tag: $build" >&2
      return 1
    }
    if [ "$build" -gt "$highest" ]; then highest="$build"; fi
  done < <(git tag -l 'v*')
  printf '%s\n' "$highest"
}

next_release_build() {
  local current highest
  current="$(read_build)"
  [[ "$current" =~ ^[1-9][0-9]*$ ]] || {
    echo "Invalid CURRENT_PROJECT_VERSION: $current" >&2
    return 1
  }
  highest="$(highest_release_build)" || return 1
  if [ "$current" -gt "$highest" ]; then highest="$current"; fi
  printf '%s\n' "$((highest + 1))"
}

if [ "${1:-}" = "--bump-build" ]; then
  old_build="$(read_build)"
  new_build="$(next_release_build)"
  set_build "$new_build"
  echo "project.yml: build $old_build → $new_build (sürüm $(read_marketing) değişmedi)"
  echo ""
  echo "Bunu yalnız sürüm değişmeden yeniden yayınlarken yap. Sıradaki adımlar:"
  echo "  1. xcodegen generate"
  echo "  2. commit"
  exit 0
fi

# --set: project.yml'yi yerinde güncelle. Build numarası hiç sıfırlanmaz —
# Sparkle'ın karşılaştırdığı sayı odur, geri giderse güncelleme görünmez olur.
if [ "${1:-}" = "--set" ]; then
  new="${2:-}"
  if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "kullanım: scripts/version.sh --set <major.minor.patch>" >&2
    exit 2
  fi
  old_marketing="$(read_marketing)"
  old_build="$(read_build)"
  new_build="$(next_release_build)"
  /usr/bin/sed -i '' -e "s/^\([[:space:]]*MARKETING_VERSION:\) .*/\1 \"$new\"/" project.yml
  set_build "$new_build"
  echo "project.yml: $old_marketing (build $old_build) → $new (build $new_build)"
  echo ""
  echo "Sıradaki adımlar (hiçbiri otomatik yapılmadı):"
  echo "  1. CHANGELOG.md: 'Unreleased' bölümünü '## [$new] - $(date +%Y-%m-%d)' olarak kes"
  echo "  2. xcodegen generate"
  echo "  3. commit, sonra: git tag -a v$new -m \"Uncoil $new\""
  exit 0
fi

MARKETING="$(read_marketing)"
BUILD="$(read_build)"
CHANGELOG_VERSION="$(grep -m1 -E '^## \[' CHANGELOG.md | sed 's/^## \[\([^]]*\)\].*/\1/' || true)"
LAST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"

# 'Unreleased' başlığı ile bir sonraki '## ' başlığı arasında içerik var mı?
UNRELEASED_LINES="$(awk '/^## Unreleased/{f=1;next} /^## /{f=0} f && NF' CHANGELOG.md | wc -l | tr -d ' ')"

printf '\n'
LAST_RELEASED_BUILD=""
[ -n "$LAST_TAG" ] && LAST_RELEASED_BUILD="$(build_at_tag "$LAST_TAG")"

printf '  project.yml sürüm     : %s (build %s)\n' "$MARKETING" "$BUILD"
printf '  son tag'\''deki build    : %s\n' "${LAST_RELEASED_BUILD:-bilinmiyor}"
printf '  CHANGELOG son sürüm   : %s\n' "${CHANGELOG_VERSION:-yok}"
printf '  son git tag           : %s\n' "${LAST_TAG:-yok}"
printf '  Unreleased'\''da bekleyen: %s satır\n' "$UNRELEASED_LINES"
printf '\n'

problems=0
note() { printf '  %s\n' "$1"; }

if [ "$MARKETING" = "$CHANGELOG_VERSION" ]; then
  note "✓ project.yml ile CHANGELOG aynı sürümü söylüyor"
else
  note "✗ project.yml $MARKETING diyor, CHANGELOG ${CHANGELOG_VERSION:-hiçbir şey}"
  note "  düzelt: CHANGELOG'a '## [$MARKETING] - $(date +%Y-%m-%d)' bölümü aç"
  problems=$((problems + 1))
fi

if [ -z "$LAST_TAG" ]; then
  note "✗ hiç sürüm tag'i yok"
  problems=$((problems + 1))
elif [ "$LAST_TAG" = "v$MARKETING" ]; then
  if [ "$(git rev-parse "$LAST_TAG^{commit}")" = "$(git rev-parse HEAD)" ]; then
    note "✓ $LAST_TAG tam olarak HEAD'i gösteriyor"
  else
    behind="$(git rev-list --count "$LAST_TAG..HEAD")"
    note "! $LAST_TAG, HEAD'in $behind commit gerisinde — sürümden sonra iş yapılmış"
    note "  bu normal: bir sonraki sürümü kesene kadar böyle kalır"
  fi
else
  note "✗ son tag $LAST_TAG ama project.yml $MARKETING diyor"
  problems=$((problems + 1))
fi

# Build numarası asla geri gitmez ve yayınlanmış bir sayı ikinci kez
# kullanılmaz: ikisi de yüklü kopyaların güncellemeyi görmemesi demek.
if [ -z "$LAST_RELEASED_BUILD" ]; then
  note "! son tag'de build numarası okunamadı — karşılaştırma yapılamıyor"
elif [ "$BUILD" -lt "$LAST_RELEASED_BUILD" ]; then
  note "✗ build $BUILD, yayınlanmış $LAST_RELEASED_BUILD'in gerisinde"
  note "  yüklü kopyalar bu sürümü hiç görmez — düzelt: scripts/version.sh --bump-build"
  problems=$((problems + 1))
elif [ "$BUILD" -eq "$LAST_RELEASED_BUILD" ] && [ "$MARKETING" != "${LAST_TAG#v}" ]; then
  note "✗ sürüm $MARKETING'e çıkmış ama build hâlâ $BUILD — $LAST_TAG ile aynı"
  note "  düzelt: scripts/version.sh --bump-build"
  problems=$((problems + 1))
elif [ "$BUILD" -eq "$LAST_RELEASED_BUILD" ]; then
  note "✓ build $BUILD — $LAST_TAG olarak yayınlanan sayı; yeniden yayınlarken artır"
else
  note "✓ build $BUILD, yayınlanmış $LAST_RELEASED_BUILD'in ilerisinde"
fi

if [ "$UNRELEASED_LINES" -eq 0 ]; then
  note "✓ Unreleased boş — kesilmemiş iş yok"
else
  note "! Unreleased'da $UNRELEASED_LINES satır var, henüz sürümlenmedi"
fi

printf '\n'
if [ "$problems" -eq 0 ]; then
  echo "  Tutarlı."
else
  echo "  $problems tutarsızlık var." >&2
  exit 1
fi
