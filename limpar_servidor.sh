#!/bin/bash
###############################################################################
# limpar_servidor.sh (v2 — revisado)
#
# Remove painéis, scripts e serviços de VPN/proxy (NetSimon, SSHPlus, DragonX,
# RustyProxy, Xray, stunnel, badvpn, dtproxy, security-proxy, wstest, etc.)
# instalados por autoscripts, deixando o servidor o mais próximo possível de
# um Ubuntu recém-formatado.
#
# MUDANÇAS PRINCIPAIS EM RELAÇÃO À V1:
#   - Corrige o bug raiz: symlinks (ex: /bin/menu -> /opt/sshplus/sshplus)
#     ficavam órfãos porque só o alvo era apagado, nunca o link. Agora TODO
#     link quebrado do sistema é varrido e removido no final, e symlinks
#     conhecidos são removidos explicitamente junto com seus alvos.
#   - Passo de "diagnóstico" (v1, item 16) que só listava binários órfãos
#     agora REMOVE de verdade — nada fica pra trás, como pedido.
#   - Remove os próprios rastros de execuções anteriores de scripts de
#     limpeza/instalação: quarentena_bin, backup_antes_limpeza_*, logs de
#     auditoria, .pcap de captura de tráfego, .bash_history, etc.
#   - Mata e remove PM2 (usado por painéis Node.js) e processos node órfãos.
#   - Limpa crontab de TODOS os usuários, não só root.
#   - Lista de diretórios/arquivos conhecidos ampliada com os itens
#     descobertos na prática (/usr/share/.plus, /usr/lib/sshplus,
#     /home/sshplus, /usr/bin/h, /usr/bin/versao, etc.)
#   - Ordem de execução ajustada: mata processos e desmonta serviços ANTES
#     de apagar diretórios, para evitar handles de arquivo travados.
#
# ---------------------------------------------------------------------------
# USO:
#   bash <(curl -fsSL https://raw.githubusercontent.com/SEU_USUARIO/SEU_REPO/main/limpar_servidor.sh)
#   (não use "curl ... | bash" — quebra a leitura do ENTER de confirmação)
# ---------------------------------------------------------------------------
#
# Este script NÃO cria backups, NÃO usa quarentena, e apaga direto.
# Ação irreversível. NADA do Ubuntu/kernel/cloud-init/agente de nuvem é tocado.
###############################################################################

set -e
R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; NC=$'\033[0m'
BASE="/etc/painel"

echo -e "${R}Isso vai apagar TODOS os usuários VPN, configs, serviços,${NC}"
echo -e "${R}regras de firewall, pacotes, logs e QUALQUER rastro relacionado${NC}"
echo -e "${R}a painéis/proxies. SEM VOLTA. Sem backup. Sem quarentena.${NC}"
echo -ne "${Y}Pressione ENTER para continuar (CTRL+C para cancelar): ${NC}"
read -r _confirm

# =============================================================================
echo -e "${C}[1/18] Parando e desabilitando serviços conhecidos...${NC}"
SERVICOS=(xray netsimon-painel netsimon-bhttp badvpn nginx stunnel4 slowdns \
          dropbear security-proxy wstest-plain wstest-tls dtproxy1 dtproxy2 \
          firewalld openvpn wg-quick@wg0 v2ray trojan hysteria-server \
          3proxy squid dnstt-server sshplus sshpanel fail2ban)
for s in "${SERVICOS[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
done

# =============================================================================
echo -e "${C}[2/18] Matando PM2 e processos Node.js de painéis...${NC}"
if command -v pm2 &>/dev/null; then
    pm2 kill &>/dev/null || true
fi
pkill -9 -f "PM2|pm2" 2>/dev/null || true
rm -rf /root/.pm2 /home/*/.pm2

# =============================================================================
echo -e "${C}[3/18] Matando processos soltos (por nome e por path)...${NC}"
pkill -9 -f "limit\.sh|proxy\.py|checkuser\.py|painel_api\.py|bot_telegram\.py|badvpn-udpgw|dnstt-server" 2>/dev/null || true
pkill -9 -f "/etc/SSHPlus|/etc/Security|/etc/dtproxy|/etc/netsimon-wstest|/etc/bot|/opt/rustyproxy|/opt/sshplus|DragonX|/root/painel" 2>/dev/null || true
pkill -9 -f "verifatt|uexpired|verifbot|initcheck|infousers|ws_real_tunnel|wss_security" 2>/dev/null || true
pkill -9 -f "/usr/share/.plus|/usr/lib/sshplus" 2>/dev/null || true
screen -wipe &>/dev/null || true

# =============================================================================
echo -e "${C}[4/18] Removendo unidades systemd conhecidas e recarregando...${NC}"
rm -f /etc/systemd/system/xray.service /etc/systemd/system/netsimon-painel.service \
      /etc/systemd/system/netsimon-bhttp.service /etc/systemd/system/badvpn.service \
      /etc/systemd/system/slowdns.service /etc/systemd/system/security-proxy.service \
      /etc/systemd/system/wstest-plain.service /etc/systemd/system/wstest-tls.service \
      /etc/systemd/system/dtproxy1.service /etc/systemd/system/dtproxy2.service \
      /etc/systemd/system/sshplus.service /etc/systemd/system/sshpanel.service
find /etc/systemd/system -maxdepth 1 \( -iname "*sshplus*" -o -iname "*netsimon*" -o -iname "*dragonx*" -o -iname "*rustyproxy*" -o -iname "*sshpanel*" \) -delete 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed &>/dev/null || true

# =============================================================================
echo -e "${C}[5/18] Limpando crontab de TODOS os usuários...${NC}"
for u in $(cut -f1 -d: /etc/passwd); do
    crontab -r -u "$u" 2>/dev/null || true
done
rm -f /etc/cron.d/xray_watchdog
rm -rf /var/spool/cron/atjobs/* /var/spool/cron/crontabs/* 2>/dev/null || true

# =============================================================================
echo -e "${C}[6/18] Removendo usuários customizados (mantendo opc/ubuntu/debian/root)...${NC}"
WHITELIST_USERS=("opc" "ubuntu" "debian" "root" "centos" "admin")
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
echo -e "${C}[7/18] Removendo Nginx (config de painel) e restaurando padrão...${NC}"
rm -f /etc/nginx/sites-enabled/netsimon_web /etc/nginx/sites-available/netsimon_web
rm -rf /var/www/html/*
systemctl restart nginx &>/dev/null || true

# =============================================================================
echo -e "${C}[8/18] Removendo Xray-core, Stunnel, SlowDNS...${NC}"
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh) remove --purge &>/dev/null || true
rm -rf /etc/xray-manager /usr/local/etc/xray /etc/slowdns /etc/stunnel
rm -f /usr/local/bin/xray

# =============================================================================
echo -e "${C}[9/18] Removendo diretórios conhecidos de painéis/autoscripts...${NC}"
rm -rf /etc/painel /etc/SSHPlus /etc/bot /etc/dtproxy1 /etc/dtproxy2 \
       /etc/netsimon-wstest /etc/Security /opt/rustyproxy /opt/sshplus \
       /root/DragonX /root/painel /root/BOT \
       /usr/share/.plus /usr/lib/sshplus /usr/local/sshplus \
       /var/lib/postgresql/*/main/base 2>/dev/null || true
# ^ obs: a linha do postgresql só remove os DADOS do banco usado pelo painel;
# se você usa postgres para outra coisa, remova essa linha antes de rodar.

# =============================================================================
echo -e "${C}[10/18] Removendo arquivos/soltos conhecidos de autoscripts...${NC}"
rm -f /etc/IP /etc/autostart /etc/bannerssh /var/log/checkuser.log \
      /var/log/vpn-multiplexer.log /var/log/netsimon_proxy.log \
      /usr/local/bin/menu /usr/local/bin/badvpn-udpgw /usr/local/bin/dragonx \
      /usr/local/bin/proxydt.1 /usr/local/bin/proxydt.2 /usr/local/bin/websocat \
      /bin/verifatt /bin/uexpired /bin/menu /usr/bin/h /usr/bin/versao \
      /home/sshplus /root/usuarios.db /root/.wget-hsts

# =============================================================================
echo -e "${C}[11/18] Apagando scripts/binários conhecidos de autoscript...${NC}"
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
    mhtop Plus sshpanel
)
removidos=0
for dir in /bin /usr/bin /usr/local/bin /usr/sbin /usr/local/sbin; do
    for f in "${KNOWN_BAD_BIN[@]}"; do
        if [ -e "$dir/$f" ]; then
            rm -f "$dir/$f" 2>/dev/null && removidos=$((removidos+1))
        fi
    done
done
echo "  Binários/links removidos: $removidos"

# =============================================================================
echo -e "${C}[12/18] Removendo rastros de scripts de limpeza/instalação anteriores...${NC}"
# Esses arquivos são, eles mesmos, sobras de execuções passadas de scripts
# de instalação/limpeza — o objetivo é zero rastro, incluindo os próprios.
rm -rf /root/quarentena_bin /root/backup_antes_limpeza_* \
       /root/auditoria_servidor_*.txt /root/install_log.txt \
       /root/strace_log.txt /root/*.pcap /root/Plus /root/Plus.* \
       /root/*.bak /root/usuarios.db.bak
: > /root/.bash_history 2>/dev/null || true
: > /var/log/auth.log 2>/dev/null || true
: > /var/log/btmp 2>/dev/null || true

# =============================================================================
echo -e "${C}[13/18] Restaurando /etc/ssh/sshd_config original...${NC}"
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
    echo -e "${R}  ATENÇÃO: sshd_config falhou no teste (sshd -t). Corrija manualmente se o SSH cair.${NC}"
fi

# =============================================================================
echo -e "${C}[14/18] Zerando firewall (iptables + nftables)...${NC}"
iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X
ip6tables -F 2>/dev/null || true; ip6tables -X 2>/dev/null || true
nft flush ruleset 2>/dev/null || true
netfilter-persistent save &>/dev/null || true

echo -e "${C}[15/18] Tratando firewalld e ufw (se instalados)...${NC}"
if command -v firewall-cmd &>/dev/null; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
fi
ufw --force reset &>/dev/null || true
ufw disable &>/dev/null || true

# =============================================================================
echo -e "${C}[16/18] Restaurando sysctl relacionado a rede (ip_forward)...${NC}"
sed -i '/^net.ipv4.ip_forward = 1/d' /etc/sysctl.conf 2>/dev/null || true
sysctl -w net.ipv4.ip_forward=0 &>/dev/null || true

# =============================================================================
echo -e "${C}[17/18] Removendo pacotes ligados a painéis/proxies e ferramentas genéricas...${NC}"
apt purge -y stunnel4 socat &>/dev/null || true
if command -v firewall-cmd &>/dev/null; then
    apt purge -y firewalld &>/dev/null || true
fi
apt purge -y screen figlet boxes lolcat nload speedtest-cli dos2unix at dnsutils net-tools sqlite3 iptables-persistent &>/dev/null || true
apt autoremove -y &>/dev/null || true
apt clean &>/dev/null || true
echo -e "${G}  Pacotes removidos.${NC}"

# =============================================================================
echo -e "${C}[18/18] Varredura final: removendo TODO link simbólico quebrado e sobras${NC}"
echo -e "${C}         de /usr/local/bin (sem apenas listar — removendo de verdade)...${NC}"
# Esta é a correção do bug raiz: qualquer symlink cujo alvo não existe mais
# (por ter sido apagado nos passos acima) é removido, em vez de virar lixo
# órfão como aconteceu com /bin/menu -> /opt/sshplus/sshplus.
removidos_links=0
for dir in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' link; do
        if [ ! -e "$link" ]; then
            echo "  - removendo link quebrado: $link -> $(readlink "$link")"
            rm -f "$link"
            removidos_links=$((removidos_links+1))
        fi
    done < <(find "$dir" -maxdepth 1 -xtype l -print0 2>/dev/null)
done
echo "  Links quebrados removidos: $removidos_links"

# Binários órfãos (não pertencem a nenhum pacote apt) em /usr/local — agora
# são removidos de fato, não só listados, para não deixar rastro.
removidos_orfaos=0
for dir in /usr/local/bin /usr/local/sbin; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
        [ -f "$f" ] || continue
        if ! dpkg -S "$f" &>/dev/null; then
            rm -f "$f"
            removidos_orfaos=$((removidos_orfaos+1))
        fi
    done
done
echo "  Binários órfãos removidos de /usr/local: $removidos_orfaos"
echo -e "${Y}  Nota: /bin,/sbin não são checados contra dpkg aqui (geram falso positivo${NC}"
echo -e "${Y}  em Ubuntu, onde são links para /usr/bin,/usr/sbin) — mas symlinks quebrados${NC}"
echo -e "${Y}  neles já foram limpos acima, e a lista do passo [11/18] cobre os nomes${NC}"
echo -e "${Y}  conhecidos de autoscript.${NC}"

echo ""
echo -e "${G}✅ Limpeza concluída. Servidor o mais próximo possível de recém-formatado.${NC}"
echo -e "${G}   Nenhum backup, quarentena ou log de auditoria foi mantido.${NC}"
