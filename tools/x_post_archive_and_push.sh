#!/usr/bin/env bash
set -euo pipefail

# Archive X/Twitter post(s) into this repo and push to GitHub.
# Usage:
#   ./tools/x_post_archive_and_push.sh url <X_URL>
#   ./tools/x_post_archive_and_push.sh batch <URL_FILE>
# Options (pass-through to download.sh): e.g. --resume --no-images --timeout 12

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$HOME/.openclaw/skills/x-post-archiver"
DL_SH="$SKILL_DIR/scripts/download.sh"
OUT_BASE="$REPO_DIR/x-post-archives"

mode="${1:-}"
shift || true

if [[ ! -x "$DL_SH" && ! -f "$DL_SH" ]]; then
  echo "ERROR: download script not found: $DL_SH" >&2
  exit 1
fi

mkdir -p "$OUT_BASE"

assemble_md() {
  local dir="$1"
  local url="${2:-}"
  local out="$dir/article.md"

  python3 - <<'PY'
import json, os
from datetime import datetime

dir = os.environ['DIR']
url = os.environ.get('URL','')
meta_path = os.path.join(dir, '.meta.json')
snap_path = os.path.join(dir, '.snapshot.txt')
images_path = os.path.join(dir, '.images.json')

meta = {}
if os.path.exists(meta_path):
  try:
    meta = json.load(open(meta_path,'r',encoding='utf-8'))
  except Exception:
    meta = {}

author_name = meta.get('author_name','unknown')
author_url = meta.get('author_url','')
title = meta.get('title') or meta.get('provider_name') or 'X Post'

imgs = []
if os.path.exists(images_path):
  try:
    imgs = json.load(open(images_path,'r',encoding='utf-8'))
  except Exception:
    imgs = []

snapshot = ''
if os.path.exists(snap_path):
  snapshot = open(snap_path,'r',encoding='utf-8',errors='replace').read().strip()

lines = []
lines.append(f"# {title}")
lines.append("")
lines.append(f"> **Author**: {author_name}" + (f" ([link]({author_url}))" if author_url else ""))
if url:
  lines.append(f"> **Original**: [{url}]({url})")
lines.append(f"> **Archived at**: {datetime.utcnow().isoformat(timespec='seconds')}Z")
lines.append("")
lines.append("---")
lines.append("")

if imgs:
  lines.append("## Media")
  lines.append("")
  for i, im in enumerate(imgs, start=1):
    local = im.get('local')
    alt = (im.get('alt') or '').strip() or f"image {i}"
    if local:
      lines.append(f"![{alt}](media/{local})")
  lines.append("")
  lines.append("---")
  lines.append("")

lines.append("## Snapshot (raw)")
lines.append("")
lines.append("```text")
lines.append(snapshot)
lines.append("```")
lines.append("")

out_path = os.path.join(dir, 'article.md')
with open(out_path,'w',encoding='utf-8') as f:
  f.write("\n".join(lines))
print(out_path)
PY
}

case "$mode" in
  url)
    url="$1"; shift || true
    tweet_id=$(python3 -c "import re,sys; m=re.search(r'/status/(\d+)', sys.argv[1]); print(m.group(1) if m else 'unknown')" "$url")
    out_dir="$OUT_BASE/$tweet_id"
    bash "$DL_SH" download "$url" "$out_dir" "$@"
    DIR="$out_dir" URL="$url" assemble_md "$out_dir" "$url" >/dev/null
    ;;

  batch)
    url_file="$1"; shift || true
    bash "$DL_SH" batch "$url_file" "$OUT_BASE" "$@"
    # Assemble article.md for any dirs that have a snapshot
    for d in "$OUT_BASE"/*; do
      [[ -d "$d" && -f "$d/.snapshot.txt" ]] || continue
      [[ -f "$d/article.md" ]] && continue
      DIR="$d" assemble_md "$d" >/dev/null || true
    done
    ;;

  *)
    echo "Usage: $0 url <X_URL> [download.sh options...]" >&2
    echo "       $0 batch <URL_FILE> [download.sh options...]" >&2
    exit 2
    ;;
esac

cd "$REPO_DIR"

git add -A
if git diff --cached --quiet; then
  echo "No changes to commit."
  exit 0
fi

msg="x-post-archiver: archive $(date '+%Y-%m-%d %H:%M:%S')"
git commit -m "$msg"
git push

echo "Done: committed and pushed."
