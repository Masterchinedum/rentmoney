#!/usr/bin/env bash
# block-dangerous-bash.sh - Claude Code PreToolUse hook (matcher: Bash)
#
# Blocks shell commands that destroy data or systems and are almost never what
# the user meant: recursive rm on filesystem/home/project roots, force-push to
# main/master, `git reset --hard` onto a remote ref, DROP DATABASE/TABLE via a
# DB client, `curl | sh` pipes, `chmod -R 777`, and raw disk writes.
#
# Exit 0 = allow, exit 2 = block (stderr is shown to Claude as the reason).
# Missing jq or unparseable input fails open (allows) with a warning.
# Compatible with bash 3.2 (macOS default).

set -euo pipefail

HOOK=block-dangerous-bash

if ! command -v jq >/dev/null 2>&1; then
  echo "$HOOK: jq not found, so this hook is disabled and the command was allowed. Install jq (brew install jq / apt install jq) to enable it." >&2
  exit 0
fi

input=$(cat)
if ! cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null); then
  echo "$HOOK: could not parse hook input as JSON; allowing." >&2
  exit 0
fi
[ -n "$cmd" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd=$PWD
project_dir=${CLAUDE_PROJECT_DIR:-}

SEP=$'\037'
DEPTH=0
LAST_CD=""

block() {
  printf '%s: blocked. %s\nIf this really is intended, stop and ask the user to run it themselves in their terminal.\n' "$HOOK" "$1" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Tokenizer: splits a command string into simple commands (one per output
# line) on unquoted ; & | newline ( ) ` $( <( >(. Tokens are separated by
# \037 with quotes removed. Redirect targets and comments are dropped.
# ---------------------------------------------------------------------------
AWK_TOKENIZE=$(cat <<'AWK'
function flushtok() {
  if (have) { if (skip) skip = 0; else line = (line == "" ? tok : line SEP tok) }
  tok = ""; have = 0
}
function flushline() { if (line != "") print line; line = ""; skip = 0 }
BEGIN {
  s = ENVIRON["BDB_CMD"]; n = length(s); SEP = "\037"
  tok = ""; have = 0; line = ""; q = ""; skip = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "'") { if (c == "'") q = ""; else tok = tok c; continue }
    if (q == "\"") {
      if (c == "\\" && i < n) {
        d = substr(s, i + 1, 1)
        if (d == "\"" || d == "\\" || d == "$" || d == "`") { tok = tok d; i++; continue }
      }
      if (c == "\"") q = ""; else tok = tok c
      continue
    }
    if (c == "\\") {
      if (i < n) { i++; d = substr(s, i, 1); if (d != "\n") { tok = tok d; have = 1 } }
      continue
    }
    if (c == "'" || c == "\"") { q = c; have = 1; continue }
    if (c == "#" && !have) { while (i < n && substr(s, i + 1, 1) != "\n") i++; continue }
    if (c == "$" && substr(s, i + 1, 1) == "{") {
      j = index(substr(s, i), "}")
      if (j > 0) { tok = tok substr(s, i, j); have = 1; i += j - 1; continue }
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") { flushtok(); flushline(); i++; continue }
    if ((c == "<" || c == ">") && substr(s, i + 1, 1) == "(") { flushtok(); flushline(); i++; continue }
    if (c == "<" || c == ">") {
      if (have && tok ~ /^[0-9]+$/) { tok = ""; have = 0 } else flushtok()
      while (i < n && substr(s, i + 1, 1) ~ /[<>&|]/) i++
      skip = 1
      continue
    }
    if (c == " " || c == "\t" || c == "\r") { flushtok(); continue }
    if (c == ";" || c == "&" || c == "|" || c == "\n" || c == "(" || c == ")" || c == "`") {
      flushtok(); flushline(); continue
    }
    tok = tok c; have = 1
  }
  flushtok(); flushline()
}
AWK
)

tokenize() { BDB_CMD="$1" awk "$AWK_TOKENIZE"; }

to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------
# rm target classification
# ---------------------------------------------------------------------------
normalize_path() {
  local x=$1
  while [[ $x == *//* ]]; do x=${x//\/\//\/}; done
  case $x in
    /\*) x=/ ;;
    */\*) x=${x%/\*} ;;
  esac
  while [ "$x" != "/" ] && [ "${x%/}" != "$x" ]; do x=${x%/}; done
  case $x in
    /.) x=/ ;;
    */.) x=${x%/.} ;;
  esac
  printf '%s' "$x"
}

norm_cwd=$(normalize_path "$cwd")
norm_proj=""
[ -z "$project_dir" ] || norm_proj=$(normalize_path "$project_dir")

# Absolute roots: filesystem root, top-level system dirs, home, project dir.
is_absolute_root() {
  local x=$1
  case $x in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/private|/root|/sbin|/srv|/usr|/var|/System|/Users|/Library|/Applications|/Volumes)
      return 0 ;;
    '~'|'~'/'*'|'$HOME'|'${HOME}'|'$HOME/*'|'${HOME}/*') return 0 ;;
  esac
  # ~user (another user's home), no further path component
  if [[ $x == '~'* && $x != */* ]]; then return 0; fi
  if [ -n "${HOME:-}" ] && [ "$x" = "$HOME" ]; then return 0; fi
  if [ "$x" = "$norm_cwd" ]; then return 0; fi
  if [ -n "$norm_proj" ] && [ "$x" = "$norm_proj" ]; then return 0; fi
  return 1
}

# Returns 0 (dangerous) with a description on stdout, 1 if fine.
classify_rm_target() {
  local raw=$1 x
  x=$(normalize_path "$raw")
  [ -n "$x" ] || return 1
  if is_absolute_root "$x"; then printf '%s' "$raw"; return 0; fi
  # Relative paths made only of dots and slashes that climb upward: .., ../..
  case $x in
    *[!./]*) ;;
    *..*) printf '%s' "$raw"; return 0 ;;
  esac
  # The current directory itself: ., *, .*
  case $x in
    .|'*'|'.*')
      if [ -n "$LAST_CD" ] && [ "$LAST_CD" != "-" ]; then
        local c
        c=$(normalize_path "$LAST_CD")
        if ! is_absolute_root "$c" && [[ $c == *[!./]* ]]; then
          return 1   # e.g. `cd dist && rm -rf *` - scoped to a subdirectory
        fi
      fi
      printf '%s' "$raw"; return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Per-command checks. They read the array `toks` and index `i` (the command).
# ---------------------------------------------------------------------------
check_rm() {
  local n=${#toks[@]} j recursive=0 endopts=0 a hit
  for ((j = i + 1; j < n; j++)); do
    a=${toks[$j]}
    if [ $endopts -eq 0 ]; then
      case $a in
        --) endopts=1; continue ;;
        --recursive) recursive=1; continue ;;
        --*) continue ;;
        -?*) [[ $a == *[rR]* ]] && recursive=1; continue ;;
      esac
    fi
  done
  [ $recursive -eq 1 ] || return 0
  endopts=0
  for ((j = i + 1; j < n; j++)); do
    a=${toks[$j]}
    if [ $endopts -eq 0 ]; then
      case $a in
        --) endopts=1; continue ;;
        -?*) continue ;;
      esac
    fi
    if hit=$(classify_rm_target "$a"); then
      block "Recursive rm on '$hit' would delete a filesystem, home or project root. Delete the specific subdirectory instead (for example: rm -rf ./build)."
    fi
  done
}

git_current_branch() {
  git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null || true
}

is_protected_branch() {
  case $1 in main|master) return 0 ;; esac
  return 1
}

check_git_push() {
  local j=$1 repo=$2 n=${#toks[@]} a force=0 all=0 del=0 endopts=0 npos=0
  local refspecs="" cur
  while [ $j -lt $n ]; do
    a=${toks[$j]}
    if [ $endopts -eq 0 ] && [[ $a == -* ]]; then
      case $a in
        --) endopts=1 ;;
        --force|--force-with-lease|--force-with-lease=*) force=1 ;;
        --all|--mirror) all=1 ;;
        --delete) del=1 ;;
        -o|--push-option|--repo|--receive-pack|--exec) j=$((j + 1)) ;;
        --*) ;;
        -*)
          [[ $a == *f* ]] && force=1
          [[ $a == *d* ]] && del=1
          ;;
      esac
    else
      npos=$((npos + 1))
      [ $npos -gt 1 ] && refspecs="$refspecs$a$SEP"
    fi
    j=$((j + 1))
  done

  cur=$(git_current_branch "$repo")

  if [ $force -eq 1 ] && [ $all -eq 1 ]; then
    block "Force push with --all/--mirror rewrites every branch on the remote, including main/master."
  fi
  if [ -z "$refspecs" ]; then
    if [ $force -eq 1 ] && is_protected_branch "$cur"; then
      block "Force push while on '$cur' rewrites shared history on the remote '$cur'. Push to a feature branch instead."
    fi
    return 0
  fi

  local rs src dst plus
  local IFS=$SEP
  for rs in $refspecs; do
    plus=0
    case $rs in +*) plus=1; rs=${rs#+} ;; esac
    if [[ $rs == *:* ]]; then src=${rs%%:*}; dst=${rs##*:}; else src=$rs; dst=$rs; fi
    dst=${dst#refs/heads/}
    [ "$dst" = "HEAD" ] && dst=$cur
    is_protected_branch "$dst" || continue
    if [ $force -eq 1 ] || [ $plus -eq 1 ]; then
      block "Force push to '$dst' rewrites shared history. Push to a feature branch and open a PR instead."
    fi
    if [ $del -eq 1 ] || { [[ $rs == *:* ]] && [ -z "$src" ]; }; then
      block "This deletes the remote '$dst' branch."
    fi
  done
}

is_remote_ref() {
  local t=$1 repo=$2 r remotes
  case $t in
    *@{u}*|*@{upstream}*|*@{push}*|*@{U}*|*@{UPSTREAM}*|refs/remotes/*|remotes/*|FETCH_HEAD*) return 0 ;;
  esac
  remotes=$(git -C "$repo" remote 2>/dev/null || true)
  for r in origin upstream $remotes; do
    case $t in "$r"/*) return 0 ;; esac
  done
  return 1
}

check_git_reset() {
  local j=$1 repo=$2 n=${#toks[@]} a hard=0 target=""
  while [ $j -lt $n ]; do
    a=${toks[$j]}
    case $a in
      --hard) hard=1 ;;
      --) break ;;
      -*) ;;
      *) [ -z "$target" ] && target=$a ;;
    esac
    j=$((j + 1))
  done
  [ $hard -eq 1 ] && [ -n "$target" ] || return 0
  if is_remote_ref "$target" "$repo"; then
    block "'git reset --hard $target' discards local commits and uncommitted work to match the remote. Use 'git stash' first, or 'git reset --keep', or create a backup branch (git branch backup-\$(date +%s))."
  fi
}

check_git() {
  local n=${#toks[@]} j=$((i + 1)) a repo=$cwd
  while [ $j -lt $n ]; do
    a=${toks[$j]}
    case $a in
      -C)
        if [ $((j + 1)) -lt $n ]; then
          case ${toks[$((j + 1))]} in
            /*) repo=${toks[$((j + 1))]} ;;
            *) repo="$cwd/${toks[$((j + 1))]}" ;;
          esac
        fi
        j=$((j + 2)) ;;
      -c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ $j -lt $n ] || return 0
  case ${toks[$j]} in
    push) check_git_push $((j + 1)) "$repo" ;;
    reset) check_git_reset $((j + 1)) "$repo" ;;
  esac
}

check_chmod() {
  local n=${#toks[@]} j a recursive=0 mode=""
  for ((j = i + 1; j < n; j++)); do
    a=${toks[$j]}
    case $a in
      --recursive) recursive=1 ;;
      --*) ;;
      777|0777|a+rwx|a=rwx|ugo+rwx|ugo=rwx) mode=$a ;;
      -*) [[ $a == *R* ]] && recursive=1 ;;
    esac
  done
  if [ $recursive -eq 1 ] && [ -n "$mode" ]; then
    block "chmod -R $mode makes every file world-writable (and executable). Grant only what is needed, e.g. chmod -R u+rwX,go+rX <dir>."
  fi
}

check_dd() {
  local n=${#toks[@]} j a
  for ((j = i + 1; j < n; j++)); do
    a=${toks[$j]}
    case $a in
      of=/dev/null|of=/dev/zero|of=/dev/stdout|of=/dev/stderr|of=/dev/tty|of=/dev/random|of=/dev/urandom|of=/dev/fd/*) ;;
      of=/dev/*) block "dd writing to ${a#of=} overwrites a raw device." ;;
    esac
  done
}

check_diskutil() {
  local n=${#toks[@]} j a
  for ((j = i + 1; j < n; j++)); do
    a=$(to_lower "${toks[$j]}")
    case $a in
      erasedisk|erasevolume|reformat|zerodisk|randomdisk|secureerase|partitiondisk|eraseoptical)
        block "diskutil ${toks[$j]} erases a disk or volume." ;;
    esac
  done
}

check_shell_c() {
  local n=${#toks[@]} j a
  for ((j = i + 1; j < n; j++)); do
    a=${toks[$j]}
    case $a in
      --*) ;;
      -*c*)
        if [ $((j + 1)) -lt $n ]; then check_command "${toks[$((j + 1))]}"; fi
        return 0 ;;
      -*) ;;
      *) return 0 ;;
    esac
  done
}

check_segment() {
  local -a toks
  IFS=$SEP read -r -a toks <<<"$1"
  local n=${#toks[@]} i=0 t f
  [ "$n" -gt 0 ] || return 0

  # Skip env assignments and wrapper commands (sudo, env, xargs, nice, ...).
  while [ $i -lt $n ]; do
    t=${toks[$i]}
    if [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
    case $t in
      sudo|doas|env|command|builtin|exec|nohup|nice|time|xargs|stdbuf|ionice|caffeinate|then|do|else|elif|if|while|until|'!'|'{'|'}')
        i=$((i + 1))
        while [ $i -lt $n ]; do
          f=${toks[$i]}
          case $f in
            --) i=$((i + 1)); break ;;
            -u|-g|-n|-I|-L|-P|-d|-E|-C|-D|-U|-p) i=$((i + 2)) ;;
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        ;;
      timeout|gtimeout)
        i=$((i + 1))
        while [ $i -lt $n ] && [[ ${toks[$i]} == -* ]]; do i=$((i + 1)); done
        i=$((i + 1)) ;;   # the duration
      *) break ;;
    esac
  done
  [ $i -lt $n ] || return 0

  local name=${toks[$i]##*/}
  case $name in
    cd|pushd)
      LAST_CD="~"
      local j
      for ((j = i + 1; j < n; j++)); do
        case ${toks[$j]} in -*) ;; *) LAST_CD=${toks[$j]}; break ;; esac
      done ;;
    rm) check_rm ;;
    git) check_git ;;
    chmod) check_chmod ;;
    dd) check_dd ;;
    mkfs|mkfs.*|newfs|newfs_*|wipefs)
      block "$name formats or wipes a filesystem." ;;
    diskutil) check_diskutil ;;
    dropdb)
      block "dropdb deletes an entire database. Ask the user to run it if this is intended." ;;
    mysqladmin)
      local j
      for ((j = i + 1; j < n; j++)); do
        case $(to_lower "${toks[$j]}") in drop) block "mysqladmin drop deletes an entire database." ;; esac
      done ;;
    sh|bash|zsh|dash|ksh|fish) check_shell_c ;;
    eval)
      if [ $((i + 1)) -lt $n ]; then
        local rest="${toks[*]:$((i + 1))}"
        check_command "${rest//$SEP/ }"
      fi ;;
  esac
}

check_command() {
  local line
  DEPTH=$((DEPTH + 1))
  if [ $DEPTH -gt 5 ]; then DEPTH=$((DEPTH - 1)); return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] && { check_segment "$line" || true; }
  done <<EOF
$(tokenize "$1")
EOF
  DEPTH=$((DEPTH - 1))
}

# ---------------------------------------------------------------------------
# Whole-command pattern checks (need pipes/redirects the tokenizer drops).
# ---------------------------------------------------------------------------
q="[\"']?"
re_pipe_shell='(^|[^[:alnum:]_.-])(curl|wget|fetch)([[:space:]][^|;&]*)?\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?(env[[:space:]]+)?([^[:space:]|;&]*/)?(sh|bash|zsh|dash|ksh|fish)([[:space:];&|)]|$)'
re_pipe_interp='(^|[^[:alnum:]_.-])(curl|wget|fetch)([[:space:]][^|;&]*)?\|[[:space:]]*(sudo([[:space:]]+-[^[:space:]]+)*[[:space:]]+)?([^[:space:]|;&]*/)?(python[0-9.]*|perl|ruby|node|php)([[:space:]]+-)?[[:space:]]*($|[;&|)])'
re_procsub='(^|[^[:alnum:]_])(sh|bash|zsh|dash|ksh|source|\.)[[:space:]]+<\([[:space:]]*(curl|wget)'
re_cmdsub='(eval|(sh|bash|zsh|dash|ksh)[[:space:]]+-[[:alpha:]]*c)[[:space:]]+'"$q"'\$\([[:space:]]*(curl|wget)'
re_rawdisk='>[[:space:]]*/dev/(sd[a-z]|nvme[0-9]|disk[0-9]|rdisk[0-9]|hd[a-z]|xvd[a-z]|vd[a-z]|mmcblk[0-9])'
re_sql_drop='(^|[^[:alnum:]_])DROP[[:space:]]+(DATABASE|TABLE|SCHEMA)([[:space:]]|$)'
re_sql_client='(^|[^[:alnum:]_.-])(PSQL|MYSQL|MARIADB|PGCLI|MYCLI|MYSQLSH)([[:space:]]|$)'

if [[ $cmd =~ $re_pipe_shell ]] || [[ $cmd =~ $re_pipe_interp ]] || [[ $cmd =~ $re_procsub ]] || [[ $cmd =~ $re_cmdsub ]]; then
  block "Piping a downloaded script straight into a shell or interpreter runs unreviewed remote code. Download it to a file, show it to the user, and let them run it."
fi

if [[ $cmd =~ $re_rawdisk ]]; then
  block "Redirecting output to a raw disk device overwrites it."
fi

upper=$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')
if [[ $upper =~ $re_sql_client ]] && [[ $upper =~ $re_sql_drop ]]; then
  block "DROP DATABASE/TABLE/SCHEMA through a database client destroys data with no undo. Write a reviewed migration, or ask the user to run it."
fi

check_command "$cmd" || true
exit 0
