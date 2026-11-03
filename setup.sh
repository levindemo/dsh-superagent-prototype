#!/usr/bin/env bash
# ============================================================
#  dsh-superagent 一键环境配置脚本 (Bash)
#  适用: Linux / macOS / WSL / Git Bash (Windows)
#  功能: 环境检查 → .npmrc → pnpm install → build → test
# ============================================================
set -euo pipefail

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()   { echo -e "${CYAN}[${1}]${NC} ${*:2}"; }
ok()    { echo -e "  ${GREEN}✅${NC} $*"; }
warn()  { echo -e "  ${YELLOW}⚠️${NC} $*"; }
err()   { echo -e "  ${RED}❌${NC} $*"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}  dsh-superagent 环境配置${NC}"
echo -e "${BLUE}============================================================${NC}\n"

# ---------- 1. 检查 Node.js ----------
log "1/6" "检查 Node.js 和 pnpm"
command -v node >/dev/null 2>&1 || err "未找到 Node.js，请安装 Node.js 22.19+ 或 24+"
NODE_VER="$(node -v)"
echo "  Node.js: $NODE_VER"

if ! command -v pnpm >/dev/null 2>&1; then
    warn "pnpm 未安装，正在安装..."
    npm install -g pnpm@11.7.0 || err "pnpm 安装失败"
fi
PNPM_VER="$(pnpm -v)"
ok "pnpm: $PNPM_VER"

# ---------- 2. 创建 .npmrc ----------
log "2/6" "配置 .npmrc"
cat > ".npmrc" << 'EOF'
# dsh-superagent npm/pnpm registry config
registry=https://registry.npmjs.org/

auto-install-peers=true
strict-peer-dependencies=false
shamefully-hoist=true
package-import-method=auto
EOF
ok "已创建 .npmrc"

# ---------- 3. 测试 registry 连通性 ----------
log "3/6" "测试 npm registry 连通性"
REGISTRY_USED="https://registry.npmjs.org/"
if ! pnpm view zod version --registry "$REGISTRY_USED" >/dev/null 2>&1; then
    warn "公共 npmjs registry 访问失败，尝试淘宝镜像..."
    REGISTRY_USED="https://registry.npmmirror.com/"
    if ! pnpm view zod version --registry "$REGISTRY_USED" >/dev/null 2>&1; then
        err "所有 registry 均不可用，请检查网络连接"
    fi
    # 写入镜像地址
    cat > ".npmrc" << EOF
registry=${REGISTRY_USED}

auto-install-peers=true
strict-peer-dependencies=false
shamefully-hoist=true
package-import-method=auto
EOF
    ok "切换到 $REGISTRY_USED"
else
    ok "公共 npmjs registry 正常"
fi

# ---------- 4. 测试 deepseek-ai 包 ----------
log "4/6" "检查 @deepseek-ai 包可用性"
DEEPSEEK_OK=false

if pnpm view @deepseek-ai/dsh-agent@0.2.1-alpha.2 version --registry "$REGISTRY_USED" >/dev/null 2>&1; then
    DEEPSEEK_OK=true
    ok "@deepseek-ai 包可从当前 registry 获取"
else
    warn "当前 registry 找不到 @deepseek-ai 包（私有包）"
    echo
    echo "  如果你有 DeepSeek 私有 registry 地址，请输入："
    echo "  (例如 https://npm.deepseek.com/)"
    read -rp "  私有 registry 地址 (直接回车跳过): " PRIVATE_REGISTRY

    if [[ -n "$PRIVATE_REGISTRY" ]]; then
        warn "测试 $PRIVATE_REGISTRY ..."
        if pnpm view @deepseek-ai/dsh-agent@0.2.1-alpha.2 version --registry "$PRIVATE_REGISTRY" >/dev/null 2>&1; then
            DEEPSEEK_OK=true
            ok "私有 registry 可用，更新 .npmrc"
            cat > ".npmrc" << EOF
registry=${PRIVATE_REGISTRY}

auto-install-peers=true
strict-peer-dependencies=false
shamefully-hoist=true
package-import-method=auto
EOF
        else
            warn "该 registry 也找不到包"
        fi
    fi
fi

if ! $DEEPSEEK_OK; then
    echo
    echo -e "  ${YELLOW}============================================================${NC}"
    echo -e "  ${YELLOW}⚠️  私有包不可用，后续安装会失败${NC}"
    echo "  你可以："
    echo "  1. 联系 DeepSeek 获取私有 registry 地址和 token"
    echo "  2. 如果同事机器已有 node_modules，复制过来"
    echo "  3. 跳过安装，先看代码"
    echo -e "  ${YELLOW}============================================================${NC}"
    echo
    read -rp "  是否继续尝试安装? (y/N): " CONTINUE
    if [[ ! "${CONTINUE,,}" =~ ^y(es)?$ ]]; then
        echo "  已取消。"
        exit 0
    fi
fi

# ---------- 5. pnpm install ----------
log "5/6" "pnpm install"
echo
pnpm install --no-frozen-lockfile 2>&1 | tee install.log
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    echo
    err "依赖安装失败！请查看 install.log，很可能是私有包 registry 未配置"
fi
ok "依赖安装成功"

# ---------- 6. build + typecheck + test ----------
log "6/6" "构建项目"
echo

echo "--- TypeScript 类型检查 ---"
if pnpm typecheck 2>&1 | tee typecheck.log; then
    ok "typecheck 通过"
else
    warn "typecheck 有错误，但继续..."
fi

echo
echo "--- 运行测试 ---"
if pnpm test 2>&1 | tee test.log; then
    ok "测试通过"
else
    warn "部分测试失败"
fi

echo
echo "--- 构建 ---"
if pnpm build 2>&1 | tee build.log; then
    ok "构建成功"
else
    err "构建失败"
fi

# ---------- 完成 ----------
echo
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ✅ 全部完成！${NC}"
echo "   - node_modules/     已安装"
echo "   - lib/              已构建"
echo "   - typecheck + test  已运行"
echo -e "${GREEN}============================================================${NC}"
echo
echo "  后续启动 DSH 服务需要 (Linux/macOS/WSL)："
echo "    1. npm install -g @deepseek-ai/dsh@0.2.1-rc.3"
echo "    2. dsh superagent --from-default-profile web"
echo "    3. dsh plugin --profile superagent add \"link:$ROOT\""
echo "    4. scripts/dsh-superagent start"
echo
