#!/usr/bin/env bash
# ============================================================
#  dsh-superagent 完整一键脚本
#  阶段: install → typecheck → test → build → (可选) start DSH
#  适用: WSL / Linux / macOS / Git Bash
# ============================================================
set -euo pipefail

# ------ 彩色输出 ------
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; C='\033[0;36m'; N='\033[0m'
hr()   { echo -e "${B}────────────────────────────────────────────────────────────${N}"; }
head() { echo -e "\n${G}============================================================${N}\n${G}  $*${N}\n${G}============================================================${N}\n"; }
log()  { echo -e "${C}[${STEP}/${TOTAL}]${N} $*"; STEP=$((STEP+1)); }
ok()   { echo -e "  ${G}✔${N} $*"; }
warn() { echo -e "  ${Y}⚠${N} $*"; }
err()  { echo -e "  ${R}✖${N} $*"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 默认只做 install+build；加 --with-dsh 也启动 DSH
WITH_DSH=false
for a in "$@"; do
    [[ "$a" == "--with-dsh" ]] && WITH_DSH=true
done

TOTAL=6; STEP=1

head "dsh-superagent 一键流水线"
echo "  项目路径:  $ROOT"
echo "  Node:      $(node -v 2>&1 || echo '未安装')"
echo "  pnpm:      $(pnpm -v 2>&1 || echo '未安装')"
echo "  启动 DSH:  $( $WITH_DSH && echo '是' || echo '否 (用 --with-dsh 启用)' )"
hr

# ============================================================
# 1. 环境检查
# ============================================================
log "环境检查"
command -v node >/dev/null 2>&1 || err "Node.js 未安装 (需要 22.19+ 或 24+)"
NODE_MAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
NODE_MINOR=$(node -v | sed 's/v//' | cut -d. -f2)
if [[ "$NODE_MAJOR" -lt 22 ]] || { [[ "$NODE_MAJOR" -eq 22 ]] && [[ "$NODE_MINOR" -lt 19 ]]; }; then
    warn "Node.js $(node -v) 低于 22.19+ 要求，某些特性可能不支持"
fi
ok "Node.js $(node -v)"

if ! command -v pnpm >/dev/null 2>&1; then
    warn "pnpm 未安装，正在安装..."
    npm install -g pnpm@11.7.0 || err "pnpm 安装失败"
fi
ok "pnpm $(pnpm -v)"

# ============================================================
# 2. pnpm install
# ============================================================
log "pnpm install"
if [[ -d "node_modules" ]]; then
    ok "node_modules 已存在，跳过 (用 --force 重新安装)"
else
    # 如果有私有 registry 需求，在此修改 .npmrc
    if [[ ! -f ".npmrc" ]]; then
        cat > ".npmrc" << 'EOF'
registry=https://registry.npmjs.org/
auto-install-peers=true
strict-peer-dependencies=false
shamefully-hoist=true
EOF
        ok "已创建 .npmrc"
    fi
    pnpm install --no-frozen-lockfile 2>&1 | tee install.log
    [[ ${PIPESTATUS[0]} -eq 0 ]] || err "依赖安装失败 (见 install.log)"
    ok "依赖安装完成 ($(ls node_modules/@deepseek-ai 2>/dev/null | wc -l) 个 dsh 包)"
fi

# ============================================================
# 3. TypeScript 类型检查
# ============================================================
log "TypeScript 类型检查"
if pnpm typecheck 2>&1 | tee typecheck.log; then
    ok "typecheck 通过"
else
    warn "typecheck 有错误 (见 typecheck.log)，继续..."
fi

# ============================================================
# 4. 测试
# ============================================================
log "运行测试"
if pnpm test 2>&1 | tee test.log; then
    ok "全部测试通过 ✨"
else
    warn "部分测试失败 (见 test.log)"
fi

# ============================================================
# 5. 构建
# ============================================================
log "构建 lib/"
if pnpm build 2>&1 | tee build.log; then
    ok "构建完成 ($(find lib -name '*.js' | wc -l) 个 JS 文件, $(find lib -name '*.d.ts' | wc -l) 个声明)"
else
    err "构建失败 (见 build.log)"
fi

# ============================================================
# 6. (可选) 启动 DSH
# ============================================================
if $WITH_DSH; then
    log "启动 DSH (--with-dsh)"

    if ! command -v dsh >/dev/null 2>&1; then
        warn "dsh 未安装，安装 @deepseek-ai/dsh@0.2.1-rc.3 ..."
        npm install -g "@deepseek-ai/dsh@0.2.1-rc.3" || err "dsh 安装失败"
    fi
    ok "dsh $(dsh --version 2>&1)"

    PROFILE="superagent"
    DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
    PROFILE_DIR="$DSH_HOME/profiles/$PROFILE"
    STATE_DIR="$DSH_HOME/state/$PROFILE"
    PORT=3082

    mkdir -p "$STATE_DIR"

    # 创建 profile
    if [[ ! -d "$PROFILE_DIR" ]]; then
        warn "创建 profile $PROFILE ..."
        dsh superagent --from-default-profile web --dump-config >/dev/null 2>&1 || true
    fi

    # cordis.patch.yml
    PATCH="$PROFILE_DIR/cordis.patch.yml"
    if [[ ! -f "$PATCH" ]] || ! grep -q "stateDir" "$PATCH"; then
        warn "写入 cordis.patch.yml ..."
        cat > "$PATCH" << EOF
- id: webserver
  config:
    host: 127.0.0.1
    port: $PORT
- id: dsh-superagent
  config:
    stateDir: $STATE_DIR
EOF
    fi

    # link bundle
    dsh plugin --profile "$PROFILE" add "link:$ROOT" 2>&1 || true

    ok "配置完成，启动 dsh --profile $PROFILE"
    echo ""
    echo "  面板地址: http://127.0.0.1:$PORT/"
    echo "  (Ctrl+C 停止)"
    echo ""
    exec dsh --profile "$PROFILE"
else
    ok "跳过 DSH 启动 (用 $0 --with-dsh 一并启动)"
fi

# ============================================================
# 总结
# ============================================================
head "完成 🎉"
echo "  项目路径:   $ROOT"
echo "  构建产物:   lib/ ($(find lib -type f | wc -l) 个文件)"
echo "  node_modules: $(du -sh node_modules 2>/dev/null | cut -f1 || echo '?')"
echo ""
echo "  启动 DSH:   $0 --with-dsh"
echo "  仅 build:   pnpm build"
echo "  仅 test:    pnpm test"
echo ""
hr
