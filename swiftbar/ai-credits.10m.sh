#!/bin/bash
# <xbar.title>AI Credits</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.desc>Кредиты и лимиты: Claude, Dust, Meta Muse</xbar.desc>
# <xbar.author>alexzerg</xbar.author>
# <xbar.dependencies>curl jq python3</xbar.dependencies>
#
# Источники:
#   Claude — https://api.anthropic.com/api/oauth/usage    (OAuth из Keychain "Claude Code-credentials")
#   Dust   — https://dust.tt/api/w/{wId}/fair-use-credits    (enterprise: лимит AWU-кредитов)
#            https://dust.tt/api/w/{wId}/credits/my-usage     (seat/пул)
#            https://dust.tt/api/w/{wId}/credits/my-usage-analytics (помесячно/понедельно)
#   Muse   — muse.ai, Next.js server action fetchSubscriptionAction
#            (клиент: ~/.local/bin/ai-credits-muse-usage; запасной путь —
#             https://api.meta.ai/muse-code/key, device-code токен Muse Code CLI)

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

CACHE_DIR="${AI_CREDITS_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/ai-credits}"
CONFIG_FILE="${AI_CREDITS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/ai-credits/config.env}"
HELPER_DIR="${AI_CREDITS_HELPER_DIR:-$HOME/.local/bin}"
TTL="${AI_CREDITS_TTL:-600}"
DEBUG="${AI_CREDITS_DEBUG:-0}"

mkdir -p "$CACHE_DIR" 2>/dev/null
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"

LINES=""
add_line() { LINES="${LINES}${LINES:+
}$1"; }

# ---------------------------------------------------------------- утилиты

dbg() { [ "$DEBUG" = "1" ] && printf '[ai-credits] %s\n' "$*" >>"$CACHE_DIR/debug.log"; return 0; }

# Команда с таймаутом: чтение Keychain может вызвать GUI-запрос и зависнуть.
# Фоновый запуск использовать нельзя: security в фоне блокируется на tty.
run_to() {
  local secs="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@" 2>/dev/null
}

kc_get() { # service [account]
  local svc="$1" acct="${2:-}" out=""
  if [ -n "$acct" ]; then
    out=$(run_to 8 security find-generic-password -s "$svc" -a "$acct" -w 2>/dev/null)
    [ -z "$out" ] && out=$(run_to 8 security find-generic-password -s "$svc" -w 2>/dev/null)
  else
    out=$(run_to 8 security find-generic-password -s "$svc" -w 2>/dev/null)
  fi
  printf '%s' "$out"
}

http() { # method url [curl args...] -> HTTP_CODE / HTTP_BODY
  local method="$1" url="$2"; shift 2
  local out code body
  out=$(curl -sS --max-time 20 -X "$method" -w '\n%{http_code}' "$@" "$url" 2>/dev/null)
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  HTTP_CODE="$code"
  HTTP_BODY="$body"
  dbg "$method $url -> $code (${#body} байт)"
}

cache_put() { local f="$CACHE_DIR/$1.json"; printf '%s' "$2" >"$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null; }
cache_get() { cat "$CACHE_DIR/$1.json" 2>/dev/null; }
cache_age() { local f="$CACHE_DIR/$1.json"; [ -f "$f" ] || { echo 999999; return; }; echo $(( $(date +%s) - $(stat -f %m "$f" 2>/dev/null || echo 0) )); }
cache_fresh() { local age; age=$(cache_age "$1"); [ "$age" -lt "$2" ]; }

is_num() { case "${1:-}" in ''|*[!0-9.]*) return 1;; *) return 0;; esac; }
to_int() { local v="${1:-0}"; v="${v%%.*}"; is_num "$v" && printf '%s' "$v" || printf '0'; }

human_delta() { # секунды -> "3д 4ч" / "4ч 12м" / "12м"
  local s; s=$(to_int "${1:-0}")
  [ "$s" -lt 0 ] && { printf 'скоро'; return; }
  local d h m
  d=$(( s / 86400 )); s=$(( s % 86400 ))
  h=$(( s / 3600 ));  s=$(( s % 3600 ))
  m=$(( s / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%sд %sч' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%sч %sм' "$h" "$m"
  else printf '%sм' "$m"; fi
}

iso_epoch() {
  local iso="${1:-}" e=""
  [ -n "$iso" ] || return 1
  e=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
  e=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$iso" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
  e=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null) && { printf '%s' "$e"; return 0; }
  return 1
}

fmt_when() { # epoch -> "25 окт 08:00"
  local e="${1:-}"
  is_num "$e" || { printf '—'; return; }
  LC_ALL=ru_RU.UTF-8 date -r "$e" "+%d %b %H:%M" 2>/dev/null || printf '—'
}

fmt_money() { # minor_units exponent -> "89.29"
  local minor exp div=1 i
  minor=$(to_int "${1:-0}")
  exp=$(to_int "${2:-2}")
  for i in $(seq 1 "$exp"); do div=$(( div * 10 )); done
  printf '%d.%0*d' $(( minor / div )) "$exp" $(( minor % div ))
}

pct_of() { # 0..1 -> "45"
  printf '%s' "$1" | awk '{printf "%.0f", $1 * 100}'
}

# ---------------------------------------------------------------- Claude

claude_token() {
  local blob="" token=""
  blob=$(run_to 8 cat "$HOME/.claude/.credentials.json" 2>/dev/null)
  if [ -n "$blob" ]; then
    token=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  fi
  if [ -z "$token" ]; then
    blob=$(kc_get "Claude Code-credentials" "$(id -un)")
    token=$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -z "$token" ]; then
      case "$blob" in sk-ant-*) token="$blob";; esac
    fi
  fi
  printf '%s' "$token"
}

check_claude() {
  LINES=""
  local token code json
  token=$(claude_token)
  if [ -z "$token" ]; then
    CLAUDE_SHORT="Claude: нет токена"
    add_line "❌ Не найден OAuth-токен (Keychain «Claude Code-credentials»). Запустите \`claude\` — он обновит токен."
    CLAUDE_LINES="$LINES"
    return
  fi

  if cache_fresh claude "$TTL"; then
    json=$(cache_get claude)
  else
    http GET "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/2.1.80 (external, cli)" \
      -H "Accept: application/json"
    code="$HTTP_CODE"
    case "$code" in
      200)
        json="$HTTP_BODY"; cache_put claude "$json"
        ;;
      429)
        json=$(cache_get claude)
        [ -n "$json" ] && add_line "⚠️ API вернул 429 (лимит запросов) — показаны кэшированные данные"
        ;;
      401|403)
        CLAUDE_SHORT="Claude: токен недействителен"
        add_line "❌ Токен отклонён (HTTP $code). Запустите \`claude\`, чтобы обновить credentials, затем обновите плагин."
        CLAUDE_LINES="$LINES"
        return
        ;;
      *)
        json=$(cache_get claude)
        [ -n "$json" ] && add_line "⚠️ HTTP $code — показаны кэшированные данные"
        ;;
    esac
  fi

  if [ -z "$json" ]; then
    CLAUDE_SHORT="Claude: нет данных"
    add_line "❌ Не удалось получить данные, кэша тоже нет"
    CLAUDE_LINES="$LINES"
    return
  fi

  local used limit exp pct short=""
  used=$(printf '%s' "$json"  | jq -r '.spend.used.amount_minor // .extra_usage.used_credits // empty')
  limit=$(printf '%s' "$json" | jq -r '.spend.limit.amount_minor // .extra_usage.monthly_limit // empty')
  exp=$(printf '%s' "$json"  | jq -r '.spend.used.exponent // .extra_usage.decimal_places // 2')
  pct=$(printf '%s' "$json"  | jq -r '.spend.percent // (.extra_usage.utilization // empty)')
  if [ -n "$used" ] && [ -n "$limit" ]; then
    add_line "💳 Кредиты API: $(fmt_money "$used" "$exp") / $(fmt_money "$limit" "$exp") USD"
    if ! is_num "$pct" && is_num "$used" && is_num "$limit"; then
      pct=$(awk -v u="$used" -v l="$limit" 'BEGIN{ if(l>0) printf "%d", (u/l)*100; else printf "0" }')
    fi
    if is_num "$pct"; then
      add_line "📊 Израсходовано: $pct%"
      short="$pct%"
      CLAUDE_PCT="$pct"
    fi
  fi

  local w u r e label line
  for w in five_hour seven_day seven_day_sonnet seven_day_opus; do
    u=$(printf '%s' "$json" | jq -r ".$w.utilization // empty")
    r=$(printf '%s' "$json" | jq -r ".$w.resets_at // empty")
    is_num "$u" || continue
    e=$(iso_epoch "$r" 2>/dev/null)
    case "$w" in
      five_hour)         label="⏳ 5-часовой лимит" ;;
      seven_day)         label="📅 Недельный лимит" ;;
      seven_day_sonnet)  label="🎵 Неделя (Sonnet)" ;;
      seven_day_opus)    label="🧠 Неделя (Opus)" ;;
    esac
    line="$label: $(pct_of "$u")%"
    if [ -n "$e" ]; then
      line="$line · сброс $(fmt_when "$e") (через $(human_delta $(( e - $(date +%s) ))))"
    fi
    add_line "$line"
  done

  CLAUDE_SHORT="Claude ${short:-—}"
  CLAUDE_LINES="$LINES"
}

# ---------------------------------------------------------------- Dust

dust_region_host() {
  local region
  region=$(kc_get "dust-cli" "region")
  case "$region" in
    europe*|eu*) printf 'https://eu.dust.tt' ;;
    *) printf 'https://dust.tt' ;;
  esac
}

dust_refresh_token() {
  # WorkOS: refresh-токен пригоден для многократного использования (ротации нет).
  local rt new nrt
  rt=$(kc_get "dust-cli" "refresh_token")
  [ -n "$rt" ] || return 1
  http POST "https://api.workos.com/user_management/authenticate" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=refresh_token" \
    --data-urlencode "client_id=client_01JGCT55T7FVDG9XF74925R1KT" \
    --data-urlencode "refresh_token=$rt"
  [ "$HTTP_CODE" = "200" ] || return 1
  new=$(printf '%s' "$HTTP_BODY" | jq -r '.access_token // empty')
  [ -n "$new" ] || return 1
  nrt=$(printf '%s' "$HTTP_BODY" | jq -r '.refresh_token // empty')
  security add-generic-password -U -s "dust-cli" -a "access_token"  -w "$new" >/dev/null 2>&1
  [ -n "$nrt" ] && security add-generic-password -U -s "dust-cli" -a "refresh_token" -w "$nrt" >/dev/null 2>&1
  printf '%s' "$new"
}

dust_token() {
  local tok exp now
  tok=$(kc_get "dust-cli" "access_token")
  [ -n "$tok" ] || return 1
  exp=$(printf '%s' "$tok" | cut -d. -f2 | tr '_-' '/+' | base64 -D 2>/dev/null | jq -r '.exp // 0' 2>/dev/null)
  now=$(date +%s)
  if [ -n "$exp" ] && [ "$exp" -gt $(( now + 60 )) ] 2>/dev/null; then
    printf '%s' "$tok"
    return 0
  fi
  dbg "dust access token истёк, обновляем"
  dust_refresh_token
}

DUST_JSON=""
DUST_ERRCODE=""
DUST_HOST=""
DUST_TOKEN=""

# GET $DUST_HOST/api/w/$ws/<path> с кэшем. Результат -> DUST_JSON, код ошибки -> DUST_ERRCODE.
dust_get() { # path cache_name
  local path="$1" name="$2" code
  if cache_fresh "$name" "$TTL"; then
    DUST_JSON=$(cache_get "$name")
    return 0
  fi
  http GET "$DUST_HOST$path" -H "Authorization: Bearer $DUST_TOKEN"
  code="$HTTP_CODE"
  case "$code" in
    200)
      DUST_JSON="$HTTP_BODY"
      cache_put "$name" "$DUST_JSON"
      ;;
    401|403)
      DUST_JSON=""
      DUST_ERRCODE="$code"
      return 1
      ;;
    *)
      DUST_JSON=$(cache_get "$name")
      [ -n "$DUST_JSON" ] && add_line "⚠️ HTTP $code — показаны кэшированные данные"
      ;;
  esac
  [ -n "$DUST_JSON" ]
}

dust_timeframe_label() {
  case "${1:-}" in
    day)      printf 'день' ;;
    week)     printf 'неделя' ;;
    month)    printf 'месяц' ;;
    lifetime) printf 'бессрочно' ;;
    *)        printf '%s' "${1:-}" ;;
  esac
}


check_dust() {
  LINES=""
  local ws fair usage analytics
  ws=$(kc_get "dust-cli" "workspace_sid")
  if [ -z "$ws" ]; then
    DUST_SHORT="Dust: нет workspace"
    add_line "❌ Не найден workspace_sid в Keychain («dust-cli»). Выполните \`dust login\`."
    DUST_LINES="$LINES"
    return
  fi
  DUST_TOKEN=$(dust_token)
  if [ -z "$DUST_TOKEN" ]; then
    DUST_SHORT="Dust: нет токена"
    add_line "❌ Не удалось получить или обновить OAuth-токен. Выполните \`dust login\`."
    DUST_LINES="$LINES"
    return
  fi
  DUST_HOST=$(dust_region_host)

  # --- Основной источник: fair-use лимит AWU-кредитов (enterprise/тарифы с лимитом) ---
  if ! dust_get "/api/w/$ws/fair-use-credits" dust-fair; then
    if [ -n "$DUST_ERRCODE" ]; then
      DUST_SHORT="Dust: нет доступа"
      add_line "❌ HTTP $DUST_ERRCODE. Обновите токен: \`dust login\`."
      DUST_LINES="$LINES"
      return
    fi
    DUST_SHORT="Dust: нет данных"
    add_line "❌ Нет данных и нет кэша"
    DUST_LINES="$LINES"
    return
  fi
  fair="$DUST_JSON"

local lim cnt tf kind rem pct short=""
  lim=$(printf '%s' "$fair" | jq -r '.fairUseAwuCreditsState.limit // empty')
  cnt=$(printf '%s' "$fair" | jq -r '.fairUseAwuCreditsState.count // empty')
  tf=$(printf '%s'  "$fair" | jq -r '.fairUseAwuCreditsState.timeframe // empty')
  kind=$(printf '%s' "$fair" | jq -r '.fairUseAwuCreditsState.windowKind // empty')

  if [ -n "$lim" ] && [ "$lim" != "-1" ] && is_num "$cnt"; then
    rem=$(awk -v l="$lim" -v c="$cnt" 'BEGIN{r=l-c; if(r<0)r=0; printf "%d", r}')
    pct=$(awk -v l="$lim" -v c="$cnt" 'BEGIN{ if(l>0) printf "%d", (c/l)*100; else printf "0" }')
    add_line "🎖 Кредиты: $cnt из $lim ($(dust_timeframe_label "$tf")) — осталось $rem ($pct%)"
    short="$pct%"
    DUST_PCT="$pct"
    if [ "$cnt" -ge "$lim" ] 2>/dev/null; then
      add_line "⛔ Лимит исчерпан — ждём возврата кредитов"
    fi
  else
    add_line "ℹ️ Лимит AWU-кредитов не задан (безлимит)"
    short="∞"
    DUST_PCT="∞"
  fi

  # Частичный сброс: момент, когда самый старый расход выйдет из окна.
  local nreset reset_line
  nreset=$(printf '%s' "$fair" | jq -r '.fairUseAwuCreditsState.nextResetAt // empty')
  if [ -n "$nreset" ] && [ "$nreset" != "null" ]; then
    reset_line=$(iso_epoch "$nreset" 2>/dev/null)
    if [ -n "$reset_line" ]; then
      if [ "$kind" = "rolling" ]; then
        add_line "♻️ Возврат кредитов: с $(fmt_when "$reset_line") (через $(human_delta $(( reset_line - $(date +%s) ))))"
      else
        add_line "♻️ Полный сброс: $(fmt_when "$reset_line") (через $(human_delta $(( reset_line - $(date +%s) ))))"
      fi
    fi
  fi

  # Расписание возврата: по сколько и когда вернётся.
  local schedule txt
  schedule=$(printf '%s' "$fair" | jq -c '.fairUseAwuCreditsState.refillSchedule // []')
  if [ -n "$schedule" ] && [ "$schedule" != "[]" ]; then
    txt=$(printf '%s' "$schedule" | jq -r '.[0:4][] | "\(.date[8:10]).\(.date[5:7]) +\(.credits)"' 2>/dev/null | tr '\n' ' ')
    [ -n "$txt" ] && add_line "📅 Возврат: ${txt% }"
  fi

  # --- Seat/пул: актуально для тарифов с персональным лимитом ---
  if dust_get "/api/w/$ws/credits/my-usage" dust-usage; then
    usage="$DUST_JSON"
    local seatbal consumed limitawu state seat
    seatbal=$(printf '%s' "$usage" | jq -r '.member.seatBalanceAwu // empty')
    consumed=$(printf '%s' "$usage" | jq -r '.member.consumedAwuCredits // empty')
    limitawu=$(printf '%s' "$usage" | jq -r '.member.spendLimitAwuCredits // empty')
    state=$(printf '%s' "$usage" | jq -r '.member.creditState // empty')
    seat=$(printf '%s' "$usage" | jq -r '.member.seatType // empty')
    if [ -n "$seatbal" ] && [ "$seatbal" != "null" ]; then
      add_line "💠 Seat-баланс: $seatbal AWU · потрачено $consumed из $limitawu"
    elif [ -n "$consumed" ] && [ "$consumed" != "null" ] && [ "${consumed%.*}" != "0" ]; then
      add_line "💠 Потрачено кредитов: $consumed AWU"
    fi
    [ -n "$seat" ] && [ "$seat" != "null" ] && [ "$seat" != "none" ] && add_line "📍 Тариф места: $seat · списание: $state"
  fi

  # --- Аналитика: расход по дням ---
  if dust_get "/api/w/$ws/credits/my-usage-analytics" dust-analytics; then
    analytics="$DUST_JSON"
    local today week
    today=$(printf '%s' "$analytics" | jq -r '(.points // []) | (map(select(.values.total != null)) | last | .values.total) // empty')
    week=$(printf '%s' "$analytics" | jq -r '[(.points // [])[-7:][]?.values.total // 0] | add // empty')
    [ -n "$today" ] && add_line "📈 Сегодня: $today AWU"
    [ -n "$week" ] && add_line "📈 За 7 дней: $week AWU"
  fi

  DUST_SHORT="Dust ${short:-—}"
  DUST_LINES="$LINES"
}

# ---------------------------------------------------------------- Meta Muse
#
# Потребительская подписка Muse (muse.ai): публичного usage-API нет — данные лежат
# в Next.js server action muse.ai. Логика в ~/.local/bin/ai-credits-muse-usage
# (идея из открытого проекта CodexBar, docs/museai.md).
# Куки берём из Chrome / Safari (нужен «Полный доступ к диску») либо из файла
# ~/.config/ai-credits/muse.cookie (вручную скопированный Cookie-заголовок).
#
# Запасной путь — Muse Code CLI (`muse login`), API https://api.meta.ai/muse-code/key.

MUSE_AI_CLIENT="${AI_CREDITS_MUSE_CLIENT:-$HELPER_DIR/ai-credits-muse-usage}"

muse_token() {
  local raw="" tok=""
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}/muse/auth.json" "$HOME/.config/muse/auth.json"; do
    [ -f "$f" ] || continue
    raw=$(run_to 8 cat "$f" 2>/dev/null)
    [ -n "$raw" ] || continue
    tok=$(printf '%s' "$raw" | jq -r '.access_token // .token // .device_token // empty' 2>/dev/null)
    case "$tok" in dca:*) printf '%s' "$tok"; return 0;; esac
  done
  raw=$(kc_get "ai.meta.dev.credentials" "meta")
  [ -z "$raw" ] && raw=$(kc_get "ai.meta.dev.credentials")
  case "$raw" in dca:*) printf '%s' "$raw"; return 0 ;; esac
  tok=$(printf '%s' "$raw" | jq -r '.access_token // .token // empty' 2>/dev/null)
  case "$tok" in dca:*) printf '%s' "$tok"; return 0 ;; esac
  return 1
}

muse_ai_json() {
  local out=""
  [ -f "$MUSE_AI_CLIENT" ] || return 1
  out=$(run_to 60 python3 "$MUSE_AI_CLIENT" 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

check_muse_ai() {
  local json="" pct plan resets tokens renews topup line err tl tv tp
  if cache_fresh muse-ai "$TTL"; then
    json=$(cache_get muse-ai)
  else
    json=$(muse_ai_json)
    # кэшируем только успешный ответ, чтобы ошибка не «залипала» на TTL
    if printf '%s' "$json" | jq -e 'has("pct") and (.pct != null)' >/dev/null 2>&1; then
      cache_put muse-ai "$json"
    fi
  fi
  [ -n "$json" ] || return 1

  if ! printf '%s' "$json" | jq -e 'has("pct") and (.pct != null)' >/dev/null 2>&1; then
    err=$(printf '%s' "$json" | jq -r '.error // "нет данных"' 2>/dev/null)
    [ -n "$err" ] || err="нет данных"
    add_line "❌ muse.ai: $err"
    add_line "ℹ️ Войдите на muse.ai (Chrome/Safari). Если вход есть, а данных нет — выдайте SwiftBar «Полный доступ к диску»."
    return 1
  fi

  pct=$(printf '%s' "$json" | jq -r '.pct')
  plan=$(printf '%s' "$json" | jq -r '.plan // empty')
  resets=$(printf '%s' "$json" | jq -r '.resets_at // empty')
  tokens=$(printf '%s' "$json" | jq -r '.tokens_left // empty')
  renews=$(printf '%s' "$json" | jq -r '.renews_at // empty')
  topup=$(printf '%s' "$json" | jq -c '.topup // empty')

  [ -n "$plan" ] && add_line "📦 План: $plan"

  line="📅 Неделя: $pct%"
  if is_num "$resets" && [ "$(to_int "$resets")" -gt 0 ] 2>/dev/null; then
    line="$line · сброс $(fmt_when "$resets") (через $(human_delta $(( $(to_int "$resets") - $(date +%s) ))))"
  fi
  add_line "$line"

  [ -n "$tokens" ] && add_line "🎟 Осталось: $tokens"

  if [ -n "$topup" ] && [ "$topup" != "null" ]; then
    tl=$(printf '%s' "$topup" | jq -r '.label // "Доп. токены"')
    tv=$(printf '%s' "$topup" | jq -r '.value // empty')
    tp=$(printf '%s' "$topup" | jq -r '.pct // empty')
    line="➕ $tl"
    [ -n "$tv" ] && line="$line: $tv"
    [ -n "$tp" ] && line="$line ($tp%)"
    add_line "$line"
  fi

  if is_num "$renews" && [ "$(to_int "$renews")" -gt 0 ] 2>/dev/null; then
    add_line "🗓 Обновление подписки: $(fmt_when "$renews")"
  fi

  MUSE_PCT="$pct"
  MUSE_SHORT="Muse $pct%"
  return 0
}

check_muse_code() {
  local token code json
  if ! token=$(muse_token); then
    return 1
  fi

  if cache_fresh muse "$TTL"; then
    json=$(cache_get muse)
  else
    http POST "https://api.meta.ai/muse-code/key" \
      -H "Authorization: Bearer $token" \
      -H "x-api-version: 1.0.0" \
      -H "Content-Type: application/json" \
      -d '{}'
    code="$HTTP_CODE"
    case "$code" in
      200) json="$HTTP_BODY"; cache_put muse "$json" ;;
      401|403)
        MUSE_SHORT="Muse: нет доступа"
        add_line "❌ HTTP $code — вход недействителен. Выполните \`muse login\` заново."
        MUSE_LINES="$LINES"
        return 1
        ;;
      *)
        json=$(cache_get muse)
        [ -n "$json" ] && add_line "⚠️ HTTP $code — показаны кэшированные данные"
        ;;
    esac
  fi

  if [ -z "$json" ]; then
    MUSE_SHORT="Muse: нет данных"
    add_line "❌ Нет данных и нет кэша"
    MUSE_LINES="$LINES"
    return 1
  fi

  local active tier reqpay
  active=$(printf '%s' "$json" | jq -r '.is_subs_active // false')
  tier=$(printf '%s' "$json" | jq -r '.subs_tier_name // empty')
  reqpay=$(printf '%s' "$json" | jq -r '.require_payment // false')

  if [ "$reqpay" = "true" ]; then
    MUSE_SHORT="Muse: нужен платёж"
    add_line "❌ Не привязан способ оплаты. Завершите настройку на dev.meta.ai."
    MUSE_LINES="$LINES"
    return 1
  fi
  if [ "$active" != "true" ]; then
    MUSE_SHORT="Muse: нет подписки"
    add_line "ℹ️ Активной подписки нет (pay-as-you-go) — квоту подписки показать нечего."
    MUSE_LINES="$LINES"
    return 1
  fi

  [ -n "$tier" ] && add_line "📦 План: $tier"

  local wp wr wd up re label line
  wp=$(printf '%s' "$json" | jq -r '.subs_usage.window.used_percent // empty')
  wr=$(printf '%s' "$json" | jq -r '.subs_usage.window.resets_at // empty')
  wd=$(printf '%s' "$json" | jq -r '.subs_usage.window.window_duration_mins // empty')
  up=$(printf '%s' "$json" | jq -r '.subs_usage.weekly.used_percent // empty')
  re=$(printf '%s' "$json" | jq -r '.subs_usage.weekly.resets_at // empty')

  if [ -n "$wp" ]; then
    MUSE_PCT="$wp"
    label="⏳ Скользящее окно"
    if is_num "$wd" && [ "$(to_int "$wd")" -gt 0 ]; then
      if [ $(( $(to_int "$wd") % 60 )) -eq 0 ]; then
        label="⏳ Окно $(( $(to_int "$wd") / 60 )) ч"
      else
        label="⏳ Окно $(to_int "$wd") мин"
      fi
    fi
    line="$label: $wp%"
    if is_num "$wr" && [ "$(to_int "$wr")" -gt 0 ]; then
      line="$line · сброс $(fmt_when "$wr") (через $(human_delta $(( $(to_int "$wr") - $(date +%s) ))))"
    fi
    add_line "$line"
  fi

  if [ -n "$up" ]; then
    line="📅 Неделя: $up%"
    if is_num "$re" && [ "$(to_int "$re")" -gt 0 ]; then
      line="$line · сброс $(fmt_when "$re") (через $(human_delta $(( $(to_int "$re") - $(date +%s) ))))"
    fi
    add_line "$line"
  fi

  if [ -z "$wp" ] && [ -z "$up" ]; then
    add_line "ℹ️ Meta не вернула окно квоты (5-часовое окно может быть простаивающим)."
  fi

  MUSE_SHORT="Muse ${wp:-0}%"
  return 0
}

check_muse() {
  LINES=""
  if check_muse_ai; then
    MUSE_LINES="$LINES"
    return
  fi
  local ai_lines="$LINES"
  LINES=""
  if check_muse_code; then
    MUSE_LINES="$LINES"
    return
  fi
  LINES="$ai_lines"
  [ -z "$LINES" ] && add_line "❌ Нет данных по Meta Muse. Войдите на muse.ai — пункт «Открыть muse.ai» ниже."
  MUSE_LINES="$LINES"
}

# ---------------------------------------------------------------- вывод

CLAUDE_LINES=""
DUST_LINES=""
MUSE_LINES=""
CLAUDE_PCT=""
DUST_PCT=""
MUSE_PCT=""

check_claude
check_dust
check_muse

# Короткий вид всегда в меню-баре: три процента использования
CLAUDE_PCT="${CLAUDE_PCT:-—}"
DUST_PCT="${DUST_PCT:-—}"
MUSE_PCT="${MUSE_PCT:-—}"
fmt_pct() {
  case "${1:-}" in
    ""|"—") printf "—" ;;
    "∞")   printf "∞" ;;
    *%)    printf '%s' "$1" ;;
    *)     printf '%s%%' "$1" ;;
  esac
}
title="🧠 $(fmt_pct "$CLAUDE_PCT")  🪹 $(fmt_pct "$DUST_PCT")  🎭 $(fmt_pct "$MUSE_PCT")"
# Заголовок (картинка или текст) выводится ниже, после write_summary:
# генератор картинки читает свежий summary.json.

# Структурированная сводка для GUI-панели (AI Credits.app)
write_summary() {
  local jc jd jm
  jc=$(printf '%s' "$CLAUDE_LINES" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)
  jd=$(printf '%s' "$DUST_LINES"   | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)
  jm=$(printf '%s' "$MUSE_LINES"   | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)
  jq -n \
    --argjson lc "${jc:-[]}" --argjson ld "${jd:-[]}" --argjson lm "${jm:-[]}" \
    --arg pc "${CLAUDE_PCT:-\u2014}" --arg pd "${DUST_PCT:-\u2014}" --arg pm "${MUSE_PCT:-\u2014}" \
    --argjson now "$(date +%s)" \
    '{updated:$now, services:[
       {key:"claude", name:"Claude", emoji:"\ud83e\udde0", pct:$pc, lines:$lc},
       {key:"dust",   name:"Dust",   emoji:"\ud83e\udeb9", pct:$pd, lines:$ld},
       {key:"muse",   name:"Meta Muse", emoji:"\ud83c\udfad", pct:$pm, lines:$lm}]}' \
    > "$CACHE_DIR/summary.json.tmp" 2>/dev/null && mv "$CACHE_DIR/summary.json.tmp" "$CACHE_DIR/summary.json" 2>/dev/null
}

emit() { # текст [параметры swiftbar...]
  local text="$1"; shift
  printf '%s' "$text"
  local p
  for p in "$@"; do printf ' | %s' "$p"; done
  printf '\n'
}

write_summary

bar_img=""
if [ -f "$HELPER_DIR/ai-credits-menubar-img.py" ]; then
  bar_img=$(python3 "$HELPER_DIR/ai-credits-menubar-img.py" 2>/dev/null)
fi
if [ -n "$bar_img" ]; then
  echo "| image=$bar_img"
else
  echo "$title"
fi
echo "---"

if [ -n "$CLAUDE_LINES" ]; then
  printf '%s\n' "$CLAUDE_LINES" | while IFS= read -r l; do [ -n "$l" ] && printf '%s\n' "$l"; done
  echo "---"
fi
if [ -n "$DUST_LINES" ]; then
  printf '%s\n' "$DUST_LINES" | while IFS= read -r l; do [ -n "$l" ] && printf '%s\n' "$l"; done
  echo "---"
fi
if [ -n "$MUSE_LINES" ]; then
  printf '%s\n' "$MUSE_LINES" | while IFS= read -r l; do [ -n "$l" ] && printf '%s\n' "$l"; done
  echo "---"
fi
echo "---"
echo "🔄 Обновить | refresh=true"
