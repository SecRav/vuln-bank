#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG="${GITFLOW_LOG:-$HOME/.barrel-gitflow.log}"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ---------- tiny helpers ----------
say()    { echo -e "$*"; }
ok()     { echo -e "${GREEN}OK:${NC} $*"; }
warn()   { echo -e "${YELLOW}Note:${NC} $*"; }
err()    { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }
# prompt  = yes by default (press Enter = yes)  -> for things you asked for
# prompt_no = no by default (press Enter = no) -> for destructive things
prompt()    { local a; IFS= read -rp "$* [Y/n]: " a; [[ -z "$a" || "$a" =~ ^[yY] ]]; }
prompt_no() { local a; IFS= read -rp "$* [y/N]: " a; [[ "$a" =~ ^[yY] ]]; }

inside_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
branch()      { git rev-parse --abbrev-ref HEAD; }
dirty()       { ! git diff --quiet || ! git diff --cached --quiet; }

check_origin() {
  if git remote get-url origin &>/dev/null; then
    echo -e "${GREEN}$(git remote get-url origin)${NC}"
    return 0
  else
    echo -e "${RED}none${NC}"
    return 1
  fi
}

# ---------- GitHub account switcher ----------
GH_CRED_DIR="${HOME}/.gh-credentials"
GH_ACTIVE_FILE="${GH_CRED_DIR}/active"
GH_CRED_FILE="${HOME}/.git-credentials"
GH_OAUTH_CLIENT="178c6fc778ccc68e1d6a"

_gh_json() {
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(sys.argv[1],''))" "$1" <<< "$2"
}

gh_list_accounts() {
  mkdir -p "$GH_CRED_DIR"
  for f in "$GH_CRED_DIR"/*; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "active" ] && continue
    basename "$f"
  done | sort
}

gh_active_account() {
  [ -f "$GH_ACTIVE_FILE" ] && cat "$GH_ACTIVE_FILE" || echo ""
}

gh_activate() {
  local user="$1"
  local file="${GH_CRED_DIR}/${user}"
  [ -f "$file" ] || { err "Account '${user}' not found. Run: ./gitflow.sh account add"; }
  local token email
  token=$(python3 -c "import json; print(json.load(open('${file}'))['token'])")
  email=$(python3 -c "import json; print(json.load(open('${file}'))['email'])")
  echo "https://${user}:${token}@github.com" > "$GH_CRED_FILE"
  echo "$user" > "$GH_ACTIVE_FILE"
  git config --global user.name "$user"
  git config --global user.email "$email"
}

gh_do_add() {
  set +euo pipefail
  mkdir -p "$GH_CRED_DIR"
  say "\n ${CYAN}GitHub will open in your browser to authorize.${NC}"
  say " Sign in with the account you want to add.\n"

  local resp device_code url user_code interval
  resp=$(curl -sSL -X POST "https://github.com/login/device/code" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -d "{\"client_id\":\"${GH_OAUTH_CLIENT}\",\"scope\":\"repo workflow\"}")
  device_code=$(_gh_json device_code "$resp")
  url=$(_gh_json verification_uri "$resp")
  user_code=$(_gh_json user_code "$resp")
  interval=$(_gh_json interval "$resp")
  [ -z "$interval" ] && interval=5

  say " 1. Open: ${GREEN}${url}${NC}"
  say " 2. Enter code: ${YELLOW}${user_code}${NC}"

  for cmd in xdg-open open start; do
    command -v "$cmd" &>/dev/null && { "$cmd" "$url" &>/dev/null & break; }
  done

  IFS= read -rp " Press Enter after you've authorized in the browser... "
  say " Waiting for authorization..."

  local token=""
  local tmp_resp
  tmp_resp=$(mktemp)
  while true; do
    sleep "$interval" 2>/dev/null || sleep 5
    curl -sSL \
      -H "Accept: application/json" -H "Content-Type: application/json" \
      -d "{\"client_id\":\"${GH_OAUTH_CLIENT}\",\"device_code\":\"${device_code}\",\"grant_type\":\"urn:ietf:params:oauth:grant-type:device_code\"}" \
      "https://github.com/login/oauth/access_token" \
      > "$tmp_resp" 2>/dev/null || true
    resp=$(cat "$tmp_resp")
    token=$(_gh_json access_token "$resp")
    [ -n "$token" ] && break
    local err_type
    err_type=$(_gh_json error "$resp")
    if [ "$err_type" = "authorization_pending" ]; then continue; fi
    if [ "$err_type" = "slow_down" ]; then
      local new_int
      new_int=$(_gh_json interval "$resp")
      [ -n "$new_int" ] && interval="$new_int"
      continue
    fi
    local err_desc
    err_desc=$(_gh_json error_description "$resp")
    [ -z "$err_desc" ] && err_desc="$(_gh_json error "$resp") ($resp)"
    rm -f "$tmp_resp"
    err "OAuth failed: $err_desc"
  done
  rm -f "$tmp_resp"

  local username email
  resp=$(curl -sSL "https://api.github.com/user" \
    -H "Authorization: Bearer ${token}" -H "Accept: application/json")
  username=$(_gh_json login "$resp")

  resp=$(curl -sSL "https://api.github.com/user/emails" \
    -H "Authorization: Bearer ${token}" -H "Accept: application/json")
  email=$(python3 -c "
import sys,json
emails=json.load(sys.stdin)
for e in emails:
    if e.get('primary'): print(e['email']); sys.exit()
if emails: print(emails[0]['email'])
" <<< "$resp" 2>/dev/null)

  python3 -c "
import json
json.dump({'username':'${username}','token':'${token}','email':'${email}'}, open('${GH_CRED_DIR}/${username}','w'))
"
  echo "$username" > "$GH_ACTIVE_FILE"
  echo "https://${username}:${token}@github.com" > "$GH_CRED_FILE"
  git config --global user.name "$username"
  git config --global user.email "$email"

  ok "Added & activated: ${username} (${email})"
  log "account added: $username"
}

gh_account_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "       GitHub Account Switcher"
    echo "========================================"
    local active
    active=$(gh_active_account)
    printf " Active: ${CYAN}%s${NC}\n" "${active:-none}"
    echo " Saved:  $(gh_list_accounts | tr '\n' ', ' || echo 'none')"
    echo "========================================"
    echo "  1)  Add a new GitHub account"
    echo "  2)  Switch to another account"
    echo "  3)  Remove a saved account"
    echo "  4)  List saved accounts"
    echo "  0)  Back to main menu"
    IFS= read -rp " Choose [0-4]: " choice

    case "$choice" in
      1) gh_do_add ;;
      2)
        local accounts
        accounts=($(gh_list_accounts))
        if [ ${#accounts[@]} -eq 0 ]; then
          warn "No accounts saved. Run 'Add' first."
          continue
        fi
        say ""
        local i=1
        for a in "${accounts[@]}"; do
          local mark=""
          [ "$a" = "$active" ] && mark=" ${GREEN}(active)${NC}"
          echo "  $i) $a"
          ((i++))
        done
        IFS= read -rp " Switch to? (number): " pick
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#accounts[@]}" ]; then
          gh_activate "${accounts[$((pick-1))]}"
          ok "Switched to: ${accounts[$((pick-1))]}"
          log "switched account to: ${accounts[$((pick-1))]}"
        else
          warn "Invalid selection."
        fi
        ;;
      3)
        local accounts
        accounts=($(gh_list_accounts))
        if [ ${#accounts[@]} -eq 0 ]; then
          warn "No accounts saved."
          continue
        fi
        IFS= read -rp " Username to remove: " user
        if [ -f "${GH_CRED_DIR}/${user}" ]; then
          say " About to remove: ${YELLOW}${user}${NC}"
          if prompt_no " Confirm?"; then
            rm -f "${GH_CRED_DIR}/${user}"
            [ "$(gh_active_account)" = "$user" ] && rm -f "$GH_ACTIVE_FILE"
            ok "Removed '${user}'"
            log "removed account: $user"
          fi
        else
          warn "Account '${user}' not found."
        fi
        ;;
      4) gh_list_accounts | while read -r a; do
           local mark=""
           [ "$a" = "$active" ] && mark=" (active)"
           echo "  - ${a}${mark}"
         done ;;
      0|q|quit|exit) return 0 ;;
      *) say " ${RED}Invalid option.${NC}" ;;
    esac
  done
}

# ---------- commands ----------
cmd_new() {
  local name="$1"
  if [ -z "$name" ]; then
    IFS= read -rp " Name your feature (no spaces, e.g. fix-logcat): " name
    [ -z "$name" ] && { warn "No name entered — cancelled."; return 1; }
  fi
  local br="feature/$name"
  if git show-ref --verify --quiet "refs/heads/$br"; then
    warn "Branch '$br' already exists. Try 'list' to see what you have."
    return 1
  fi
  if [ "$(branch)" != "main" ]; then
    warn "You're on '$(branch)'. I'll switch to main first."
    if dirty; then
      warn "You have unsaved work on '$(branch)'. Commit or stash it first."
      return 1
    fi
  fi
  git checkout main
  git pull
  git checkout -b "$br"
  ok "Now on '$br'. Edit files freely — 'main' stays untouched."
  log "new feature branch: $br"
}

cmd_push() {
  local br
  br="$(branch)"
  if [ "$br" = "main" ]; then
    warn "You're on 'main' — nothing to push here. Start a feature first (menu 1)."
    return 1
  fi
  if dirty; then
    say " ${YELLOW}You have unsaved changes — I'll commit them first.${NC}"
    IFS= read -rp " Commit message (e.g. 'fix logcat crash', Enter = default): " msg
    git add -A
    git commit -m "${msg:-chore: $br}"
    ok "Saved: ${msg:-chore: $br}"
  fi
  if ! git push -u origin "$br"; then
    warn "Push failed (check network/auth). Nothing was lost — your commits are local."
    log "push FAILED: $br"
    return 1
  fi
  ok "Pushed '$br' to GitHub. Branch pushes don't run any builds."
  log "pushed: $br"
}

cmd_finish() {
  local br
  br="$(branch)"
  [ "$br" = "main" ] && { warn "Already on main — start a feature to merge."; return 1; }
  if dirty; then
    warn "You have unsaved changes — they'll be committed as part of this."
  fi
  say " I'm about to: commit -> switch to main -> pull -> merge '$br' -> push -> delete '$br'."
  if ! prompt " Merge '$br' into main now?"; then
    say " Cancelled. Nothing changed."
    return 1
  fi
  git add -A
  if ! git diff --cached --quiet; then
    IFS= read -rp " Commit message (Enter = default): " msg
    git commit -m "${msg:-chore: ${br#feature/}}"
  fi
  git checkout main
  git pull
  if ! git merge "$br"; then
    warn "Merge conflicts happened. Fix them (or ask for help), then run 'finish' again."
    return 1
  fi
  if ! git push origin main; then
    warn "Push failed. Your merge is committed locally on main — try 'git push' later."
    return 1
  fi
  git branch -d "$br" 2>/dev/null || warn "Couldn't auto-delete '$br'."
  ok "Done! '$br' is now part of main and pushed to GitHub."
  log "merged $br -> main (pushed & branch deleted)"
}

cmd_status() {
  say " Branch: ${CYAN}$(branch)${NC}"
  if dirty; then
    say " You have unsaved changes here. Use menu 2 to commit & push them."
  else
    say " All clean — nothing unsaved."
  fi
}

cmd_history() {
  if [ -f "$LOG" ]; then
    echo "========================================"
    echo "        Recent activity"
    echo "        ($LOG)"
    echo "========================================"
    tail -n 30 "$LOG"
  else
    warn "No history yet — do something first."
  fi
}

cmd_list() {
  git branch -vv
}

cmd_history() {
  if [ ! -f "$LOG" ]; then
    warn "No history yet — the log is written to: $LOG"
    return 1
  fi
  echo " Most recent actions (newest first):"
  echo " ----------------------------------------"
  tail -n 30 "$LOG" | tac
  echo " ----------------------------------------"
  echo " Full log: $LOG"
}

cmd_undo() {
  if git rev-parse HEAD~1 >/dev/null 2>&1; then
    say " Most recent commit on $(branch):"
    git log --oneline -1
    if prompt " Roll it back (your FILES are kept, just un-committed)?"; then
      git reset --soft HEAD~1
      ok "Undone. Your changes are back as 'staged' — commit again anytime."
      log "undo last commit on $(branch)"
    else
      say " Cancelled."
    fi
  else
    warn "No previous commit to go back to."
  fi
}

# ---------- origin manager ----------
origin_menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "       Remote Origin Manager"
    echo "========================================"
    printf " Current origin: "
    check_origin || true
    echo "========================================"
    echo "  1)  Check origin URL"
    echo "  2)  Add origin URL"
    echo "  3)  Set/Change origin URL"
    echo "  4)  Remove origin"
    echo "  0)  Back to main menu"
    IFS= read -rp " Choose [0-4]: " choice

    case "$choice" in
      1)
        if git remote get-url origin &>/dev/null; then
          printf " Origin: ${GREEN}%s${NC}\n" "$(git remote get-url origin)"
        else
          printf " ${RED}No origin remote set.${NC}\n"
        fi
        ;;
      2)
        if git remote get-url origin &>/dev/null 2>&1; then
          warn "Origin already exists: $(git remote get-url origin)"
        else
          IFS= read -rp " Enter origin URL (e.g. git@github.com:you/repo.git): " url
          if [ -n "$url" ]; then
            git remote add origin "$url"
            ok "Added origin: $url"
            log "origin added: $url"
          else
            warn "No URL entered."
          fi
        fi
        ;;
      3)
        IFS= read -rp " Enter new origin URL: " url
        if [ -z "$url" ]; then
          warn "No URL entered."
        elif git remote get-url origin &>/dev/null 2>&1; then
          local old
          old="$(git remote get-url origin)"
          git remote set-url origin "$url"
          ok "Updated: $old -> $url"
          log "origin changed: $old -> $url"
        else
          git remote add origin "$url"
          ok "Added origin: $url"
          log "origin added: $url"
        fi
        ;;
      4)
        if git remote get-url origin &>/dev/null 2>&1; then
          local old
          old="$(git remote get-url origin)"
          say " About to remove: ${YELLOW}$old${NC}"
          if prompt_no " Confirm removal?"; then
            git remote remove origin
            ok "Removed origin: $old"
            log "origin removed: $old"
          else
            say " Cancelled."
          fi
        else
          warn "No origin remote to remove."
        fi
        ;;
      0|q|quit|exit) return 0 ;;
      *) say " ${RED}Invalid option.${NC}" ;;
    esac
  done
}

# ---------- help ----------
show_help() {
  cat <<'EOF'

========================================
        Barrel Git Helper
========================================
 A friendly wrapper around git — no commands to memorize.
 Pick what you want to do and it does the safe thing.

 QUICK START
 --------------------------------------------------------
   ./gitflow.sh               open the interactive menu
   ./gitflow.sh --help        show this help
   ./gitflow.sh new my-thing  start a new feature branch
   ./gitflow.sh push          save & send your feature to GitHub
   ./gitflow.sh finish        merge your feature into main
   ./gitflow.sh status        "what am I working on?"
   ./gitflow.sh list          show every branch
   ./gitflow.sh undo          take back your last commit
   ./gitflow.sh origin        manage the GitHub remote URL
   ./gitflow.sh history       see everything you've done (persistent log)
   ./gitflow.sh account add   sign in with a new GitHub account
   ./gitflow.sh account <user> switch to a saved account
   ./gitflow.sh account list  show all saved accounts

 TIPS
 --------------------------------------------------------
   • Only ONE prompt is ever active — whatever it asks is
     what your Enter goes to. No hidden double-enters.
   • Pressing Enter usually means YES. Only destructive
     actions (like removing origin) need an explicit y.
   • '0' or 'q' at any menu goes back / exits.
   • Every action is saved to a log — 'history' shows it
     any time, even after the script is closed.
   • Every action is saved to ~/.barrel-gitflow.log, so you
     can run './gitflow.sh history' even after quitting.

 BRANCHES IN PLAIN ENGLISH
 --------------------------------------------------------
   main      = the official code. Nobody works here directly.
   feature/  = your personal copy. Edit, save, push here freely.
   Nothing reaches main until you run 'finish'.

 WHAT IT PROTECTS YOU FROM
 --------------------------------------------------------
   • 'push' can never push to main by accident.
   • 'new' always starts from the latest GitHub main.
   • 'finish' shows what it will do before doing it.
   • 'undo' keeps your files — only the commit is rolled back.

EOF
}

# ---------- main menu ----------
show_menu() {
  echo "========================================"
  echo "        Barrel Git Helper"
  echo "========================================"
  printf " Current branch: ${CYAN}%s${NC}\n" "$(branch)"
  printf " Remote origin:  "
  check_origin || true
  echo "========================================"
  echo ""
  echo "  1)  Start a new feature"
  echo "  2)  Save my work & push to GitHub"
  echo "  3)  Merge my feature into main (finish)"
  echo "  4)  What am I working on? (status)"
  echo "  5)  See all branches"
  echo "  6)  Undo my last commit"
  echo "  7)  Remote (origin) — check / add / change / remove"
  echo "  8)  See what I've done (history)"
  echo "  9)  GitHub Account — sign in / switch"
  echo ""
  echo "  0)  Exit"
  echo ""
}

interactive() {
  clear
  while true; do
    show_menu
    IFS= read -rp " Choose a number [0-9]: " choice
    case "$choice" in
      1) cmd_new "" || true ;;
      2) cmd_push || true ;;
      3) cmd_finish || true ;;
      4) cmd_status ;;
      5) cmd_list ;;
      6) cmd_undo || true ;;
      7) origin_menu || true ;;
      8) cmd_history || true ;;
      9) gh_account_menu || true ;;
      0|q|quit|exit) exit 0 ;;
      *) say " ${RED}Not a valid choice.${NC}" ;;
    esac
    echo ""
  done
}

main() {
  inside_repo || err "Not inside a git repo — run this from the Barrel folder."
  case "${1:-menu}" in
    -h|--help|help) show_help ;;
    menu)           interactive ;;
    new)            cmd_new "${2:-}" ;;
    push)           cmd_push ;;
    finish)         cmd_finish ;;
    status)         cmd_status ;;
    list)           cmd_list ;;
    history|log)    cmd_history ;;
    undo)           cmd_undo ;;
    origin)         origin_menu ;;
    account)
      case "${2:-}" in
        add|"") gh_do_add ;;
        list|ls) gh_list_accounts | while read -r a; do
          local mark=""
          [ "$a" = "$(gh_active_account)" ] && mark=" (active)"
          echo "  - ${a}${mark}"
        done ;;
        *) gh_activate "$2" && ok "Switched to: $2" ;;
      esac
      ;;
    *)
      say " Unknown command: '$1'. Run './gitflow.sh --help'."
      exit 1
      ;;
  esac
}

main "$@"
