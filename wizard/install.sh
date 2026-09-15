#!/usr/bin/env bash
# =====================================================================
#  Red Panel Wizard — CLI Edition
#  نصب / به‌روزرسانی خودکار رد پنل روی Cloudflare از ترمینال
#
#  اجرا:
#    bash <(curl -fsSL https://raw.githubusercontent.com/redcorexx/Red-Panel/main/wizard/install.sh)
#
#  - چندحسابی (ورودها روی سیستم شما ذخیره می‌شود، نه هیچ‌جای دیگر)
#  - پشتیبانی از Workers و Pages
# =====================================================================
set -u
CF_API="https://api.cloudflare.com/client/v4"
REPO="redcorexx/Red-Panel"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/redpanel-wizard"
CFG_FILE="$CFG_DIR/accounts.json"
PANELS_FILE="$CFG_DIR/panels.json"

# ---------- colors ----------
if [ -t 1 ]; then B='\033[1m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; NC='\033[0m'; else B=;R=;G=;Y=;C=;NC=; fi
say(){ printf "%b\n" "$1"; }
die(){ say "${R}✕ $1${NC}"; exit 1; }
ok(){ say "${G}✓ $1${NC}"; }

command -v curl >/dev/null || die "curl not found"
command -v python3 >/dev/null || die "python3 not found (needed for JSON handling)"

mkdir -p "$CFG_DIR"
[ -f "$CFG_FILE" ] || echo '[]' > "$CFG_FILE"
[ -f "$PANELS_FILE" ] || echo '[]' > "$PANELS_FILE"
chmod 600 "$CFG_FILE" 2>/dev/null

# ---------- helpers ----------
jget(){ python3 -c "
import json,sys
try: data=json.load(open(sys.argv[1]))
except Exception: data=[]
print(data if isinstance(data,str) else json.dumps(data))
" "$1" 2>/dev/null; }

cf(){ # cf METHOD PATH [JSON_BODY]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$CF_API$path" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "$body"
  else
    curl -sS -X "$method" "$CF_API$path" -H "Authorization: Bearer $TOKEN"
  fi
}

rand_name(){ echo "red-panel-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
rand_pass(){ python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(12)))"; }

b64url_enc(){ python3 -c "
import base64,json,sys
print(base64.urlsafe_b64encode(json.dumps(json.loads(sys.argv[1])).encode()).decode().rstrip('='))
" "$1"; }

banner(){
  clear 2>/dev/null || true
  say "${C}┌───────────────────────────────────────────────┐${NC}"
  say "${C}│${NC}   ${B}🗞  RED PANEL WIZARD — CLI Edition${NC}          ${C}│${NC}"
  say "${C}│${NC}   newspaper edition · $(date '+%Y-%m-%d')            ${C}│${NC}"
  say "${C}└───────────────────────────────────────────────┘${NC}"
}

# ---------- login ----------
login(){
  say "\n${B}توکن API کلودفلر${NC} را وارد کنید (دسترسی‌ها: Account Settings Read · Workers Scripts Edit · D1 Edit · Pages Edit)"
  say "${C}→ https://dash.cloudflare.com/profile/api-tokens/create${NC}"
  read -r -s -p "Token: " TOKEN; echo
  [ -n "$TOKEN" ] || die "empty token"
  say "${Y}… بررسی توکن${NC}"
  local v a
  v=$(cf GET /user/tokens/verify)
  echo "$v" | grep -q '"status":"active"' || die "توکن معتبر نیست: $(echo "$v" | head -c 200)"
  a=$(cf GET "/accounts?per_page=50")
  echo "$a" | grep -q '"success":true' || die "حسابی پیدا نشد (Account Settings: Read)"
  ACCOUNTS_JSON=$(echo "$a" | python3 -c "import json,sys;print(json.dumps([{'id':x['id'],'name':x['name']} for x in json.load(sys.stdin)['result']]))")
  # store
  python3 - "$CFG_FILE" "$TOKEN" "$ACCOUNTS_JSON" <<'PY'
import json,sys
path, token, accs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
data = json.load(open(path))
for ex in data:
    if ex['token'] == token:
        ex['accounts'] = accs; break
else:
    data.append({'token': token, 'accounts': accs})
json.dump(data, open(path,'w'), indent=1)
PY
  ok "توکن ذخیره شد ($(echo "$ACCOUNTS_JSON" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))') حساب)"
}

choose_login(){
  local n
  n=$(python3 -c "import json;print(len(json.load(open('$CFG_FILE'))))")
  if [ "$n" -ge 1 ]; then
    say "\n${B}حساب‌های ذخیره‌شده:${NC}"
    python3 -c "
import json
d=json.load(open('$CFG_FILE'))
for i,l in enumerate(d):
    print(f\"  {i+1}) {l['accounts'][0]['name'] if l['accounts'] else '?'} ({len(l['accounts'])} account)\")
print('  N) ورود با توکن جدید')
"
    read -r -p "انتخاب [1]: " sel; sel="${sel:-1}"
    if [ "$sel" = "N" ] || [ "$sel" = "n" ]; then login; else
      TOKEN=$(python3 -c "import json;print(json.load(open('$CFG_FILE'))[$((sel-1))]['token'])")
      ACCOUNTS_JSON=$(python3 -c "import json;print(json.dumps(json.load(open('$CFG_FILE'))[$((sel-1))]['accounts']))")
    fi
  else
    login
  fi
  # choose account if several
  local na
  na=$(echo "$ACCOUNTS_JSON" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')
  if [ "$na" -gt 1 ]; then
    echo "$ACCOUNTS_JSON" | python3 -c "
import json,sys
for i,a in enumerate(json.load(sys.stdin)): print(f\"  {i+1}) {a['name']}\")
"
    read -r -p "حساب [1]: " asel; asel="${asel:-1}"
  else asel=1; fi
  ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)[$((asel-1))]['id'])")
  ACCOUNT_NAME=$(echo "$ACCOUNTS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)[$((asel-1))]['name'])")
  ok "حساب فعال: $ACCOUNT_NAME"
}

# ---------- fetch code ----------
fetch_code(){
  say "${Y}… دریافت کد رد پنل${NC}"
  CODE_FILE="$(mktemp)"
  curl -sS -f "https://cdn.jsdelivr.net/gh/$REPO@main/_worker.js" -o "$CODE_FILE" ||
  curl -sS -f "https://raw.githubusercontent.com/$REPO/refs/heads/main/_worker.js" -o "$CODE_FILE" || die "دریافت کد ناموفق"
  [ "$(wc -c < "$CODE_FILE")" -gt 5000 ] || die "کد دریافتی نامعتبر است"
  VERSION=$(grep -o 'const CURRENT_VERSION *= *"[^"]*"' "$CODE_FILE" | head -1 | grep -o '[0-9][0-9.]*' | head -1)
  ok "کد v${VERSION:-?} دریافت شد"
}

# ---------- D1 ----------
create_d1(){
  local name="$1" out id msg
  say "${Y}… ساخت D1: ${name}-db${NC}"
  out=$(cf POST "/accounts/$ACCOUNT_ID/d1/database" "{\"name\":\"${name}-db\"}")
  id=$(echo "$out" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['result'].get('uuid') or d['result'].get('database_id'))" 2>/dev/null || true)
  if [ -z "$id" ]; then
    if echo "$out" | grep -qi "already"; then
      id=$(cf GET "/accounts/$ACCOUNT_ID/d1/database" | python3 -c "
import json,sys
d=json.load(sys.stdin)
m=[x['uuid'] for x in d.get('result',[]) if x['name']=='$name-db']
print(m[0] if m else '')
")
    fi
  fi
  [ -n "$id" ] || die "ساخت D1 ناموفق: $(echo "$out" | head -c 200)"
  DB_ID="$id"; ok "D1 آماده: ${id:0:8}…"
}

# ---------- inject ----------
inject_code(){
  local name="$1" password="$2"
  python3 - "$CODE_FILE" "$name" "$password" "$ACCOUNT_ID" "$TOKEN" <<'PY'
import re, sys
path, name, password, acc, token = sys.argv[1:6]
code = open(path, encoding='utf-8').read()
def setf(k, v):
    global code
    code = re.sub(r'(%s\s*:\s*)"[^"]*"' % k, lambda m: m.group(1) + '"%s"' % v.replace('"',''), code)
setf('masterKey', password); setf('cfWorkerName', name)
setf('cfAccountId', acc); setf('cfApiToken', token)
open(path, 'w', encoding='utf-8').write(code)
PY
}

# ---------- deploy workers ----------
deploy_workers(){
  local name="$1"
  say "${Y}… استقرار روی Workers${NC}"
  local meta out
  meta=$(python3 -c "import json,sys;print(json.dumps({'main_module':'worker.js','compatibility_date':'2024-09-22','compatibility_flags':['nodejs_compat'],'bindings':[{'name':'IOT_DB','type':'d1','id':sys.argv[1]}]}))" "$DB_ID")
  echo "$meta" > /tmp/rp-meta.json
  out=$(curl -sS -X PUT "$CF_API/accounts/$ACCOUNT_ID/workers/scripts/$name" \
      -H "Authorization: Bearer $TOKEN" \
      -F "metadata=@/tmp/rp-meta.json;type=application/json" \
      -F "worker.js=@$CODE_FILE;type=application/javascript+module")
  echo "$out" | grep -q '"success":true' || die "استقرار ناموفق: $(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["errors"][0]["message"][:300])' 2>/dev/null || echo "$out" | head -c 200)"
  ok "ورکر مستقر شد: $name"
}

# ---------- deploy pages ----------
deploy_pages(){
  local name="$1" out
  say "${Y}… استقرار روی Pages${NC}"
  cf POST "/accounts/$ACCOUNT_ID/pages/projects" "{\"name\":\"$name\",\"production_branch\":\"main\"}" > /dev/null
  out=$(curl -sS -X POST "$CF_API/accounts/$ACCOUNT_ID/pages/projects/$name/deployments" \
      -H "Authorization: Bearer $TOKEN" \
      -F "branch=main" \
      -F "files[/_worker.js]=@$CODE_FILE;type=application/javascript+module")
  echo "$out" | grep -q '"success":true' || die "استقرار Pages ناموفق: $(echo "$out" | head -c 250)"
  DEPLOY_URL=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['result'].get('url',''))" 2>/dev/null)
  ok "Pages مستقر شد: ${DEPLOY_URL:-$name.pages.dev}"
}

# ---------- url ----------
get_url(){
  local name="$1" sub
  sub=$(cf GET "/accounts/$ACCOUNT_ID/workers/subdomain" | python3 -c "import json,sys;print(json.load(sys.stdin).get('result',{}).get('subdomain',''))" 2>/dev/null)
  [ -n "$sub" ] || die "ساب‌دامین workers.dev فعال نیست"
  DEPLOY_URL="https://$name.$sub.workers.dev"
}

save_panel(){
  python3 - "$PANELS_FILE" "$1" "$2" "$3" <<'PY'
import json, sys
path, name, url, method = sys.argv[1:5]
data = json.load(open(path))
data = [p for p in data if p['name'] != name]
data.insert(0, {'name': name, 'url': url, 'method': method})
json.dump(data[:10], open(path, 'w'), indent=1)
PY
}

# ---------- install ----------
do_install(){
  choose_login
  say "\nروش نصب؟  ${B}1)${NC} Workers   ${B}2)${NC} Pages"
  read -r -p "انتخاب [1]: " msel; msel="${msel:-1}"
  local method=workers; [ "$msel" = "2" ] && method=pages
  local name password
  name=$(rand_name); password=$(rand_pass)
  say "نام ورکر: ${B}$name${NC} · رمز پنل: ${B}$password${NC}"
  fetch_code
  create_d1 "$name"
  inject_code "$name" "$password"
  if [ "$method" = "workers" ]; then
    deploy_workers "$name"; get_url "$name"
  else
    deploy_pages "$name"; DEPLOY_URL="${DEPLOY_URL:-https://$name.pages.dev}"
  fi
  save_panel "$name" "$DEPLOY_URL" "$method"
  local priv
  priv=$(b64url_enc "{\"a\":\"$ACCOUNT_ID\",\"m\":\"$method\",\"w\":\"$name\",\"pw\":\"$password\",\"t\":\"$TOKEN\"}")
  banner
  say "\n${G}╔══════════════════════════════════════════════╗${NC}"
  say "${G}║          🎉  پنل شما آماده است!             ║${NC}"
  say "${G}╚══════════════════════════════════════════════╝${NC}"
  say " داشبورد : ${C}$DEPLOY_URL/sync/dash${NC}"
  say " رمز     : ${B}$password${NC}"
  say " نسخه    : v${VERSION:-?}"
  say "\n لینک خصوصی (نصب یک‌کلیک وب):"
  say " ${Y}https://redcorexx.github.io/Red-Panel/#p=$priv${NC}"
  say "\n ${B}این اطلاعات را نگه دارید.${NC}\n"
}

# ---------- update ----------
do_update(){
  choose_login
  say "\nنام ورکر موجود برای به‌روزرسانی:"
  python3 -c "
import json
d=json.load(open('$PANELS_FILE'))
for i,p in enumerate(d): print(f\"  {i+1}) {p['name']}  ({p['method']})\")" 2>/dev/null
  read -r -p "نام یا شماره: " sel
  local name method
  if echo "$sel" | grep -q '^[0-9]*$'; then
    name=$(python3 -c "import json;print(json.load(open('$PANELS_FILE'))[$((sel-1))]['name'])")
    method=$(python3 -c "import json;print(json.load(open('$PANELS_FILE'))[$((sel-1))]['method'])")
  else name="$sel"; method=workers; fi
  fetch_code
  say "${Y}… بازیابی اتصال‌های موجود${NC}"
  local bindings
  bindings=$(cf GET "/accounts/$ACCOUNT_ID/workers/scripts/$name/settings" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=d.get('result',{}).get('bindings',[])
print(json.dumps(b) if any(x.get('type')=='d1' for x in b) else '')" 2>/dev/null)
  if [ "$method" = "pages" ]; then
    deploy_pages "$name"
  else
    [ -n "$bindings" ] || die "اتصال D1 پیدا نشد؛ نام ورکر را بررسی کنید"
    DB_ID=$(echo "$bindings" | python3 -c "import json,sys;print([x['id'] for x in json.load(sys.stdin) if x['type']=='d1'][0])")
    deploy_workers "$name"
  fi
  banner
  ok "به‌روزرسانی کامل شد: $name"
}

# ---------- menu ----------
while true; do
  banner
  say "\n ${B}1)${NC} 🚀 نصب پنل جدید"
  say " ${B}2)${NC} 🔄 به‌روزرسانی پنل موجود"
  say " ${B}3)${NC} 📋 پنل‌های ذخیره‌شده"
  say " ${B}4)${NC} 🔑 افزودن حساب جدید"
  say " ${B}0)${NC} خروج"
  read -r -p "انتخاب: " ch
  case "$ch" in
    1) do_install ;;
    2) do_update ;;
    3) say "\n${B}پنل‌های ذخیره‌شده:${NC}"; python3 -c "
import json
d=json.load(open('$PANELS_FILE'))
if not d: print('  (خالی)')
for p in d: print(f\"  • {p['name']}  [{p['method']}]  {p['url']}/sync/dash\")" ;;
    4) login ;;
    0|q|exit) say "خداحافظ 👋"; exit 0 ;;
  esac
  read -r -p "ادامه با Enter…" _
done
