#!/usr/bin/env bash
set -euo pipefail

# ────────────────────────────────────────────────────────────────
# setup-bevy-codegraph.sh
# 创建一个新的 Bevy 项目，同时为 pi AI agent 配置 CodeGraph 知识图谱
#
# 用法: ./setup-bevy-codegraph.sh
#
# 效果:
#   <project-name>/
#   ├── src/main.rs              ← 你的游戏代码
#   ├── Cargo.toml               ← 已添加最新 bevy 依赖
#   ├── .gitignore               ← deps/ 已排除
#   ├── .codegraph/              ← CodeGraph 索引（你的代码 + Bevy）
#   ├── .mcp.json                ← pi MCP 配置，指向 CodeGraph 索引
#   ├── CONTEXT.md               ← AI 上下文，介绍如何使用 CodeGraph
#   └── deps/bevy/               ← Bevy 源码（嵌入式 git 仓库）
#       ├── .codegraph/          ← Bevy 的 CodeGraph 索引（由 init 创建）
#       └── crates/...
# ────────────────────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}⟹${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }

read -p "Enter new project name: " PROJECT_NAME
if [ -z "$PROJECT_NAME" ]; then
  echo "Error: project name cannot be empty."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(pwd)/$PROJECT_NAME"

# ── 检查前置条件 ─────────────────────────────────────────────

info "Checking prerequisites..."

if ! command -v cargo &>/dev/null; then
  echo "Error: cargo not found. Install Rust first: https://rustup.rs"
  exit 1
fi

if ! command -v codegraph &>/dev/null; then
  warn "codegraph not on PATH. Trying npx fallback..."
  if ! npx @colbymchenry/codegraph --version &>/dev/null 2>&1; then
    echo ""
    echo "Error: codegraph not available. Install it first:"
    echo "  curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh"
    exit 1
  fi
  CODEGRAPH_CMD="npx @colbymchenry/codegraph"
else
  CODEGRAPH_CMD="codegraph"
fi

CG_VERSION=$($CODEGRAPH_CMD version 2>/dev/null || $CODEGRAPH_CMD --version 2>/dev/null || echo "unknown")
ok "cargo found"
ok "codegraph found ($CG_VERSION)"

# ── 步骤1: cargo new ─────────────────────────────────────────

info "Creating Rust project: ${BOLD}$PROJECT_NAME${NC}"
cargo new "$PROJECT_NAME"
cd "$PROJECT_DIR"
ok "Rust project created"

# ── 步骤2: 查询最新 Bevy release 版本 ────────────────────────

info "Querying latest Bevy release version from crates.io..."

# 策略: 优先 cargo search，失败则 fallback 到 crates.io API，再失败则用已知版本
LATEST_BEVY=""

if [ -z "$LATEST_BEVY" ]; then
  # fallback: cargo search
  LATEST_BEVY=$(cargo search bevy --registry crates-io --limit 1 2>/dev/null | head -1 | sed -n 's/.*bevy = "\([^"]*\)".*/\1/p' || echo "")
fi

if [ -z "$LATEST_BEVY" ]; then
  LATEST_BEVY="0.18.1"
  warn "Could not query crates.io, using known version v$LATEST_BEVY"
fi

ok "Latest Bevy release: ${BOLD}v$LATEST_BEVY${NC}"

# ── 步骤3: 添加 Bevy 依赖 + dev/release 特性配置 ──────────

info "Adding bevy = \"$LATEST_BEVY\" to Cargo.toml..."
cargo add bevy@"$LATEST_BEVY"

# 添加 fast-dev 特性: dev 模式用 dynamic_link 加速编译，release 模式静态链接
# usage: cargo dev   (等同 cargo run --features fast-dev)
#        cargo build --release  (release 模式下默认不使用 fast-dev，即静态链接)
cat >> Cargo.toml << 'EOF'

# =============================================
# Compilation optimization profiles
# =============================================
#   cargo dev              → dynamic linking (fast compile, day-to-day work)
#   cargo run              → no dynamic link (works but slower compile)
#   cargo build --release  → fully static binary
[features]
fast-dev = ["bevy/dynamic_linking"]

[profile.dev.package."*"]
opt-level = 3

[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
strip = "debuginfo"
EOF

ok "Bevy $LATEST_BEVY + fast-dev feature added"

# ── 步骤4: 克隆 Bevy 源码（嵌入式仓库，用于 CodeGraph 索引） ─

info "Cloning Bevy source into ${BOLD}deps/bevy/${NC}..."

mkdir -p deps
if [ -d "deps/bevy/.git" ]; then
  warn "deps/bevy already exists, skipping clone"
else
  git clone --depth 1 --filter=blob:none --branch "v$LATEST_BEVY" \
    --no-checkout https://github.com/bevyengine/bevy.git deps/bevy

  # sparse checkout: 只检出 CodeGraph 需要的目录（跳过 assets/ docs/ 等非源码目录）
  cd deps/bevy
  git sparse-checkout set \
    crates/ \
    src/ \
    examples/ \
    Cargo.toml \
    Cargo.lock
  git checkout
  cd "$PROJECT_DIR"
  ok "Bevy source cloned (tag: v$LATEST_BEVY, shallow + partial)"
fi

# ── 步骤5: 创建 .cargo/config.toml（dev/release 编译工作流） ──

info "Creating .cargo/config.toml with dev/release workflow..."
mkdir -p .cargo
cat > .cargo/config.toml << 'EOF'
[alias]
# Development build: run with bevy dynamic linking for fast iteration
#   cargo dev
dev = "run --features fast-dev"
EOF
ok ".cargo/config.toml created — \"cargo dev\" for fast dev, \"cargo build --release\" for static binary"


# ── 步骤6: 配置 .gitignore ─────────────────────────────────

if ! grep -q "^deps/$" .gitignore 2>/dev/null; then
  cat >> .gitignore << EOF

# Bevy source for CodeGraph indexing (embedded git repo)
deps/
.codegraph/
EOF
  ok ".gitignore updated: deps/ excluded from git tracking"
else
  ok ".gitignore already configured"
fi

# ── 步骤7: 初始化 CodeGraph（多仓库工作区） ──────────────────

info "Initializing CodeGraph at project root..."
$CODEGRAPH_CMD init
ok "CodeGraph initialized — indexing your code + Bevy together"

# ── 步骤8: 生成 .mcp.json（pi 通过 MCP 连接 CodeGraph） ──────

info "Generating .mcp.json for pi..."

cat > .mcp.json << EOF
{
  "mcpServers": {
    "codegraph-bevy": {
      "command": "codegraph",
      "args": ["serve", "--mcp", "--path", "."],
      "directTools": true
    }
  }
}
EOF
ok ".mcp.json created — pi will auto-connect to CodeGraph MCP server"

# ── 步骤9: 生成 CONTEXT.md（pi AI 的 CodeGraph 使用指南） ────

info "Generating CONTEXT.md..."

cat > CONTEXT.md << CONTEXTEOF
# $PROJECT_NAME — Bevy Project with CodeGraph Knowledge Base

This project has a **CodeGraph** knowledge graph indexing both your game code and the Bevy engine source code.

**CodeGraph index location:** \`./.codegraph/\`

## Available CodeGraph Tools

These tools are available as direct pi tools (via MCP, configured in \`.mcp.json\`):

| Tool | Purpose |
|------|---------|
| \`codegraph_explore\` | **(PRIMARY)** One-shot exploration — symbol source + call paths grouped by file. Use for "how does X work", architecture questions, or before editing. |
| \`codegraph_node\` | Single symbol's full source + caller/callee trail, or read a file with dependents. |
| \`codegraph_search\` | Quick symbol lookup by name (location + signature). |
| \`codegraph_callers\` | Find all call sites of a function/method. |
| \`codegraph_callees\` | Find what a function/method calls. |
| \`codegraph_impact\` | Blast radius analysis — what breaks if you change a symbol. |
| \`codegraph_files\` | Indexed file structure (faster than filesystem listing). |

## Bevy Crates Indexed

The Bevy source lives at \`deps/bevy/\` and its key crates include:

- \`bevy_app\` — App builder, Plugin lifecycle
- \`bevy_ecs\` — ECS: World, Entity, Component, System, Query, Schedule
- \`bevy_render\` — Rendering pipeline, extract/prepare/queue phases
- \`bevy_asset\` — Asset system, handles, loaders, servers
- \`bevy_math\` — Math types (Vec3, Quat, Mat4, etc.)
- \`bevy_reflect\` — Reflection, serialization, type info
- \`bevy_core_pipeline\` — Core render graph pipeline
- \`bevy_pbr\` — PBR rendering, materials, lights
- \`bevy_sprite\` — 2D sprite rendering
- \`bevy_ui\` — UI system
- \`bevy_input\` — Input handling
- \`bevy_time\` — Time, timers, stopwatch
- \`bevy_window\` — Window management
- \`bevy_transform\` — Transform, GlobalTransform, hierarchy
- \`bevy_scene\` — Scene system

## Usage Pattern

When writing Bevy code, **query the CodeGraph first** before reading source files.
Use \`codegraph_explore\` with Bevy symbol names to get exact source code and call paths in one call.

### Examples

\`\`\`
codegraph_explore "Commands spawn entity"
codegraph_explore "Query get component World"
codegraph_explore "App add_systems Plugin"
codegraph_callers "bevy_ecs::world::World::spawn"
codegraph_impact "bevy::prelude::Component"
codegraph_node "bevy_app::App::run"
\`\`\`

### Cross-referencing

Since both your game code and Bevy are in the same index, you can:

- \`codegraph_callers "bevy_ecs::system::Commands::spawn"\` — see where YOUR code calls spawn
- \`codegraph_impact "bevy_ecs::component::Component"\` — see which types in YOUR project implement Component
- \`codegraph_explore "MyPlugin build (bevy_app) App"\` — trace from your plugin into Bevy internals

The index auto-syncs on file changes — no manual re-index needed.

## Compilation Workflow

This project uses a custom Cargo feature + alias setup to balance compile speed and binary size:

| Command | Mode | Linking | Use case |
|---------|------|---------|----------|
| \`cargo dev\` | debug | **dynamic** (fast) | Day-to-day development |
| \`cargo run\` | debug | static (slower) | Fallback if you forget \`dev\` |
| \`cargo build --release\` | release | **static** | Production / shipping |

- \`cargo dev\` is an alias for \`cargo run --features fast-dev\` (configured in \`.cargo/config.toml\`)
- The \`fast-dev\` feature enables \`bevy/dynamic_link\`, which significantly reduces compile time
  during development by linking Bevy as a shared library
- Release builds intentionally do NOT use \`fast-dev\`, producing a fully static single binary
CONTEXTEOF
ok "CONTEXT.md created — AI will know how to use CodeGraph for this project"

# ── 步骤10: 验证索引状态 ──────────────────────────────────────

info "Verifying CodeGraph index..."
$CODEGRAPH_CMD status 2>&1 || warn "Run 'codegraph status' manually to verify"

# ── 汇总 ──────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    All done! 🎉                        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Project:${NC}      $PROJECT_NAME"
echo -e "  ${BOLD}Bevy:${NC}         v$LATEST_BEVY"
echo -e "  ${BOLD}Bevy source:${NC}  deps/bevy/ (embedded git repo)"
echo -e "  ${BOLD}CodeGraph:${NC}     $PROJECT_DIR/.codegraph/"
echo ""
echo -e "  ${BOLD}Generated files:${NC}"
echo -e "    .mcp.json           — pi MCP server config (connects CodeGraph)"
echo -e "    CONTEXT.md          — AI agent context (how to use CodeGraph)"
echo -e "    .cargo/config.toml  — Cargo alias for dev/release workflow"
echo -e "    .gitignore          — excludes deps/ from git"
echo ""
echo -e "  ${BOLD}Compilation workflow:${NC}"
echo -e "    ${CYAN}cargo dev${NC}              — debug + dynamic linking (fastest for dev)"
echo -e "    ${CYAN}cargo run${NC}              — debug + static linking"
echo -e "    ${CYAN}cargo build --release${NC}  — release + static linking (shipping)"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    1. cd $PROJECT_NAME"
echo "    2. Open in pi: pi"
echo "    3. Try querying Bevy internals:"
echo "       codegraph_explore \"Query World system\""
echo "       codegraph_explore \"Commands spawn bundle\""
echo "       codegraph_callers \"bevy_ecs::system::Commands::spawn\""
echo ""
echo -e "  ${YELLOW}Note:${NC} The index auto-syncs on file changes."
echo "  Run 'codegraph status' any time to check index health."
echo ""

