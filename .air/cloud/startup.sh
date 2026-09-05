#!/usr/bin/env bash
#
# Air environment startup script for the `air-skills` repository.
#
# Runs in two modes, announced by AIR_STARTUP_MODE:
#   warmup - the snapshot-baking run (also used by env-setup verification).
#            Does the slow, cacheable work and then blocks on `healthcheck`.
#   task   - a real task run. Same preparation, but returns promptly.
#
# This repository holds agent skills plus the shared MCP server manifest
# (.mcp.json). It has no application to serve, so there is no dev server to
# start; the environment is "ready" when the interpreters skills are written
# against are usable, .mcp.json is well-formed, any declared dependencies are
# installed, and outbound HTTPS to the MCP hosts works.

set -euo pipefail

log() { printf '[startup] %s\n' "$*"; }
warn() { printf '[startup][warn] %s\n' "$*"; }
fail() { printf '[startup][error] %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi
log "repo=$REPO_ROOT mode=${AIR_STARTUP_MODE:-task}"

MCP_MANIFEST="$REPO_ROOT/.mcp.json"

# ---------------------------------------------------------------------------
# Login-shell environment
#
# The launch runs this script as a child process, so a bare `export` dies with
# it. Write the variables to our own file and source that from the login shell
# profile and from ~/.bashrc, guarded by a marker so re-runs cannot duplicate.
# ---------------------------------------------------------------------------
ENV_FILE="$HOME/.air-skills-env.sh"
ENV_MARKER="# >>> air-skills env >>>"

write_env_file() {
  cat >"$ENV_FILE" <<'EOF'
# Managed by .air/cloud/startup.sh in the air-skills repository.
# Edits here are overwritten on the next environment start.

# Tools installed by `uv tool install`, `pip install --user` and `npm -g`
# prefixed to ~/.local land here; skills routinely rely on it.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# Keep Python from writing .pyc files into the checkout.
export PYTHONDONTWRITEBYTECODE=1
EOF

  # A login shell reads only the FIRST profile file that exists, so hook the
  # first match rather than assuming ~/.profile.
  local profile=""
  for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$candidate" ]; then profile="$candidate"; break; fi
  done
  if [ -z "$profile" ]; then
    profile="$HOME/.profile"
    : >"$profile"
  fi

  # ~/.bashrc covers the non-login interactive shells tools may spawn.
  for target in "$profile" "$HOME/.bashrc"; do
    [ -f "$target" ] || : >"$target"
    if ! grep -qF "$ENV_MARKER" "$target"; then
      {
        printf '\n%s\n' "$ENV_MARKER"
        printf '[ -f "%s" ] && . "%s"\n' "$ENV_FILE" "$ENV_FILE"
        printf '%s\n' "# <<< air-skills env <<<"
      } >>"$target"
      log "hooked $ENV_FILE into $target"
    fi
  done
}

log "writing login-shell environment hook"
write_env_file
# shellcheck source=/dev/null
. "$ENV_FILE"

# ---------------------------------------------------------------------------
# Manifest inspection
#
# .mcp.json is the one thing this repository currently declares. Parse it with
# python3 (no jq in the base image) to (a) prove it is valid JSON and (b) learn
# which ${VAR} placeholders and which hosts the MCP servers need.
# ---------------------------------------------------------------------------
MCP_VARS=""
MCP_URLS=""

read_mcp_manifest() {
  if [ ! -f "$MCP_MANIFEST" ]; then
    warn ".mcp.json not found - skipping MCP manifest checks"
    return 0
  fi

  local parsed
  if ! parsed="$(python3 - "$MCP_MANIFEST" <<'PY'
import json, re, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    manifest = json.load(fh)

servers = manifest.get("mcpServers") or {}
if not isinstance(servers, dict):
    raise SystemExit("mcpServers must be an object")

urls, variables = [], []
for name, spec in servers.items():
    if not isinstance(spec, dict):
        raise SystemExit(f"server {name!r} must be an object")
    url = spec.get("url")
    if url:
        urls.append(url)
    # ${VAR} placeholders anywhere in the server definition (headers, env, ...)
    for var in re.findall(r"\$\{(\w+)\}", json.dumps(spec)):
        if var not in variables:
            variables.append(var)

print("SERVERS=" + " ".join(sorted(servers)))
print("URLS=" + " ".join(urls))
print("VARS=" + " ".join(variables))
PY
  )"; then
    fail ".mcp.json is not valid / not usable - fix the manifest"
    return 1
  fi

  local servers=""
  while IFS= read -r line; do
    case "$line" in
      SERVERS=*) servers="${line#SERVERS=}" ;;
      URLS=*) MCP_URLS="${line#URLS=}" ;;
      VARS=*) MCP_VARS="${line#VARS=}" ;;
    esac
  done <<<"$parsed"

  log ".mcp.json is valid; servers: ${servers:-none}"
  [ -n "$MCP_VARS" ] && log ".mcp.json expects variables: $MCP_VARS"
  return 0
}

# ---------------------------------------------------------------------------
# Dependency installation
#
# The repository ships no package manifests today. These branches are the slow,
# cacheable work for when skills start carrying helper scripts - the results
# land in the warmup snapshot, so real tasks boot with them already in place.
# ---------------------------------------------------------------------------
NODE_DEPS_EXPECTED=
PY_VENV_EXPECTED=

install_dependencies() {
  if [ -f "$REPO_ROOT/package.json" ]; then
    NODE_DEPS_EXPECTED=1
    local mgr="npm"
    if [ -f "$REPO_ROOT/pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
      mgr="pnpm"
    fi
    log "installing Node dependencies with $mgr (this can take a while)"
    if [ "$mgr" = pnpm ]; then
      pnpm install --frozen-lockfile || pnpm install
    elif [ -f "$REPO_ROOT/package-lock.json" ]; then
      npm ci || npm install
    else
      npm install
    fi
    log "Node dependencies installed"
  else
    log "no package.json - skipping Node dependency install"
  fi

  if [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/uv.lock" ]; then
    PY_VENV_EXPECTED=1
    log "syncing Python project with uv (this can take a while)"
    uv sync
    log "Python project synced into .venv"
  elif [ -f "$REPO_ROOT/requirements.txt" ]; then
    PY_VENV_EXPECTED=1
    log "installing requirements.txt into .venv with uv"
    [ -d "$REPO_ROOT/.venv" ] || uv venv
    uv pip install -r "$REPO_ROOT/requirements.txt"
    log "Python requirements installed into .venv"
  else
    log "no Python manifest - skipping Python dependency install"
  fi
}

# ---------------------------------------------------------------------------
# Skill content report (informational only)
#
# A malformed SKILL.md is a repository problem, not a broken environment, and a
# task may well have been started to fix it - so this reports and never fails.
# ---------------------------------------------------------------------------
report_skills() {
  local count
  count="$(find "$REPO_ROOT" -name SKILL.md -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" = 0 ]; then
    log "no SKILL.md files in the checkout yet"
    return 0
  fi
  log "found $count SKILL.md file(s); checking front matter"
  python3 - "$REPO_ROOT" <<'PY' || true
import pathlib, sys

root = pathlib.Path(sys.argv[1])
for path in sorted(root.rglob("SKILL.md")):
    if ".git" in path.parts:
        continue
    rel = path.relative_to(root)
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines or lines[0].strip() != "---":
        print(f"[startup][warn] {rel}: missing YAML front matter fence")
        continue
    try:
        end = lines.index("---", 1)
    except ValueError:
        print(f"[startup][warn] {rel}: front matter is not closed")
        continue
    keys = {
        line.split(":", 1)[0].strip()
        for line in lines[1:end]
        if ":" in line and not line.startswith((" ", "\t", "#"))
    }
    missing = sorted({"name", "description"} - keys)
    if missing:
        print(f"[startup][warn] {rel}: front matter missing {', '.join(missing)}")
    else:
        print(f"[startup] {rel}: front matter ok")
PY
}

# ---------------------------------------------------------------------------
# healthcheck
#
# Asserts the environment actually works the way a task in this repository
# needs it to. Deterministic checks fail fast; the one genuinely asynchronous
# dependency (outbound HTTPS through the egress proxy) is polled until it
# answers, with no deadline of its own - the launch applies that.
# ---------------------------------------------------------------------------
healthcheck() {
  log "healthcheck: starting"
  local failures=0

  # 1. Interpreters and tooling that skills and the agent rely on.
  local tool
  for tool in git python3 node curl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      fail "healthcheck: required tool '$tool' is not on PATH"
      failures=$((failures + 1))
    fi
  done
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,pathlib,re,sys; sys.exit(0)'; then
      log "healthcheck: python3 $(python3 -c 'import platform; print(platform.python_version())') ok"
    else
      fail "healthcheck: python3 cannot run a trivial script"
      failures=$((failures + 1))
    fi
  fi
  if command -v node >/dev/null 2>&1; then
    if [ "$(node -e 'process.stdout.write("ok")')" = ok ]; then
      log "healthcheck: node $(node --version) ok"
    else
      fail "healthcheck: node cannot run a trivial script"
      failures=$((failures + 1))
    fi
  fi

  # 2. The checkout is a usable git working tree (tasks commit and push).
  if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "healthcheck: git work tree ok at $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  else
    fail "healthcheck: $REPO_ROOT is not a usable git work tree"
    failures=$((failures + 1))
  fi

  # 3. The MCP manifest still parses (re-checked here, not just prepared above).
  if [ -f "$MCP_MANIFEST" ]; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$MCP_MANIFEST"; then
      log "healthcheck: .mcp.json parses"
    else
      fail "healthcheck: .mcp.json does not parse"
      failures=$((failures + 1))
    fi
  fi

  # 4. Dependencies that the install step said it produced are really there.
  if [ -n "$NODE_DEPS_EXPECTED" ] && [ ! -d "$REPO_ROOT/node_modules" ]; then
    fail "healthcheck: package.json present but node_modules is missing"
    failures=$((failures + 1))
  fi
  if [ -n "$PY_VENV_EXPECTED" ]; then
    if [ -x "$REPO_ROOT/.venv/bin/python" ]; then
      "$REPO_ROOT/.venv/bin/python" -c 'import sys; print("[startup] healthcheck: .venv python", sys.version.split()[0])'
    else
      fail "healthcheck: Python manifest present but .venv/bin/python is missing"
      failures=$((failures + 1))
    fi
  fi

  # 5. Outbound HTTPS to the hosts .mcp.json talks to. Any HTTP status counts:
  #    an answer proves DNS, the egress proxy and TLS work, which is the
  #    environment's responsibility. Whether the token is accepted is not.
  local url
  for url in $MCP_URLS; do
    local host status
    host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#[/?].*$##')"
    log "healthcheck: waiting for outbound HTTPS to $host"
    local attempt=0
    while :; do
      attempt=$((attempt + 1))
      status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" 2>/dev/null || true)"
      if [ -n "$status" ] && [ "$status" != 000 ]; then
        log "healthcheck: $host answered HTTP $status after $attempt attempt(s)"
        break
      fi
      log "healthcheck: $host not reachable yet (attempt $attempt) - retrying"
      sleep 5
    done
  done

  # 6. Variables .mcp.json interpolates. These are the user's personal secrets
  #    and the MCP servers they gate are optional for authoring skills, so an
  #    empty one is reported loudly but does not break the environment.
  local var
  for var in $MCP_VARS; do
    if [ -n "${!var:-}" ]; then
      log "healthcheck: $var is set"
    else
      warn "$var is not set - the MCP server that needs it will fail to authenticate."
      warn "Add it as a secret in the Air environment configuration to enable that server."
    fi
  done

  if [ "$failures" -ne 0 ]; then
    fail "healthcheck: FAILED with $failures problem(s)"
    return 1
  fi
  log "healthcheck: PASSED"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
read_mcp_manifest
install_dependencies
report_skills

if [ -n "$WARMUP" ]; then
  log "warmup run - blocking on healthcheck before the snapshot is taken"
  healthcheck
else
  log "task run - environment prepared; skipping the blocking healthcheck so the task starts now"
fi

log "startup complete"
