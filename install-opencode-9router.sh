#!/usr/bin/env bash
# Install OpenCode + otomatis integrasi ke 9router
# Semua data (URL, API key, nama provider, model) DITANYA saat script dijalankan,
# tidak ada yang di-hardcode, jadi gampang dipakai di server/PC mana pun.
#
# Pemakaian:
#   bash install-opencode-9router.sh
#
# Opsional: lewati pertanyaan lewat env var
#   NR_BASE_URL    Base URL 9router (akhiran /v1 ditambahkan otomatis)
#   NR_API_KEY     API key 9router
#   NR_PROVIDER    Nama provider di OpenCode (default: 9router)
#   NR_MODEL       Model default (contoh: ds/deepseek-v4.1-flash)
#   NR_SKILLS      y / n  (install skill 9router atau tidak)
#   NR_SKILLS_URL  Sumber skill (default: repo decolua/9router di GitHub)

set -euo pipefail

BASE_URL="${NR_BASE_URL:-}"
API_KEY="${NR_API_KEY:-}"
PROVIDER="${NR_PROVIDER:-}"
MODEL="${NR_MODEL:-}"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "curl belum terinstal."
if command -v python3 >/dev/null 2>&1; then PY=python3
elif command -v python >/dev/null 2>&1; then PY=python
else die "python belum terinstal (dipakai untuk menulis config JSON)."; fi

# ---------- 1. Pertanyaan ----------
while [ -z "$BASE_URL" ]; do
  read -rp "Base URL 9router (contoh: https://domain-kamu/v1): " BASE_URL
done
BASE_URL="${BASE_URL%/}"
case "$BASE_URL" in
  */v1) ;;
  *) warn "Base URL tidak berakhiran /v1, otomatis ditambahkan."; BASE_URL="$BASE_URL/v1" ;;
esac

while [ -z "$API_KEY" ]; do
  read -rp "API key 9router: " API_KEY
done

if [ -z "$PROVIDER" ]; then
  read -rp "Nama provider di OpenCode [9router]: " PROVIDER
fi
PROVIDER="$(printf '%s' "${PROVIDER:-9router}" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-')"

# ---------- 2. Install OpenCode ----------
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
if command -v opencode >/dev/null 2>&1; then
  ok "OpenCode sudah terinstal: $(opencode --version 2>/dev/null || echo 'versi tidak diketahui')"
else
  log "Menginstal OpenCode..."
  if curl -fsSL https://opencode.ai/install | bash; then
    export PATH="$HOME/.opencode/bin:$HOME/.local/bin:$PATH"
  elif command -v npm >/dev/null 2>&1; then
    warn "Install script gagal, mencoba lewat npm..."
    npm install -g opencode-ai
  else
    die "Gagal menginstal OpenCode. Coba manual: https://opencode.ai/docs"
  fi
  command -v opencode >/dev/null 2>&1 || die "opencode tidak ditemukan di PATH setelah install. Buka terminal baru lalu jalankan ulang."
  ok "OpenCode terinstal: $(opencode --version 2>/dev/null || true)"
fi

# ---------- 2b. Windows (Git Bash): tambahkan OpenCode ke PATH permanen ----------
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v powershell.exe >/dev/null 2>&1; then
      PATH_RESULT="$(powershell.exe -NoProfile -Command '$d = Join-Path $env:USERPROFILE ".opencode\bin"; $p = [Environment]::GetEnvironmentVariable("Path","User"); if (-not $p) { $p = "" }; if (($p -split ";") -notcontains $d) { [Environment]::SetEnvironmentVariable("Path", ($p.TrimEnd(";") + ";" + $d).TrimStart(";"), "User"); "ADDED" } else { "EXISTS" }' 2>/dev/null | tr -d '\r' || true)"
      case "$PATH_RESULT" in
        ADDED)  ok "OpenCode ditambahkan ke PATH Windows. Buka CMD baru, lalu cukup ketik: opencode" ;;
        EXISTS) ok "PATH Windows sudah berisi OpenCode." ;;
        *)      warn "Gagal mengatur PATH Windows otomatis. Tambahkan manual: %USERPROFILE%\\.opencode\\bin" ;;
      esac
    fi
    ;;
esac

# ---------- 3. Ambil daftar model & pilih default ----------
log "Mengambil daftar model dari $BASE_URL ..."
MODELS_RAW="$(NR_BASE="$BASE_URL" NR_KEY="$API_KEY" "$PY" - <<'PY' | tr -d '\r'
import json, os, sys, urllib.request
base, key = os.environ["NR_BASE"], os.environ["NR_KEY"]
try:
    req = urllib.request.Request(base + "/models", headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (compatible; opencode-installer)"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    for m in data.get("data", []):
        print(m["id"])
except Exception as e:
    print(f"[!] Tidak bisa ambil daftar model ({e}). Cek Base URL, API key, dan pastikan 9router jalan.", file=sys.stderr)
PY
)"

MODEL_IDS=()
while IFS= read -r line; do
  line="${line%$'\r'}"
  if [ -n "$line" ]; then MODEL_IDS+=("$line"); fi
done <<EOF_IDS
$MODELS_RAW
EOF_IDS

if [ -z "$MODEL" ]; then
  if [ "${#MODEL_IDS[@]}" -gt 0 ]; then
    ok "${#MODEL_IDS[@]} model ditemukan (semuanya didaftarkan ke OpenCode)."
    while :; do
      echo
      read -rp "Cari model default (kata kunci, mis. deepseek / qwen; Enter = model pertama): " KW
      if [ -z "$KW" ]; then MODEL="${MODEL_IDS[0]}"; break; fi
      MATCHES=()
      while IFS= read -r line; do
        line="${line%$'\r'}"
        if [ -n "$line" ]; then MATCHES+=("$line"); fi
      done <<EOF_M
$(printf '%s\n' "$MODELS_RAW" | grep -iF -- "$KW" || true)
EOF_M
      if [ "${#MATCHES[@]}" -eq 0 ]; then warn "Tidak ada model yang cocok dengan '$KW'."; continue; fi
      SHOW="${#MATCHES[@]}"
      if [ "$SHOW" -gt 30 ]; then SHOW=30; fi
      i=0
      while [ "$i" -lt "$SHOW" ]; do
        printf '  %d) %s\n' "$((i + 1))" "${MATCHES[$i]}"
        i=$((i + 1))
      done
      if [ "${#MATCHES[@]}" -gt 30 ]; then echo "  ... dan $(( ${#MATCHES[@]} - 30 )) lainnya (persempit kata kunci)"; fi
      read -rp "Pilih nomor (Enter = cari lagi): " PICK
      case "$PICK" in
        ''|*[!0-9]*) continue ;;
      esac
      if [ "$PICK" -ge 1 ] && [ "$PICK" -le "$SHOW" ]; then MODEL="${MATCHES[$((PICK - 1))]}"; break; fi
      warn "Nomor tidak valid."
    done
  else
    while [ -z "$MODEL" ]; do
      read -rp "Daftar model kosong. Ketik nama model default (contoh: ds/deepseek-v4.1-flash): " MODEL
    done
  fi
fi
ok "Model default: $PROVIDER/$MODEL"

# ---------- 4. Tulis config ----------
CONFIG_DIR="$HOME/.config/opencode"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
mkdir -p "$CONFIG_DIR"

if [ -f "$CONFIG_FILE" ]; then
  BACKUP="$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_FILE" "$BACKUP"
  ok "Config lama dibackup ke $BACKUP"
fi

NR_BASE="$BASE_URL" NR_KEY="$API_KEY" NR_PROVIDER="$PROVIDER" NR_MODEL_SEL="$MODEL" NR_CFG="$CONFIG_FILE" "$PY" - <<'PY'
import json, os, sys, urllib.request

base, key = os.environ["NR_BASE"], os.environ["NR_KEY"]
prov  = os.environ["NR_PROVIDER"]
model = os.environ.get("NR_MODEL_SEL", "").strip()
path  = os.environ["NR_CFG"]

models = {}
try:
    req = urllib.request.Request(base + "/models", headers={
        "Authorization": "Bearer " + key,
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (compatible; opencode-installer)"})
    with urllib.request.urlopen(req, timeout=15) as r:
        data = json.load(r)
    for m in data.get("data", []):
        models[m["id"]] = {"name": m["id"]}
except Exception as e:
    print(f"    [!] Gagal ambil daftar model ({e}); hanya model default yang didaftarkan.", file=sys.stderr)

if model:
    models.setdefault(model, {"name": model})
if not models:
    sys.exit("Tidak ada model untuk didaftarkan.")

cfg = {}
if os.path.exists(path):
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception:
        sys.exit(f"Config lama ({path}) bukan JSON murni (mungkin ada komentar). Rapikan manual atau hapus, lalu jalankan ulang.")

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("provider", {})[prov] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": prov,
    "options": {"baseURL": base, "apiKey": key},
    "models": models,
}
cfg["model"] = prov + "/" + (model or next(iter(models)))

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
try:
    os.chmod(path, 0o600)
except Exception:
    pass
print(f"    {len(models)} model didaftarkan.")
PY
ok "Config tersimpan di $CONFIG_FILE"

# ---------- 5. Skill 9router (opsional) ----------
INSTALL_SKILLS="${NR_SKILLS:-}"
if [ -z "$INSTALL_SKILLS" ]; then
  read -rp "Install skill 9router (chat, image, tts, stt, embeddings, web search, web fetch)? [Y/n]: " INSTALL_SKILLS
fi

case "${INSTALL_SKILLS:-Y}" in
  [nN]*) log "Skip install skill." ;;
  *)
    SKILL_RAW="${NR_SKILLS_URL:-https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills}"
    SKILL_DIR="$CONFIG_DIR/skills"
    SKILLS="9router 9router-chat 9router-image 9router-tts 9router-stt 9router-embeddings 9router-web-search 9router-web-fetch"
    OK_COUNT=0
    for s in $SKILLS; do
      mkdir -p "$SKILL_DIR/$s"
      if curl -fsSL "$SKILL_RAW/$s/SKILL.md" -o "$SKILL_DIR/$s/SKILL.md"; then
        # samakan field "name" di frontmatter dengan nama folder (syarat OpenCode)
        "$PY" - "$SKILL_DIR/$s/SKILL.md" "$s" <<'PY'
import re, sys
p, name = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read()
if t.startswith("---"):
    end = t.find("\n---", 3)
    head, rest = t[:end], t[end:]
    if re.search(r"(?m)^name:", head):
        head = re.sub(r"(?m)^name:.*$", "name: " + name, head, count=1)
    else:
        head = head + "\nname: " + name
    t = head + rest
open(p, "w", encoding="utf-8").write(t)
PY
        printf '\n\n> Catatan: 9router di PC ini memakai Base URL %s (abaikan localhost jika berbeda). API key ada di ~/.config/opencode/opencode.json (provider %s).\n' "$BASE_URL" "$PROVIDER" >> "$SKILL_DIR/$s/SKILL.md"
        OK_COUNT=$((OK_COUNT + 1))
      else
        warn "Gagal mengunduh skill $s (dilewati)."
        rmdir "$SKILL_DIR/$s" 2>/dev/null || true
      fi
    done
    ok "$OK_COUNT skill terpasang di $SKILL_DIR"
    ;;
esac

# ---------- 6. Selesai ----------
cat <<EOF

Selesai! Cara pakai (di terminal baru):
  cd folder-proyek-kamu
  opencode
  /models   -> ganti model kapan saja

Pindah server? Jalankan script ini lagi dengan Base URL dan API key baru.
Pakai nama provider berbeda kalau mau menyimpan beberapa server sekaligus.
EOF
