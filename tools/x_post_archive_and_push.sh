#!/usr/bin/env bash
set -euo pipefail

# Archive X/Twitter post(s) into this repo and push to GitHub.
# Usage:
#   ./tools/x_post_archive_and_push.sh url <X_URL>
#   ./tools/x_post_archive_and_push.sh batch <URL_FILE>
# Options (pass-through to download.sh): e.g. --resume --no-images --timeout 12

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Prefer OpenClaw-optimized variant if present
SKILL_DIR="$HOME/.openclaw/skills/x-post-archiver-openclaw"
if [ ! -d "$SKILL_DIR" ]; then
  SKILL_DIR="$HOME/.openclaw/skills/x-post-archiver"
fi
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
import json, os, re
from datetime import datetime, UTC

DIR = os.environ['DIR']
URL = os.environ.get('URL','')
meta_path = os.path.join(DIR, '.meta.json')
snap_path = os.path.join(DIR, '.snapshot.txt')
images_path = os.path.join(DIR, '.images.json')

meta = {}
if os.path.exists(meta_path):
  try:
    meta = json.load(open(meta_path,'r',encoding='utf-8'))
  except Exception:
    meta = {}

author_name = meta.get('author_name','unknown')
author_url = meta.get('author_url','')

def load_images(p):
  if not os.path.exists(p):
    return []
  try:
    v = json.load(open(p,'r',encoding='utf-8'))
    if isinstance(v, str):
      v = json.loads(v)
    return v if isinstance(v, list) else []
  except Exception:
    return []

imgs = load_images(images_path)

snapshot = []
if os.path.exists(snap_path):
  snapshot = open(snap_path,'r',encoding='utf-8',errors='replace').read().splitlines()

# Prefer DOM-extracted title/content if present (x-post-archiver-openclaw)
content_p = os.path.join(DIR, '.content.json')
dom_title = ''
dom_text = ''
if os.path.exists(content_p):
  try:
    v = json.load(open(content_p,'r',encoding='utf-8'))
    if isinstance(v, str):
      v = json.loads(v)
    dom_title = (v.get('title') or '').strip()
    dom_text = (v.get('text') or '').strip()
  except Exception:
    pass

boiler = {
  "Don’t miss what’s happening People on X are the first to know.",
  "Don't miss what's happening People on X are the first to know.",
}

def guess_title(lines):
  author = (meta.get('author_name') or '').strip()
  for ln in lines:
    m = re.match(r"\s*-\s*text:\s*(.+)$", ln)
    if not m:
      continue
    t = m.group(1).strip().strip('"')
    if not t or t in boiler:
      continue
    if author and t == author:
      continue
    if len(t) > 140:
      continue
    if t.lower() in {"sign up", "log in", "new to x?", "trending now", "what’s happening", "what's happening", "article", "conversation"}:
      continue
    return t
  return meta.get('title') or meta.get('provider_name') or 'X Post'

snapshot_title = guess_title(snapshot)
title = (meta.get('title') or '').strip() or dom_title or snapshot_title

# Prefer DOM text; fallback to snapshot parsing.
paras = []
if dom_text:
  paras = [p.strip() for p in re.split(r"\n\s*\n", dom_text) if p.strip()]
else:
  def extract_body(lines):
    in_article = False
    base_indent = None
    out = []
    for ln in lines:
      if not in_article:
        if re.search(r"-\s*article\s+\"", ln):
          in_article = True
          base_indent = len(ln) - len(ln.lstrip(' '))
        continue

      indent = len(ln) - len(ln.lstrip(' '))
      if indent <= (base_indent or 0):
        break

      tm = re.match(r"\s*-\s*text:\s*(.+)$", ln)
      if tm:
        txt = tm.group(1).strip().strip('"')
        if txt and txt not in boiler:
          out.append(txt)
    cleaned = []
    for p in out:
      if cleaned and cleaned[-1] == p:
        continue
      cleaned.append(p)
    return cleaned

  paras = extract_body(snapshot)

md = []
md.append(f"# {title}")
md.append("")
md.append(f"> **Author**: {author_name}" + (f" ([@link]({author_url}))" if author_url else ""))
if URL:
  md.append(f"> **Original**: [{URL}]({URL})")
md.append(f"> **Archived at**: {datetime.now(UTC).isoformat(timespec='seconds')}")
md.append("")
md.append("---")
md.append("")

# Always include screenshot if present
if os.path.exists(os.path.join(DIR, 'media', 'full_page.png')):
  md.append("![](media/full_page.png)")
  md.append("")

if paras:
  md.append("## Content")
  md.append("")
  for p in paras:
    md.append(p)
    md.append("")
else:
  md.append("## Snapshot (raw)")
  md.append("")
  md.append("```text")
  md.append("\n".join(snapshot).strip())
  md.append("```")
  md.append("")

out_path = os.path.join(DIR, 'article.md')
with open(out_path,'w',encoding='utf-8') as f:
  f.write("\n".join(md))
print(out_path)
PY
}

case "$mode" in
  url)
    url="$1"; shift || true
    tweet_id=$(python3 -c "import re,sys; m=re.search(r'/status/(\d+)', sys.argv[1]); print(m.group(1) if m else 'unknown')" "$url")
    tmp_dir="$OUT_BASE/$tweet_id"
    bash "$DL_SH" download "$url" "$tmp_dir" "$@"

    # Rename directory to article title (slug) when possible.
    # Prefer .content.json title (DOM), fallback to snapshot heuristic.
    new_name=$(python3 - "$tmp_dir" <<'PY'
import os,re,sys,json
base = sys.argv[1]

# Load meta for author (to avoid picking author as title)
meta_p=os.path.join(base,'.meta.json')
author=''
if os.path.exists(meta_p):
  try:
    author=json.load(open(meta_p,'r',encoding='utf-8')).get('author_name','').strip()
  except Exception:
    author=''

# Prefer DOM title
dom_title=''
cp=os.path.join(base,'.content.json')
if os.path.exists(cp):
  try:
    v=json.load(open(cp,'r',encoding='utf-8'))
    if isinstance(v,str):
      v=json.loads(v)
    dom_title=(v.get('title') or '').strip()
  except Exception:
    dom_title=''

snap=os.path.join(base,'.snapshot.txt')
lines=[]
if os.path.exists(snap):
  lines=open(snap,'r',encoding='utf-8',errors='replace').read().splitlines()

boiler=set([
  "Don’t miss what’s happening People on X are the first to know.",
  "Don't miss what's happening People on X are the first to know.",
])

def slugify(s):
  s=s.strip().strip('"')
  s=re.sub(r"\s+","-",s)
  s=re.sub(r"[^A-Za-z0-9\u4e00-\u9fff\-]+","",s)
  s=re.sub(r"-+","-",s).strip('-')
  return s[:80]

if dom_title and dom_title not in boiler and dom_title != author:
  print(slugify(dom_title))
  raise SystemExit

title=''
for ln in lines:
  m=re.match(r"\s*-\s*text:\s*(.+)$",ln)
  if not m: continue
  t=m.group(1).strip().strip('"')
  if not t or t in boiler: continue
  if author and t == author: continue
  if len(t)>140: continue
  if t.lower() in {"sign up","log in","new to x?","trending now","what’s happening","what's happening","article","conversation"}: continue
  title=t
  break
print(slugify(title) if title else '')
PY
)

    out_dir="$tmp_dir"
    if [ -n "$new_name" ]; then
      candidate="$OUT_BASE/$new_name"
      if [ "$candidate" != "$tmp_dir" ]; then
        if [ -e "$candidate" ]; then
          candidate="$OUT_BASE/${new_name}-${tweet_id}"
        fi
        mv "$tmp_dir" "$candidate"
        out_dir="$candidate"
      fi
    fi

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
