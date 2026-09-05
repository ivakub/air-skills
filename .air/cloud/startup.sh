#!/usr/bin/env bash
#
# Air environment startup for the `air-skills` repository.
#
# The repository holds agent skill definitions plus `.mcp.json`, which wires up two
# remote HTTP MCP servers (YouTrack and TeamCity) using the YOUTRACK_TOKEN and
# TEAMCITY_TOKEN secrets. There is no application to build or serve here, so the job
# of this script is to provide the authoring toolchain and to prove that the MCP
# servers a real task depends on are actually reachable and authenticated.
#
# Two modes, signalled by AIR_STARTUP_MODE:
#   warmup - snapshot-baking run (also the env-setup companion): do the cacheable
#            work and block on `healthcheck` at the end.
#   task   - real task run: same setup, return promptly without the health gate.
#
set -uo pipefail

log()  { printf '[startup] %s\n' "$*"; }
warn() { printf '[startup][warn] %s\n' "$*" >&2; }
die()  { printf '[startup][error] %s\n' "$*" >&2; exit 1; }

if [ "${AIR_STARTUP_MODE:-}" = warmup ]; then WARMUP=1; else WARMUP=; fi

LOCAL_BIN="$HOME/.local/bin"
ENV_FILE="$HOME/.air-skills-env.sh"
HOOK_MARKER='# >>> air-skills env (managed by .air/cloud/startup.sh) >>>'
JQ_VERSION='1.7.1'
YQ_VERSION='v4.44.6'

# ---------------------------------------------------------------------------
# Locate the repository checkout. The launcher materializes this script outside
# the repo, so $BASH_SOURCE is not a reliable anchor.
# ---------------------------------------------------------------------------
detect_repo_root() {
  local root candidate
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$root"
    return 0
  fi
  for candidate in "${AIR_REPO_DIR:-}" /workspaces/air-skills "$HOME/workspace/air-skills"; do
    if [ -n "$candidate" ] && [ -d "$candidate/.git" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  for candidate in /workspaces/*/; do
    if [ -d "${candidate}.git" ]; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

REPO_ROOT=$(detect_repo_root) || die "could not locate the air-skills checkout (no git work tree found)"
log "repository root: $REPO_ROOT"
log "startup mode: ${AIR_STARTUP_MODE:-task}"

MCP_CONFIG="$REPO_ROOT/.mcp.json"

# ---------------------------------------------------------------------------
# Userspace tooling. sudo is password-gated in this image, so everything lands in
# ~/.local/bin. Both are single static binaries, cached into the snapshot.
# ---------------------------------------------------------------------------
install_binary() {
  local name="$1" want="$2" url="$3"
  local target="$LOCAL_BIN/$name"
  if [ -x "$target" ] && "$target" --version 2>/dev/null | grep -qF "$want"; then
    log "$name $want already installed, skipping download"
    return 0
  fi
  log "installing $name $want"
  if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$target.tmp" "$url"; then
    rm -f "$target.tmp"
    die "failed to download $name from $url"
  fi
  chmod +x "$target.tmp"
  mv -f "$target.tmp" "$target"
  log "$name installed: $("$target" --version 2>&1 | head -1)"
}

mkdir -p "$LOCAL_BIN" || die "cannot create $LOCAL_BIN"

install_binary jq "$JQ_VERSION" \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64"
install_binary yq "$YQ_VERSION" \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64"

export PATH="$LOCAL_BIN:$PATH"

# ---------------------------------------------------------------------------
# Persist environment for the agent's login shell. A bare `export` here dies with
# this process, so write a file and source it from the shell startup files.
# ---------------------------------------------------------------------------
log "writing shell environment to $ENV_FILE"
cat > "$ENV_FILE" <<'ENVEOF'
# Managed by .air/cloud/startup.sh in the air-skills repository. Edits are overwritten.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
# The image's global npm prefix is root-owned; point it at $HOME so `npm i -g` works.
export NPM_CONFIG_PREFIX="$HOME/.local"
ENVEOF

hook_line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\""

add_hook() {
  local rc_file="$1"
  if [ -f "$rc_file" ] && grep -qF "$HOOK_MARKER" "$rc_file"; then
    log "shell hook already present in $rc_file"
    return 0
  fi
  {
    printf '\n%s\n' "$HOOK_MARKER"
    printf '%s\n' "$hook_line"
    printf '%s\n' '# <<< air-skills env <<<'
  } >> "$rc_file" || die "cannot append shell hook to $rc_file"
  log "added shell hook to $rc_file"
}

# A login shell reads only the FIRST of these that exists.
login_rc=''
for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  if [ -f "$candidate" ]; then login_rc="$candidate"; break; fi
done
[ -n "$login_rc" ] || login_rc="$HOME/.profile"
add_hook "$login_rc"
# Non-login interactive shells that tools may spawn.
add_hook "$HOME/.bashrc"

# ---------------------------------------------------------------------------
# Prime dependency caches. The repository currently ships no package manifest;
# these guards keep the warm-up useful as skills grow scripts of their own.
# ---------------------------------------------------------------------------
prime_dependencies() {
  cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"

  if [ -f package-lock.json ]; then
    log "package-lock.json found, running npm ci"
    npm ci --no-audit --no-fund || die "npm ci failed"
  elif [ -f package.json ]; then
    log "package.json found, running npm install"
    npm install --no-audit --no-fund || die "npm install failed"
  else
    log "no Node manifest, skipping npm install"
  fi

  if [ -f uv.lock ] && command -v uv >/dev/null 2>&1; then
    log "uv.lock found, running uv sync"
    uv sync || die "uv sync failed"
  elif [ -f requirements.txt ]; then
    log "requirements.txt found, installing with pip --user"
    python3 -m pip install --user --no-input -r requirements.txt || die "pip install failed"
  else
    log "no Python manifest, skipping Python dependency install"
  fi

  if [ -f docker-compose.yml ] || [ -f compose.yaml ] || [ -f docker-compose.yaml ]; then
    log "compose file found, pre-pulling images into the snapshot"
    docker compose pull --ignore-pull-failures || warn "docker compose pull did not complete cleanly"
  else
    log "no compose file, skipping image pre-pull"
  fi
}

prime_dependencies

# ---------------------------------------------------------------------------
# healthcheck: assert the environment works the way a task in this repo needs.
#
#   1. the authoring toolchain is on PATH,
#   2. the checkout is a usable git work tree,
#   3. .mcp.json parses and every ${VAR} it interpolates is populated,
#   4. every HTTP MCP server in it completes an authenticated `initialize`
#      JSON-RPC handshake.
#
# (4) is the real gate: it proves the RESTRICTED network policy allows the hosts
# AND that the tokens are valid. It polls indefinitely on transient faults (the
# launch owns the timeout) but fails fast on 401/403, which no amount of waiting
# will clear.
# ---------------------------------------------------------------------------
healthcheck() {
  log "healthcheck: verifying toolchain"
  local tool
  for tool in git curl node npm python3 jq yq; do
    command -v "$tool" >/dev/null 2>&1 || die "healthcheck: required tool '$tool' is not on PATH"
    log "healthcheck:   $tool -> $(command -v "$tool")"
  done

  log "healthcheck: verifying git work tree"
  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "healthcheck: $REPO_ROOT is not a git work tree"
  log "healthcheck:   HEAD $(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

  log "healthcheck: language runtimes smoke test"
  node -e 'process.stdout.write("node ok\n")' >/dev/null || die "healthcheck: node failed to execute"
  python3 -c 'pass' || die "healthcheck: python3 failed to execute"

  if [ ! -f "$MCP_CONFIG" ]; then
    warn "healthcheck: $MCP_CONFIG is absent; skipping MCP server verification"
    log "healthcheck: OK"
    return 0
  fi

  jq -e . "$MCP_CONFIG" >/dev/null 2>&1 || die "healthcheck: $MCP_CONFIG is not valid JSON"
  log "healthcheck: $MCP_CONFIG parses; servers: $(jq -r '(.mcpServers // {}) | keys | join(", ")' "$MCP_CONFIG")"

  log "healthcheck: probing MCP servers (polling until they answer)"
  local attempt=0 rc
  while :; do
    attempt=$((attempt + 1))
    MCP_CONFIG="$MCP_CONFIG" python3 - <<'PY'
import json, os, re, sys, urllib.error, urllib.request

PLACEHOLDER = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
FATAL, TRANSIENT = 2, 3

try:
    with open(os.environ["MCP_CONFIG"], encoding="utf-8") as fh:
        config = json.load(fh)
except (OSError, ValueError) as exc:
    print(f"  cannot read .mcp.json: {exc}")
    sys.exit(FATAL)

servers = config.get("mcpServers") or {}
http_servers = {
    name: spec
    for name, spec in servers.items()
    if (spec.get("type") or "http") == "http" and spec.get("url")
}
if not http_servers:
    print("  no HTTP MCP servers declared, nothing to probe")
    sys.exit(0)

missing = set()


def resolve(text):
    def repl(match):
        key = match.group(1)
        value = os.environ.get(key, "")
        if not value:
            missing.add(key)
        return value

    return PLACEHOLDER.sub(repl, text)


handshake = json.dumps(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "air-startup-healthcheck", "version": "1"},
        },
    }
).encode()

targets = []
for name, spec in http_servers.items():
    url = resolve(spec["url"])
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    for key, value in (spec.get("headers") or {}).items():
        headers[key] = resolve(str(value))
    targets.append((name, url, headers))

if missing:
    # An empty secret is a configuration problem, not a readiness problem.
    print("  unpopulated variables referenced by .mcp.json: " + ", ".join(sorted(missing)))
    sys.exit(FATAL)

exit_code = 0
for name, url, headers in targets:
    request = urllib.request.Request(url, data=handshake, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8", "replace")
        try:
            payload = json.loads(body.partition("data:")[2] if body.lstrip().startswith("event:") else body)
        except ValueError:
            payload = None
        if isinstance(payload, dict) and "result" in payload:
            info = payload["result"].get("serverInfo") or {}
            print(f"  {name}: OK ({info.get('name', 'unknown')} {info.get('version', '')})".rstrip())
        elif "result" in body:
            print(f"  {name}: OK (handshake accepted, non-JSON transport framing)")
        else:
            print(f"  {name}: HTTP {response.status} but no JSON-RPC result; retrying")
            exit_code = max(exit_code, TRANSIENT)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            print(f"  {name}: HTTP {exc.code} - the token for this server is missing, "
                  f"invalid or lacks permissions")
            exit_code = FATAL
        else:
            print(f"  {name}: HTTP {exc.code}; retrying")
            exit_code = max(exit_code, TRANSIENT)
    except Exception as exc:  # network not up yet, DNS, proxy, timeout
        print(f"  {name}: not reachable yet ({type(exc).__name__}: {exc}); retrying")
        exit_code = max(exit_code, TRANSIENT)

sys.exit(exit_code)
PY
    rc=$?
    case "$rc" in
      0)
        log "healthcheck: all MCP servers answered the initialize handshake"
        break
        ;;
      2)
        die "healthcheck: MCP configuration is broken (see above) - fix the token/config, it will not become ready on its own"
        ;;
      *)
        log "healthcheck: MCP servers not ready (attempt $attempt); retrying in 5s"
        sleep 5
        ;;
    esac
  done

  log "healthcheck: OK"
}

# No long-running server belongs to this repository, so nothing is started in the
# background here; the snapshot only captures files anyway.
if [ -n "$WARMUP" ]; then
  log "warmup run: gating completion on healthcheck"
  healthcheck
else
  log "task run: skipping the blocking healthcheck so the task starts immediately"
fi

log "startup complete"
