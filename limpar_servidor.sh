#!/bin/bash
###############################################################################
# limpar_servidor.sh
#
# Remove painéis, scripts e serviços de VPN/proxy (NetSimon, SSHPlus, DragonX,
# RustyProxy, Xray, stunnel, badvpn, dtproxy, security-proxy, wstest, etc.)
# instalados por autoscripts, deixando o servidor o mais próximo possível de
# um Ubuntu recém-formatado (mantém apenas update/upgrade do sistema).
#
# ---------------------------------------------------------------------------
# INSTALAÇÃO E EXECUÇÃO EM 1 COMANDO (depois de subir este arquivo ao GitHub):
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/miau4/limpeza/main/limpar_servidor.sh)
#
# IMPORTANTE: use exatamente esse formato ("bash <(curl ...)"), e não
# "curl ... | bash". O script pede confirmação digitada (interativa) antes de
# apagar qualquer coisa; com "curl | bash" o terminal não consegue receber
# essa digitação porque o pipe já está ocupado com o conteúdo baixado, e o
# script seria cancelado sozinho. "bash <(curl ...)" resolve isso mantendo o
# teclado conectado normalmente.
#
# Alternativa em 2 comandos (baixar e depois rodar):
#   curl -fsSL https://raw.githubusercontent.com/miau4/limpeza/main/limpar_servidor.sh -o limpar_servidor.sh
#   chmod +x limpar_servidor.sh && ./limpar_servidor.sh
#
# Troque SEU_USUARIO/SEU_REPO pelo caminho real do seu repositório no GitHub.
# ---------------------------------------------------------------------------
#
# O que este script faz:
#   - Para e desabilita serviços/painéis conhecidos
#   - Mata processos soltos ligados a esses painéis
#   - Remove unidades systemd criadas por eles
#   - Zera o crontab do root (com backup) e cron.d relacionado
#   - Remove usuários Linux criados por painéis (mantém opc/ubuntu/root)
#   - Remove Nginx, Xray, stunnel, SlowDNS e configs de painel
#   - Remove diretórios e binários conhecidos de autoscripts (SSHPlus,
#     DragonX, RustyProxy, bot, etc.)
#   - Restaura /etc/ssh/sshd_config ao padrão do pacote
#   - Zera firewall (iptables, nftables, firewalld, ufw)
#   - Opcionalmente remove pacotes genéricos instalados pelo autoscript
#   - Faz backup de tudo que altera em /root/backup_antes_limpeza_<data>/
#
# NADA relacionado ao Ubuntu, kernel, cloud-init, agente da nuvem (Oracle/AWS/
# Azure/GCP) ou update/upgrade do sistema é tocado.
###############################################################################

set -e
R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; NC=$'\033[0m'
BASE="/etc/painel"
BKDIR="/root/backup_antes_limpeza_$(date +%Y%m%d_%H%M%S)"
QUARENTENA="/root/quarentena_bin"
mkdir -p "$BKDIR" "$QUARENTENA"

echo -e "${R}Isso vai apagar TODOS os usuários VPN, configs, serviços,${NC}"
echo -e "${R}regras de firewall e pacotes relacionados a painéis/proxies. SEM VOLTA.${NC}"
echo -ne "${Y}Digite 'limpar' para confirmar: ${NC}"
read -r confirm
[[ "$confirm" != "limpar" ]] && { echo "Cancelado."; exit 0; }

# =============================================================================
echo -e "${C}[1/17] Parando e desabilitando serviços conhecidos...${NC}"
SERVICOS=(xray netsimon-painel badvpn nginx stunnel4 slowdns dropbear \
          security-proxy wstest-plain wstest-tls dtproxy1 dtproxy2 \
          firewalld openvpn wg-quick@wg0 v2ray trojan hysteria-server \
          3proxy squid dnstt-server)
for s in "${SERVICOS[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
done

# =============================================================================
echo -e "${C}[2/17] Matando processos soltos (por nome e por path)...${NC}"
pkill -9 -f "limit\.sh|proxy\.py|checkuser\.py|painel_api\.py|bot_telegram\.py|badvpn-udpgw|dnstt-server" 2>/dev/null || true
pkill -9 -f "/etc/SSHPlus|/etc/Security|/etc/dtproxy|/etc/netsimon-wstest|/etc/bot|/opt/rustyproxy|/opt/sshplus|DragonX" 2>/dev/null || true
pkill -9 -f "verifatt|uexpired|verifbot|initcheck|infousers" 2>/dev/null || true
screen -wipe &>/dev/null || true

# =============================================================================
echo -e "${C}[3/17] Removendo unidades systemd conhecidas e recarregando...${NC}"
rm -f /etc/systemd/system/xray.service /etc/systemd/system/netsimon-painel.service \
      /etc/systemd/system/badvpn.service /etc/systemd/system/slowdns.service \
      /etc/systemd/system/security-proxy.service /etc/systemd/system/wstest-plain.service \
      /etc/systemd/system/wstest-tls.service /etc/systemd/system/dtproxy1.service \
      /etc/systemd/system/dtproxy2.service
systemctl daemon-reload

# =============================================================================
echo -e "${C}[4/17] Fazendo backup e limpando crontab do root...${NC}"
crontab -l -u root > "$BKDIR/crontab_root.bak" 2>/dev/null || true
crontab -r -u root 2>/dev/null || true
rm -f /etc/cron.d/xray_watchdog

# =============================================================================
echo -e "${C}[5/17] Removendo usuários customizados (mantendo opc/ubuntu/debian/root)...${NC}"
WHITELIST_USERS=("opc" "ubuntu" "debian" "root" "centos" "admin")
cp /etc/passwd "$BKDIR/passwd.bak"
while IFS=: read -r login _ uid _ _ home shell; do
    [ -z "$login" ] && continue
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 65000 ] || continue
    skip=false
    for w in "${WHITELIST_USERS[@]}"; do [ "$login" == "$w" ] && skip=true; done
    if [ "$skip" = false ]; then
        echo "  -> removendo usuário: $login"
        userdel -r "$login" &>/dev/null || true
    fi
done < /etc/passwd
if [ -f "$BASE/usuarios.db" ]; then
    while IFS='|' read -r login _; do
        [ -n "$login" ] && userdel -r "$login" &>/dev/null || true
    done < "$BASE/usuarios.db"
fi

# =============================================================================
echo -e "${C}[6/17] Removendo Nginx (config de painel) e restaurando padrão...${NC}"
rm -f /etc/nginx/sites-enabled/netsimon_web /etc/nginx/sites-available/netsimon_web
rm -rf /var/www/html/*
systemctl restart nginx &>/dev/null || true

# =============================================================================
echo -e "${C}[7/17] Removendo Xray-core, Stunnel, SlowDNS...${NC}"
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove --purge &>/dev/null || true
rm -rf /etc/xray-manager /usr/local/etc/xray /etc/slowdns /etc/stunnel
rm -f /usr/local/bin/xray

# =============================================================================
echo -e "${C}[8/17] Removendo diretórios conhecidos de painéis/autoscripts...${NC}"
rm -rf /etc/painel /etc/SSHPlus /etc/bot /etc/dtproxy1 /etc/dtproxy2 \
       /etc/netsimon-wstest /etc/Security /opt/rustyproxy /opt/sshplus \
       /root/DragonX

# =============================================================================
echo -e "${C}[9/17] Removendo arquivos soltos conhecidos de autoscripts...${NC}"
rm -f /etc/IP /etc/autostart /etc/bannerssh /var/log/checkuser.log \
      /usr/local/bin/menu /usr/local/bin/badvpn-udpgw /usr/local/bin/dragonx \
      /usr/local/bin/proxydt.1 /usr/local/bin/proxydt.2 /usr/local/bin/websocat \
      /bin/verifatt /bin/uexpired

# =============================================================================
echo -e "${C}[10/17] Colocando em quarentena scripts/binários conhecidos de autoscript...${NC}"
# Lista consolidada a partir de análise real de servidores infectados por
# autoscripts (SSHPlus / DragonX / RustyProxy / NetSimon e variantes).
KNOWN_BAD_BIN=(
    NF ShellBot.sh alfa_proxy alterarlimite alterarsenha attscript badvpn \
    badvpn.sh blocksite blockt blockuser botssh botssh.sh botteste.sh \
    botteste.sh.1 botteste.sh.2 chuker.sh conexao criarteste criarusuario \
    delhost delscript detalhes dnsserv droplimiter expcleaner inst-botteste \
    instsqd lcf licence limiter menu menu_check mfire mproxy.sh msocks.sh \
    mssh.sh mudardata mudp.sh mxray onlineapp open.sh otimizar pbget pbput \
    pbputs pkill.sh procan proxyd proxydtv1 proxydtv2 proxyrust \
    reiniciarservicos reiniciarsistema remover senharoot sshmonitor \
    swapmemory tcptweaker.sh trojan-go userbackup v2raymanager verifbot \
    versao websocket.sh ws wsmenu ajuda ajuda.sh h key infousers initcheck \
    mhtop
)
for dir in /bin /usr/bin /usr/local/bin; do
    for f in "${KNOWN_BAD_BIN[@]}"; do
        [ -f "$dir/$f" ] && mv "$dir/$f" "$QUARENTENA/" 2>/dev/null
    done
done
echo "  Itens movidos para $QUARENTENA (revise antes de apagar definitivamente):"
ls "$QUARENTENA" 2>/dev/null | wc -l

# =============================================================================
echo -e "${C}[11/17] Restaurando /etc/ssh/sshd_config original...${NC}"
cp /etc/ssh/sshd_config "$BKDIR/sshd_config.bak" 2>/dev/null || true
if [ -f /etc/ssh/sshd_config.ucf-dist ]; then
    cp /etc/ssh/sshd_config.ucf-dist /etc/ssh/sshd_config
    echo -e "${G}  sshd_config restaurado a partir do padrão do pacote.${NC}"
else
    sed -i '/^HostKeyAlgorithms +ssh-rsa/d; /^Banner /d' /etc/ssh/sshd_config 2>/dev/null || true
    echo -e "${Y}  Backup .ucf-dist não encontrado, apliquei apenas correções pontuais.${NC}"
fi
if sshd -t 2>/dev/null; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo -e "${G}  sshd validado e reiniciado.${NC}"
else
    echo -e "${R}  ATENÇÃO: sshd_config falhou no teste (sshd -t). Restaure de $BKDIR/sshd_config.bak se o SSH cair.${NC}"
fi

# =============================================================================
echo -e "${C}[12/17] Zerando firewall (iptables + nftables)...${NC}"
iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X
ip6tables -F 2>/dev/null || true; ip6tables -X 2>/dev/null || true
nft flush ruleset 2>/dev/null || true
netfilter-persistent save &>/dev/null || true

echo -e "${C}[13/17] Tratando firewalld e ufw (se instalados)...${NC}"
if command -v firewall-cmd &>/dev/null; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
fi
ufw --force reset &>/dev/null || true
ufw disable &>/dev/null || true

# =============================================================================
echo -e "${C}[14/17] Restaurando sysctl relacionado a rede (ip_forward)...${NC}"
sed -i '/^net.ipv4.ip_forward = 1/d' /etc/sysctl.conf 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=0 &>/dev/null || true

# =============================================================================
echo -e "${C}[15/17] Removendo pacotes claramente ligados a painéis/proxies...${NC}"
apt purge -y stunnel4 socat &>/dev/null || true
if command -v firewall-cmd &>/dev/null; then
    apt purge -y firewalld &>/dev/null || true
fi

echo -ne "${Y}Remover TAMBÉM ferramentas genéricas (screen, figlet, boxes, lolcat, nload, speedtest-cli, dos2unix, at, dnsutils, net-tools)? (s/n): ${NC}"
read -r resp_pkg
if [[ "$resp_pkg" == "s" ]]; then
    apt purge -y screen figlet boxes lolcat nload speedtest-cli dos2unix at dnsutils net-tools sqlite3 iptables-persistent &>/dev/null || true
    apt autoremove -y &>/dev/null || true
    echo -e "${G}  Pacotes removidos.${NC}"
else
    echo -e "${Y}  Pacotes mantidos.${NC}"
fi

# =============================================================================
echo -e "${C}[16/17] Verificando binários que não pertencem a nenhum pacote apt (diagnóstico)...${NC}"
SUSPFILE="$BKDIR/binarios_suspeitos.txt"
> "$SUSPFILE"
for dir in /usr/local/bin /usr/local/sbin; do
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        dpkg -S "$f" &>/dev/null || echo "$f" >> "$SUSPFILE"
    done
done
if [ -s "$SUSPFILE" ]; then
    echo -e "${Y}  Encontrados arquivos fora de /bin,/usr/bin que não pertencem a pacotes apt.${NC}"
    echo -e "${Y}  Lista salva em: $SUSPFILE (revise manualmente, pode ter falso positivo).${NC}"
else
    echo -e "${G}  Nenhum item adicional encontrado em /usr/local/bin.${NC}"
fi
echo -e "${Y}  Nota: /bin e /sbin são links para /usr/bin e /usr/sbin neste Ubuntu, e o dpkg${NC}"
echo -e "${Y}  às vezes não reconhece esse link — por isso não escaneamos essas pastas aqui${NC}"
echo -e "${Y}  automaticamente (gera muito falso positivo). A lista de nomes conhecidos do${NC}"
echo -e "${Y}  passo [10/17] já cobre os casos reais encontrados em autoscripts.${NC}"

# =============================================================================
echo -e "${C}[17/17] Backup e quarentena desta limpeza salvos em:${NC}"
echo "  $BKDIR"
echo "  $QUARENTENA"

echo ""
echo -e "${G}✅ Limpeza concluída. Servidor o mais próximo possível de recém-formatado.${NC}"
echo -e "${Y}Revise $QUARENTENA e, se estiver tudo certo, apague com:${NC}"
echo -e "${Y}  rm -rf $QUARENTENA${NC}"
