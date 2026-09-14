#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────
# CORES
# ─────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────
# CONFIGURAÇÕES
# ─────────────────────────────────────────────────────────────
APP_NAME="nexyra-link"
APP_DIR="/opt/nexyra-link"
JS_FILE="monitor.js"
CONFIG_FILE="$APP_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
MENU_CMD="/usr/local/bin/nexyra"
BACKUP_DIR="$APP_DIR/backups"
LOG_DIR="$APP_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# URLs fixas dos endpoints
GET_USERS_ENDPOINT="get_users_with_servers.php"
GET_NODES_ENDPOINT="get_nodes_1.php"
UPDATE_NODE_ENDPOINT="update_node_1.php"
UPDATE_SERVER_ENDPOINT="update_server_status.php"

# ─────────────────────────────────────────────────────────────
# FUNÇÃO DE LOG
# ─────────────────────────────────────────────────────────────
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO PARA INSTALAR DEPENDÊNCIAS BÁSICAS
# ─────────────────────────────────────────────────────────────
install_basic_deps() {
    echo -e "${BLUE}📦 Instalando dependências básicas...${NC}"
    apt update -y > /dev/null 2>&1 || true
    apt install -y curl wget jq > /dev/null 2>&1
    
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  jq não pôde ser instalado via apt, tentando instalar manualmente...${NC}"
        curl -L -o /usr/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 2>/dev/null
        chmod +x /usr/bin/jq
    fi
    
    if command -v jq >/dev/null 2>&1; then
        echo -e "${GREEN}✅ jq instalado com sucesso${NC}"
    else
        echo -e "${RED}❌ Falha ao instalar jq${NC}"
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO PARA VALIDAR CHAVE DE INSTALAÇÃO
# ─────────────────────────────────────────────────────────────
validate_installation_key() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║      VALIDAÇÃO DE INSTALAÇÃO          ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Digite a chave de instalação:${NC}"
    read -p "🔑 Chave: " INSTALL_KEY
    
    if [ -z "$INSTALL_KEY" ]; then
        error "Chave não pode estar vazia"
    fi
    
    echo ""
    echo -e "${CYAN}📡 Validando chave...${NC}"
    
    # URL base para validação
    BASE_URL="https://api.nexyratech.com.br/netpulse"
    
    # Valida a chave e obtém o link base
    RESPONSE=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"key\":\"$INSTALL_KEY\"}" \
        --max-time 10 \
        "$BASE_URL/validate_key.php")
    
    # Verifica se a consulta foi bem sucedida
    if [ $? -ne 0 ] || [ -z "$RESPONSE" ]; then
        error "Falha ao conectar com o servidor"
    fi
    
    # Extrai o status e o link base
    if command -v jq >/dev/null 2>&1; then
        STATUS=$(echo "$RESPONSE" | jq -r '.status // "error"')
        
        if [ "$STATUS" != "success" ]; then
            MESSAGE=$(echo "$RESPONSE" | jq -r '.message // "Chave inválida"')
            echo -e "${RED}❌ $MESSAGE${NC}"
            error "Validação falhou"
        fi
        
        BASE_LINK=$(echo "$RESPONSE" | jq -r '.base_link // empty')
        
    else
        if echo "$RESPONSE" | grep -q '"status"[[:space:]]*:[[:space:]]*"success"'; then
            STATUS="success"
            BASE_LINK=$(echo "$RESPONSE" | grep -o '"base_link"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"base_link"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
            
            if [ -z "$BASE_LINK" ]; then
                error "Link base não encontrado na resposta"
            fi
        else
            ERROR_MSG=$(echo "$RESPONSE" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"message"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
            ERROR_MSG=${ERROR_MSG:-"Chave inválida"}
            echo -e "${RED}❌ $ERROR_MSG${NC}"
            error "Validação falhou"
        fi
    fi
    
    if [ -z "$BASE_LINK" ]; then
        error "Link base não encontrado na resposta"
    fi
    
    # Remove barra no final se existir
    BASE_LINK=$(echo "$BASE_LINK" | sed 's:/*$::')
    
    echo -e "${GREEN}✅ Chave validada com sucesso!${NC}"
    echo ""
    echo -e "${CYAN}📋 Link base: $BASE_LINK${NC}"
    echo ""
    
    # Monta as URLs completas
    GET_USERS_API="$BASE_LINK/$GET_USERS_ENDPOINT"
    GET_NODES_API="$BASE_LINK/$GET_NODES_ENDPOINT"
    UPDATE_NODE_API="$BASE_LINK/$UPDATE_NODE_ENDPOINT"
    UPDATE_SERVER_API="$BASE_LINK/$UPDATE_SERVER_ENDPOINT"
    
    echo -e "${CYAN}📋 URLs configuradas:${NC}"
    echo "  • GET Users: $GET_USERS_API"
    echo "  • GET Nodes: $GET_NODES_API"
    echo "  • UPDATE Node: $UPDATE_NODE_API"
    echo "  • UPDATE Server: $UPDATE_SERVER_API"
    echo ""
    
    # Testa rapidamente as URLs
    echo -e "${YELLOW}🔍 Testando conexão com as APIs...${NC}"
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GET_USERS_API" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "401" ]; then
        echo -e "  ✅ GET Users: $HTTP_CODE"
    else
        echo -e "  ⚠️  GET Users: $HTTP_CODE (possível erro)"
    fi
    
    sleep 2
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO PARA CRIAR ARQUIVO DE CONFIGURAÇÃO
# ─────────────────────────────────────────────────────────────
create_config_file() {
    log "📝 Criando arquivo de configuração..."
    
    cat > "$CONFIG_FILE" <<EOF
{
  "apis": {
    "get_users": "$GET_USERS_API",
    "get_nodes": "$GET_NODES_API",
    "update_node": "$UPDATE_NODE_API",
    "update_server": "$UPDATE_SERVER_API"
  },
  "check_interval_ms": 30000,
  "timeout_ms": 1500,
  "offline_threshold_ms": 60000,
  "max_concurrent": 10,
  "installation_key": "$INSTALL_KEY",
  "installed_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "server_ip": "$(hostname -I | awk '{print $1}')"
}
EOF
    
    log "✅ Arquivo de configuração criado"
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO PARA INSTALAR NODE.JS
# ─────────────────────────────────────────────────────────────
install_nodejs() {
    echo -e "${BLUE}📦 Instalando Node.js...${NC}"
    
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node -v)
        echo -e "${GREEN}✅ Node.js já instalado: $NODE_VERSION${NC}"
        return
    fi
    
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - > /dev/null 2>&1
    apt install -y nodejs > /dev/null 2>&1
    
    if command -v node >/dev/null 2>&1; then
        NODE_VERSION=$(node -v)
        echo -e "${GREEN}✅ Node.js $NODE_VERSION instalado${NC}"
    else
        error "Falha ao instalar Node.js"
    fi
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO DE LIMPEZA
# ─────────────────────────────────────────────────────────────
clean_installation() {
    echo -e "${YELLOW}🧹 Limpando instalação anterior...${NC}"
    
    if systemctl is-active --quiet nexyra-link 2>/dev/null; then
        systemctl stop nexyra-link
    fi
    
    if systemctl is-enabled --quiet nexyra-link 2>/dev/null; then
        systemctl disable nexyra-link
    fi
    
    rm -f "$SERVICE_FILE"
    
    if [ -d "$APP_DIR" ]; then
        echo -e "${BLUE}📦 Fazendo backup...${NC}"
        mkdir -p "$BACKUP_DIR"
        cp -r "$APP_DIR" "${BACKUP_DIR}/backup_${TIMESTAMP}" 2>/dev/null || true
    fi
    
    rm -rf "$APP_DIR"
    rm -f "$MENU_CMD"
    systemctl daemon-reload 2>/dev/null || true
    
    echo -e "${GREEN}✅ Limpeza concluída${NC}"
    sleep 2
}

# ─────────────────────────────────────────────────────────────
# FUNÇÃO DE DESINSTALAÇÃO
# ─────────────────────────────────────────────────────────────
uninstall() {
    clear
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║      DESINSTALAR NEXYRA LINK          ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Isso irá:${NC}"
    echo -e "  ${RED}•${NC} Parar o serviço"
    echo -e "  ${RED}•${NC} Remover todos os arquivos"
    echo -e "  ${RED}•${NC} Remover o comando 'nexyra'"
    echo ""
    read -p "❓ Tem certeza? (s/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        echo -e "${YELLOW}🗑️  Desinstalando...${NC}"
        
        if systemctl is-active --quiet nexyra-link 2>/dev/null; then
            systemctl stop nexyra-link
        fi
        
        if systemctl is-enabled --quiet nexyra-link 2>/dev/null; then
            systemctl disable nexyra-link
        fi
        
        rm -f "$SERVICE_FILE"
        rm -rf "$APP_DIR"
        rm -f "$MENU_CMD"
        
        systemctl daemon-reload
        
        sed -i '/# Nexyra Link/d' /root/.bashrc 2>/dev/null || true
        sed -i '/nexyra/d' /root/.bashrc 2>/dev/null || true
        
        echo -e "${GREEN}✅ Nexyra Link desinstalado com sucesso!${NC}"
        exit 0
    else
        echo -e "${BLUE}Desinstalação cancelada${NC}"
        sleep 2
        return
    fi
}

# ─────────────────────────────────────────────────────────────
# CRIAR ARQUIVO JS
# ─────────────────────────────────────────────────────────────
create_js_file() {
    log "📝 Criando arquivo monitor.js..."
    
    cat > "$APP_DIR/$JS_FILE" <<'EOF'
const { exec } = require("child_process");
const fs = require("fs");
const http = require("http");
const https = require("https");
const net = require("net");
const os = require("os");
const { promisify } = require("util");

const execAsync = promisify(exec);
const config = JSON.parse(fs.readFileSync("./config.json", "utf8"));

/* ================= CONFIG ================= */

const GET_NODES_API = config.apis.get_nodes;
const UPDATE_NODE_API = config.apis.update_node;
const GET_USERS_API = config.apis.get_users;
const UPDATE_SERVER_API = config.apis.update_server;

const CHECK_INTERVAL = config.check_interval_ms || 30000;
const TIMEOUT = 1500;
const MAX_CONCURRENT = 10;
const OFFLINE_THRESHOLD = 60000;

/* ================= ESTADO ================= */

const state = {
  nodes: new Map(),
  servers: new Map()
};

/* ================= IP LOCAL ================= */

function getLocalIP() {
  const nets = os.networkInterfaces();
  for (const name of Object.keys(nets)) {
    for (const net of nets[name]) {
      if (!net.internal && net.family === "IPv4") {
        return net.address;
      }
    }
  }
  return null;
}

const SERVER_IP = getLocalIP();

console.log("🚀 MONITOR INICIADO");
console.log("🌐 IP:", SERVER_IP);

/* ================= REQUEST ================= */

async function request(url, postData = null) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const client = parsed.protocol === "https:" ? https : http;

    const req = client.request({
      hostname: parsed.hostname,
      port: parsed.port || (parsed.protocol === "https:" ? 443 : 80),
      path: parsed.pathname + parsed.search,
      method: postData ? "POST" : "GET",
      headers: { "Content-Type": "application/json" },
      timeout: 5000
    }, res => {
      let data = "";
      res.on("data", chunk => data += chunk);
      res.on("end", () => {
        try { resolve(JSON.parse(data)); }
        catch { resolve(data); }
      });
    });

    req.on("error", reject);
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("Timeout"));
    });

    if (postData) req.write(JSON.stringify(postData));
    req.end();
  });
}

/* ================= TESTES ================= */

async function pingTest(host) {
  try {
    const cmd = process.platform === "win32"
      ? `ping -n 1 -w 1000 ${host}`
      : `ping -c 1 -W 1 ${host}`;

    await execAsync(cmd, { timeout: TIMEOUT });
    return true;
  } catch {
    return false;
  }
}

async function tcpTest(host, port = 80) {
  return new Promise(resolve => {
    const socket = new net.Socket();
    socket.setTimeout(TIMEOUT);

    socket.on("connect", () => {
      socket.destroy();
      resolve(true);
    });

    socket.on("error", () => resolve(false));
    socket.on("timeout", () => {
      socket.destroy();
      resolve(false);
    });

    socket.connect(port, host);
  });
}

async function testHost(ip, port = 80) {
  if (await pingTest(ip)) return true;
  if (await tcpTest(ip, port)) return true;
  return false;
}

/* ================= NODE ================= */

async function updateNode(node, isOnline) {
  const now = Date.now();

  if (!node.memory) {
    node.memory = {
      firstFail: null
    };
  }

  if (isOnline) {
    node.memory.firstFail = null;

    if (node.status !== "online") {
      node.status = "online";
      console.log(`🟢 NODE ${node.ip} ONLINE`);

      await request(UPDATE_NODE_API, {
        id: node.id,
        status: "online",
        last_online: new Date().toISOString()
      });
    }
    return;
  }

  if (!node.memory.firstFail) {
    node.memory.firstFail = now;
    console.log(`⚠ SUSPEITO ${node.ip}`);
  }

  if (now - node.memory.firstFail >= OFFLINE_THRESHOLD) {
    if (node.status !== "offline") {
      node.status = "offline";
      console.log(`🔴 NODE ${node.ip} OFFLINE`);

      await request(UPDATE_NODE_API, {
        id: node.id,
        status: "offline",
        last_check: new Date().toISOString()
      });
    }
  }
}

/* ================= SERVER ================= */

async function updateServer(server, isOnline) {
  server.online = isOnline;

  await request(UPDATE_SERVER_API, {
    uid: server.uid,
    is_online: isOnline ? 1 : 0,
    last_update: new Date().toISOString()
  });
}

/* ================= CONCORRÊNCIA ================= */

async function processInBatches(items, handler) {
  const queue = [...items];

  async function worker() {
    while (queue.length) {
      const item = queue.shift();
      await handler(item);
    }
  }

  const workers = [];
  for (let i = 0; i < MAX_CONCURRENT; i++) {
    workers.push(worker());
  }

  await Promise.all(workers);
}

/* ================= LOOP ================= */

async function run() {
  console.log("\n🔄 Ciclo:", new Date().toLocaleString("pt-BR"));

  const users = await request(GET_USERS_API);
  if (!Array.isArray(users)) return;

  for (const user of users) {
    if (user.monitoring_ip !== SERVER_IP) continue;

    let server = state.servers.get(user.uid);

    if (!server) {
      server = {
        uid: user.uid,
        ip: user.monitoring_ip,
        online: true
      };
      state.servers.set(user.uid, server);
    }

    const serverOnline = await testHost(server.ip);
    await updateServer(server, serverOnline);

    const nodes = await request(`${GET_NODES_API}?userId=${user.uid}`);
    if (!Array.isArray(nodes)) continue;

    const apiIds = new Set();

    for (const apiNode of nodes) {
      if (!apiNode.ip) continue;

      apiIds.add(apiNode.id);

      const existing = state.nodes.get(apiNode.id);

      if (!existing) {
        state.nodes.set(apiNode.id, { ...apiNode });
      } else if (existing.ip !== apiNode.ip || existing.port !== apiNode.port) {
        console.log(`🔄 IP alterado ${existing.ip} → ${apiNode.ip}`);

        existing.ip = apiNode.ip;
        existing.port = apiNode.port;
        existing.memory = null;

        // Teste imediato ao alterar IP
        const immediate = await testHost(existing.ip, existing.port || 80);
        existing.status = immediate ? "online" : "offline";

        await request(UPDATE_NODE_API, {
          id: existing.id,
          status: existing.status
        });
      }
    }

    for (const [id] of state.nodes) {
      if (!apiIds.has(id)) {
        state.nodes.delete(id);
      }
    }

    await processInBatches(nodes.filter(n => n.ip), async (apiNode) => {
      const node = state.nodes.get(apiNode.id);
      const isOnline = await testHost(node.ip, node.port || 80);
      await updateNode(node, isOnline);
    });
  }

  console.log("✅ Ciclo finalizado");
}

/* ================= START ================= */

async function init() {
  await run();
  setInterval(run, CHECK_INTERVAL);
}

init().catch(console.error);

process.on("SIGINT", () => {
  console.log("\n👋 Monitor encerrado");
  process.exit();
});
EOF

    log "✅ Arquivo monitor.js criado"
}

# ─────────────────────────────────────────────────────────────
# CRIAR SCRIPTS AUXILIARES
# ─────────────────────────────────────────────────────────────
create_aux_scripts() {
    log "📝 Criando scripts auxiliares..."
    
    cat > "$APP_DIR/start.sh" <<'EOF'
#!/bin/bash
echo -e "\033[0;32m▶️ Iniciando Nexyra Link...\033[0m"
systemctl start nexyra-link
sleep 2
if systemctl is-active --quiet nexyra-link; then
    echo -e "\033[0;32m✅ Serviço iniciado\033[0m"
else
    echo -e "\033[0;31m❌ Falha ao iniciar\033[0m"
fi
EOF

    cat > "$APP_DIR/stop.sh" <<'EOF'
#!/bin/bash
echo -e "\033[1;33m⏹️ Parando Nexyra Link...\033[0m"
systemctl stop nexyra-link
echo -e "\033[0;32m✅ Serviço parado\033[0m"
EOF

    cat > "$APP_DIR/restart.sh" <<'EOF'
#!/bin/bash
echo -e "\033[0;34m🔄 Reiniciando Nexyra Link...\033[0m"
systemctl restart nexyra-link
sleep 2
echo -e "\033[0;32m✅ Serviço reiniciado\033[0m"
EOF

    cat > "$APP_DIR/logs.sh" <<'EOF'
#!/bin/bash
echo -e "\033[0;36m📄 LOGS (Ctrl+C para sair)\033[0m"
echo ""
journalctl -u nexyra-link -f -n 50
EOF

    cat > "$APP_DIR/status.sh" <<'EOF'
#!/bin/bash
clear
echo "════════════════════════════════════════"
echo "        STATUS DO MONITOR"
echo "════════════════════════════════════════"
echo ""
if systemctl is-active --quiet nexyra-link; then
    echo "📊 Serviço: ATIVO"
else
    echo "📊 Serviço: INATIVO"
fi
echo ""
echo "Últimas 10 linhas:"
journalctl -u nexyra-link -n 10 --no-pager | tail -10
echo ""
read -p "Pressione Enter para voltar..."
EOF

    chmod +x "$APP_DIR"/*.sh
    log "✅ Scripts auxiliares criados"
}

# ─────────────────────────────────────────────────────────────
# CRIAR MENU PRINCIPAL
# ─────────────────────────────────────────────────────────────
create_menu() {
    log "📝 Criando menu principal..."
    
    cat > "$APP_DIR/menu.sh" <<'EOF'
#!/bin/bash
APP_DIR="/opt/nexyra-link"

while true; do
    clear
    echo "════════════════════════════════════════"
    echo "      NEXYRA LINK - MONITOR v3.1"
    echo "════════════════════════════════════════"
    echo ""
    echo "1) ▶️  INICIAR monitor"
    echo "2) ⏹️  PARAR monitor"
    echo "3) 🔄  REINICIAR monitor"
    echo "4) 📄  VER LOGS"
    echo "5) 📊  VER STATUS"
    echo "6) ⏱️  EDITAR INTERVALO"
    echo "7) 🔍  TESTAR APIs"
    echo "8) 📋  VER CONFIGURAÇÃO"
    echo "9) 🚀  ATIVAR AUTO START"
    echo "10) ❌ DESATIVAR AUTO START"
    echo "0) 🚪  SAIR"
    echo ""
    echo "11) HISTORICO LOCAL"
    echo "12) VERSAO E MIKROTIK"
    echo "Status: $(systemctl is-active nexyra-link)"
    echo ""
    read -p "👉 Escolha: " opt

    case $opt in
        1) cd "$APP_DIR" && ./start.sh ;;
        2) cd "$APP_DIR" && ./stop.sh ;;
        3) cd "$APP_DIR" && ./restart.sh ;;
        4) cd "$APP_DIR" && ./logs.sh ;;
        5) cd "$APP_DIR" && ./status.sh ;;
        6) 
            current=$(jq '.check_interval_ms' "$APP_DIR/config.json")
            current_min=$((current / 60000))
            echo "Atual: $current_min minutos"
            read -p "Novo intervalo (min): " min
            if [[ "$min" =~ ^[0-9]+$ ]] && [ "$min" -gt 0 ]; then
                ms=$((min * 60000))
                jq ".check_interval_ms=$ms" "$APP_DIR/config.json" > tmp && mv tmp "$APP_DIR/config.json"
                echo "✅ Alterado para $min minutos"
                echo "Reinicie o monitor (opção 3)"
            fi
            sleep 2
            ;;
        7) 
            GET_USERS=$(jq -r '.apis.get_users' "$APP_DIR/config.json")
            GET_NODES=$(jq -r '.apis.get_nodes' "$APP_DIR/config.json")
            echo "🔍 Testando APIs..."
            echo ""
            echo "GET Users: $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GET_USERS")"
            echo "GET Nodes: $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$GET_NODES")"
            read -p "Enter..."
            ;;
        8)
            echo "📋 CONFIGURAÇÃO ATUAL:"
            echo ""
            jq '.' "$APP_DIR/config.json"
            echo ""
            read -p "Enter..."
            ;;
        9) systemctl enable nexyra-link && echo "✅ Auto start ativado" && sleep 2 ;;
        10) systemctl disable nexyra-link && echo "❌ Auto start desativado" && sleep 2 ;;
        0) echo "Até logo!" && exit 0 ;;
        *) echo "Opção inválida" && sleep 2 ;;
    esac
done
EOF

    chmod +x "$APP_DIR/menu.sh"
    log "✅ Menu principal criado"
}

# ─────────────────────────────────────────────────────────────
# CRIAR ARQUIVO DE SERVIÇO SYSTEMD
# ─────────────────────────────────────────────────────────────
create_service_file() {
    log "📝 Criando arquivo de serviço systemd..."
    
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Nexyra Link Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node $APP_DIR/$JS_FILE
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nexyra-link

[Install]
WantedBy=multi-user.target
EOF

    log "✅ Arquivo de serviço criado"
}

# ─────────────────────────────────────────────────────────────
# CRIAR COMANDO DE MENU
# ─────────────────────────────────────────────────────────────
create_menu_command() {
    log "📝 Criando comando 'nexyra'..."
    
    cat > "$MENU_CMD" <<'EOF'
#!/bin/bash
/opt/nexyra-link/menu.sh
EOF

    chmod +x "$MENU_CMD"
    log "✅ Comando 'nexyra' criado"
}

# ─────────────────────────────────────────────────────────────
# CONFIGURAR AUTO COMPLETION
# ─────────────────────────────────────────────────────────────
setup_autocompletion() {
    if ! grep -q "# Nexyra Link" /root/.bashrc; then
        echo "" >> /root/.bashrc
        echo "# Nexyra Link" >> /root/.bashrc
        echo "alias nexyra='/usr/local/bin/nexyra'" >> /root/.bashrc
    fi
}

# ─────────────────────────────────────────────────────────────
# INICIAR SERVIÇO
# ─────────────────────────────────────────────────────────────
start_service() {
    log "🚀 Iniciando serviço..."
    
    systemctl daemon-reload
    systemctl enable nexyra-link
    systemctl start nexyra-link
    
    sleep 3
    
    if systemctl is-active --quiet nexyra-link; then
        log "✅ Serviço iniciado com sucesso"
    else
        warning "⚠️  Serviço pode não ter iniciado corretamente"
        systemctl status nexyra-link --no-pager
    fi
}

# ─────────────────────────────────────────────────────────────
# MOSTRA RESUMO DA INSTALAÇÃO
# ─────────────────────────────────────────────────────────────
show_summary() {
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    INSTALAÇÃO CONCLUÍDA COM SUCESSO   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}📋 INFORMAÇÕES:${NC}"
    echo -e "  • Diretório: ${CYAN}$APP_DIR${NC}"
    echo -e "  • Arquivo JS: ${CYAN}$JS_FILE${NC}"
    echo -e "  • Config: ${CYAN}$CONFIG_FILE${NC}"
    echo -e "  • Serviço: ${CYAN}nexyra-link${NC}"
    echo ""
    echo -e "${WHITE}📝 COMANDOS:${NC}"
    echo -e "  • Menu: ${YELLOW}nexyra${NC}"
    echo -e "  • Status: ${YELLOW}systemctl status nexyra-link${NC}"
    echo -e "  • Logs: ${YELLOW}journalctl -u nexyra-link -f${NC}"
    echo ""
    echo -e "${WHITE}🔗 APIs CONFIGURADAS:${NC}"
    echo -e "  • GET Users: ${CYAN}$GET_USERS_API${NC}"
    echo -e "  • GET Nodes: ${CYAN}$GET_NODES_API${NC}"
    echo -e "  • UPDATE Node: ${CYAN}$UPDATE_NODE_API${NC}"
    echo -e "  • UPDATE Server: ${CYAN}$UPDATE_SERVER_API${NC}"
    echo ""
    echo -e "${GREEN}✅ Monitor está rodando!${NC}"
    echo -e "${YELLOW}➡️  Digite 'nexyra' para acessar o menu${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────
# INSTALAÇÃO PRINCIPAL
# ─────────────────────────────────────────────────────────────
# Implementacao atual. As funcoes abaixo substituem as versoes legadas.
AGENT_VERSION="3.1.0"

install_basic_deps() {
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget jq iputils-ping nodejs npm ca-certificates
    command -v node >/dev/null 2>&1 || error "Node.js nao foi instalado"
    [ "$(node -p 'Number(process.versions.node.split(".")[0])')" -ge 18 ] || error "Node.js 18+ obrigatorio"
}

validate_installation_key() {
    clear
    echo "NEXYRA LINK v$AGENT_VERSION - VALIDACAO"
    read -r -p "URL da API [https://api.nexyratech.com.br/netpulse]: " BASE_LINK
    BASE_LINK=${BASE_LINK:-https://api.nexyratech.com.br/netpulse}; BASE_LINK=${BASE_LINK%/}
    read -r -p "Chave de instalacao: " INSTALL_KEY
    [ -n "$INSTALL_KEY" ] || error "Chave obrigatoria"
    RESPONSE=$(curl -sS --connect-timeout 8 --max-time 20 -H "Content-Type: application/json" -d "$(jq -nc --arg key "$INSTALL_KEY" '{key:$key}')" "$BASE_LINK/validate_key.php") || error "API indisponivel"
    RESPONSE=$(printf '%s' "$RESPONSE" | sed -n '/{/,$p')
    printf '%s' "$RESPONSE" | jq -e . >/dev/null 2>&1 || error "validate_key.php retornou uma resposta que nao e JSON: $RESPONSE"
    [ "$(printf '%s' "$RESPONSE" | jq -r 'if .success == true or .status == "success" then "true" else "false" end')" = "true" ] || error "$(printf '%s' "$RESPONSE" | jq -r '.message // .error // "Chave recusada"')"
    GET_USERS_API="$BASE_LINK/api.php?action=get_monitor_payload&key=$INSTALL_KEY"
    GET_NODES_API="$GET_USERS_API"
    UPDATE_NODE_API="$BASE_LINK/update_node_1.php"
    UPDATE_SERVER_API="$BASE_LINK/api.php?action=monitoring_heartbeat"
    PAYLOAD_RESPONSE=$(curl -sS --connect-timeout 8 --max-time 20 "$GET_USERS_API") || error "Falha ao consultar o payload"
    PAYLOAD_RESPONSE=$(printf '%s' "$PAYLOAD_RESPONSE" | sed -n '/{/,$p')
    printf '%s' "$PAYLOAD_RESPONSE" | jq -e . >/dev/null 2>&1 || error "api.php retornou uma resposta que nao e JSON: $PAYLOAD_RESPONSE"
    [ "$(printf '%s' "$PAYLOAD_RESPONSE" | jq -r '.success // false')" = "true" ] || error "$(printf '%s' "$PAYLOAD_RESPONSE" | jq -r '.message // .error // "Payload recusado"')"
    log "Chave e assinatura validadas"
}

create_config_file() {
    jq -n --arg b "$BASE_LINK" --arg k "$INSTALL_KEY" --arg v "$AGENT_VERSION" '{base_url:$b,key:$k,version:$v,check_interval_ms:30000,timeout_ms:2200,offline_threshold_ms:60000,max_concurrent:10,apis:{get_users:($b+"/api.php?action=get_monitor_payload&key="+$k),get_nodes:($b+"/api.php?action=get_monitor_payload&key="+$k),update_node:($b+"/update_node_1.php"),update_server:($b+"/api.php?action=monitoring_heartbeat")}}' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

clean_installation() {
    systemctl disable --now nexyra-link 2>/dev/null || true
    rm -f "$SERVICE_FILE" "$MENU_CMD"
    if [ -d "$APP_DIR" ]; then
        SAFE_BACKUP="/opt/nexyra-link-backup-$TIMESTAMP"; mkdir -p "$SAFE_BACKUP"
        for f in config.json node-state.json history-queue.json node-history.jsonl; do [ -f "$APP_DIR/$f" ] && cp -a "$APP_DIR/$f" "$SAFE_BACKUP/"; done
        log "Backup salvo em $SAFE_BACKUP"
    fi
    rm -rf "$APP_DIR"; systemctl daemon-reload
}

create_js_file() {
    log "Criando monitor de nodes e RouterOS"
    cat > "$APP_DIR/$JS_FILE" <<'EOF'
'use strict';
const fs=require('fs'),net=require('net'),{execFile}=require('child_process'),{RouterOSAPI}=require('node-routeros');
const dir='/opt/nexyra-link/',cfg=JSON.parse(fs.readFileSync(dir+'config.json','utf8')),base=cfg.base_url.replace(/\/$/,'');
const sf=dir+'node-state.json',qf=dir+'history-queue.json',hf=dir+'node-history.jsonl';
const read=(p,d)=>{try{return JSON.parse(fs.readFileSync(p,'utf8'))}catch{return d}},write=(p,v)=>{fs.writeFileSync(p+'.tmp',JSON.stringify(v));fs.renameSync(p+'.tmp',p)};
let states=read(sf,{}),queue=read(qf,[]),running=false;
async function req(url,opt={}){const c=new AbortController(),t=setTimeout(()=>c.abort(),15000);try{const r=await fetch(url,{...opt,signal:c.signal}),s=(await r.text()).replace(/^\uFEFF+/,'').trim(),j=s?JSON.parse(s):{};if(!r.ok||j.success===false)throw Error(j.message||j.error||('HTTP '+r.status));return j}finally{clearTimeout(t)}}
const post=(a,d)=>req(base+'/api.php?action='+a,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(d)}),update=d=>req(base+'/update_node_1.php',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({...d,key:cfg.key})}),payload=()=>req(base+'/api.php?action=get_monitor_payload&key='+encodeURIComponent(cfg.key));
const ping=h=>new Promise(ok=>execFile('ping',['-c','1','-W','2',h],{timeout:4000},e=>ok(!e))),tcp=(h,p)=>new Promise(ok=>{const s=new net.Socket();let done=false,end=v=>{if(!done){done=true;s.destroy();ok(v)}};s.setTimeout(cfg.timeout_ms||2200);s.once('connect',()=>end(true));s.once('timeout',()=>end(false));s.once('error',()=>end(false));s.connect(p,h)});
async function detect(h){if(await ping(h))return{online:true,port:null};for(const p of [80,443,22,8291,8728,8080,8443,53])if(await tcp(h,p))return{online:true,port:p};return{online:false,port:null}}
function archive(e){fs.appendFileSync(hf,JSON.stringify(e)+'\n');if(fs.statSync(hf).size>25*1024*1024){const x=fs.readFileSync(hf,'utf8').trim().split('\n').slice(-100000);fs.writeFileSync(hf+'.tmp',x.join('\n')+'\n');fs.renameSync(hf+'.tmp',hf)}}
async function flush(){while(queue.length)try{await update(queue[0]);queue.shift();write(qf,queue)}catch(e){console.error('Fila:',e.message);return}}
async function check(n,uid){const now=Date.now(),r=await detect(n.ip),old=states[n.id]||{status:n.status||'unknown',failed:null};let status='online',failed=null;if(!r.online){failed=old.failed||now;status=now-failed>=(cfg.offline_threshold_ms||60000)?'offline':old.status}const e={id:Number(n.id),uid,status,detected_port:r.port,checked_at:new Date().toISOString()};if(status!==old.status){queue.push(e);archive({...e,old_status:old.status});write(qf,queue)}else try{await update(e)}catch(x){console.error('Node '+n.id+':',x.message)}states[n.id]={status,failed};write(sf,states)}
async function pppoe(m){const ros=new RouterOSAPI({host:m.host,port:Number(m.port||8728),user:m.username,password:String(m.password),tls:Boolean(Number(m.use_ssl)),timeout:10,keepalive:false});try{await ros.connect();const rows=await ros.write('/ppp/active/print');return rows.map(x=>({username:x.name,address:x.address||null,uptime:x.uptime||null,caller_id:x['caller-id']||null,service:x.service||null}))}finally{try{ros.close()}catch{}}}
async function pool(items,n,fn){const q=[...items];await Promise.all(Array.from({length:Math.min(n,q.length)},async()=>{while(q.length)await fn(q.shift())}))}
async function run(){if(running)return;running=true;try{await flush();const d=await payload();await post('monitoring_heartbeat',{uid:d.user.uid,server_ip:d.request_ip});await pool(d.nodes||[],cfg.max_concurrent||10,n=>check(n,d.user.uid));await flush();if(!d.credentials_allowed&&(d.mikrotiks||[]).length)console.error('Credenciais bloqueadas para '+d.request_ip);for(const m of d.mikrotiks||[])if(m.password)try{await post('update_pppoe_clients',{key:cfg.key,mikrotik_id:m.id,clients:await pppoe(m)})}catch(e){console.error('MikroTik '+m.name+':',e.message);try{await post('mikrotik_error',{key:cfg.key,mikrotik_id:m.id,error:e.message})}catch{}}}catch(e){console.error(new Date().toISOString(),e.message)}finally{running=false}}
console.log('Nexyra Link Agent v'+cfg.version);run();setInterval(run,cfg.check_interval_ms||30000);
EOF
    cd "$APP_DIR"; npm init -y >/dev/null 2>&1
    npm install --omit=dev --save-exact node-routeros@1.6.9
    node --check "$APP_DIR/$JS_FILE" || error "monitor.js invalido"
}

install() {
    clear
    echo -e "${BLUE}🚀 Iniciando instalação do Nexyra Link Monitor${NC}"
    
    # Primeiro instala as dependências básicas
    install_basic_deps
    
    # Valida a chave e obtém o link base
    validate_installation_key
    
    # Limpa instalação anterior
    clean_installation
    
    # Cria diretórios
    mkdir -p "$APP_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    
    # Instala Node.js
    install_nodejs
    
    # Cria arquivos
    create_config_file
    create_js_file
    create_aux_scripts
    create_menu
    create_service_file
    create_menu_command
    
    # Configura auto completion
    setup_autocompletion
    
    # Inicia serviço
    start_service
    
    # Mostra resumo
    show_summary
}

# ─────────────────────────────────────────────────────────────
# MENU PRINCIPAL DO INSTALADOR
# ─────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║      NEXYRA LINK - INSTALADOR         ║${NC}"
        echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
        echo ""
        echo "1) 🚀 INSTALAR"
        echo "2) 🗑️  DESINSTALAR"
        echo "0) ❌ SAIR"
        echo ""
        read -p "👉 Escolha: " option
        
        case $option in
            1) install ;;
            2) uninstall ;;
            0) 
                echo -e "${GREEN}Até logo!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Opção inválida${NC}"
                sleep 2
                ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────
# EXECUTAR MENU PRINCIPAL
# ─────────────────────────────────────────────────────────────
main_menu
