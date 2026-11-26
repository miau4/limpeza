#!/bin/bash
###############################################################################
# limpar_servidor.sh (v3.1 — revisado)
#
# Remove painéis, scripts e serviços de VPN/proxy (NetSimon, SSHPlus, DragonX,
# RustyProxy, Xray, stunnel, badvpn, dtproxy, security-proxy, wstest, etc.)
# instalados por autoscripts, deixando o servidor o mais próximo possível de
# um Ubuntu recém-formatado.
#
# ---------------------------------------------------------------------------
# USO:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/miau4/limpeza/main/limpar_servidor.sh)
#
#   (não use "curl ... | bash" — quebra a leitura do ENTER de confirmação)
#
# OPÇÕES (variáveis de ambiente, todas opcionais):
#
#   RESET_SSHD=0          não restaura o sshd_config do pacote (só tira Banner e
#                         HostKeyAlgorithms +ssh-rsa). Padrão: 1 (restaura, mas
#                         DESFAZ sozinho se isso tirar seu login root/senha).
#   LIMPAR_POSTGRES=1     apaga os DADOS de TODOS os bancos PostgreSQL. Padrão: 0
#                         (na v2 isso era feito sempre, sem perguntar).
#   PURGAR_NGINX=1        desinstala o nginx por completo. Padrão: 0 (só remove
#                         o site do painel e restaura o site padrão).
#   RESET_SHELL_RC=1      recria /root/.bashrc e /root/.profile a partir de
#                         /etc/skel (padrão do Ubuntu). Padrão: 0 (só remove as
#                         linhas de banner/autoscript, mantendo suas outras
#                         customizações).
#
#   Exemplo: RESET_SSHD=0 PURGAR_NGINX=1 bash <(curl -fsSL URL)
# ---------------------------------------------------------------------------
#
# MUDANÇAS DA V3.1 EM RELAÇÃO À V3:
#   - NOVO (passo 2): remove UDP gateways (badvpn/udpgw) por ASSINATURA, não só
#     por nome. A v3 só conhecia "badvpn"; um serviço com outro nome (ex.:
#     sshorizon-udp-7300.service, binário /bin/sshorizon-udp) ficava de pé,
#     seguia ocupando a porta 7300 e o badvpn do painel nunca subia ("bind
#     failed" em loop). A assinatura é o ExecStart do unit / a linha de comando
#     do processo (udpgw, sshorizon, --max-connections-for-client). Remove o
#     unit, os drop-ins, o binário (se não for de pacote apt) e confere se a
#     porta 7300 ficou livre.
#   - badvpn: agora apaga também badvpn.service.d/ (a sobreposição
#     override.conf), badvpn@.service e os backups /root/badvpn.service.bak-*.
#     A v3 apagava só o badvpn.service e deixava o drop-in órfão.
#   - Padrões de unit/processo/binário incluem sshorizon e udpgw.
#   - Verificação final: mostra o PROCESSO dono de cada porta e avisa se algo
#     ainda escuta na 7300.
#
# MUDANÇAS DA V3 EM RELAÇÃO À V2:
#   - NOVO (passo 13): limpa banner/linhas de autoscript do .bashrc, .profile,
#     /etc/profile, /etc/profile.d, /etc/update-motd.d, /etc/motd, rc.local.
#     Era a causa do "Command 'lolcat' not found" ao abrir o terminal: o passo
#     de apt purge removia figlet/lolcat, mas as linhas que os chamavam
#     continuavam nos arquivos de login.
#   - Sem "set -e": um comando que falha não aborta mais a limpeza no meio
#     (ex: iptables ausente derrubava os passos 15-18).
#   - Units systemd: descoberta dinâmica (acha wss@8443, proxy@80, checkuser,
#     limiter, whatsapp-bot, netsimon-*, etc.), remove drop-ins (ssh.service.d,
#     xray.service.d) e links "wants" quebrados. A v2 deixava units órfãs.
#   - nginx: a v2 desabilitava o nginx no passo 1 e o deixava desabilitado
#     (nunca voltava a subir no reboot). Agora é reabilitado, e o site padrão
#     é restaurado (o instalador remove sites-enabled/default).
#   - Xray: remoção local (antes baixava e executava um script remoto do GitHub
#     como root, e falhava sem internet).
#   - Cron: remove também /etc/cron.d/{atlas_sync,dragon_hook,sync_usuarios,
#     delete_watcher_watchdog}. Sysctl/módulos do conntrack e logs do painel
#     (/var/log/netsimon_*, /var/log/xray) também são removidos.
#   - Usuários: mata os processos antes (userdel -rf), aplica a whitelist
#     também ao usuarios.db e protege o usuário do sudo atual.
#   - Firewall: coloca as políticas em ACCEPT antes do flush (evita lockout) e
#     não aborta se iptables não existir.
#   - apt: purga pacote a pacote (um nome inexistente fazia o apt abortar o
#     purge INTEIRO em silêncio) e SIMULA antes — se a remoção arrastar um
#     pacote protegido (ubuntu-server, openssh-server, cloud-init, ...) o
#     pacote é pulado. O mesmo vale para o autoremove. Inclui fail2ban e
#     nodejs (instalados pelo painel) e o repositório do nodesource.
#   - sshd_config: nunca restaura um arquivo que tire o seu acesso; valida com
#     sshd -t e desfaz sozinho se falhar; usa reload em vez de restart.
#   - pkill protegido contra matar o próprio script.
#   - Verificação final: lista processos, units com falha e portas abertas.
#
# Este script NÃO cria backups, NÃO usa quarentena, e apaga direto.
# Ação irreversível. Pacotes/kernel/cloud-init/agente de nuvem NÃO são tocados.
###############################################################################

set -u
R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; C=$'\033[1;36m'; NC=$'\033[0m'
BASE="/etc/painel"

RESET_SSHD="${RESET_SSHD:-1}"
LIMPAR_POSTGRES="${LIMPAR_POSTGRES:-0}"
PURGAR_NGINX="${PURGAR_NGINX:-0}"
RESET_SHELL_RC="${RESET_SHELL_RC:-0}"
export RESET_SHELL_RC
export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" != "0" ]; then
    echo -e "${R}Rode como root (sudo bash limpar_servidor.sh).${NC}"
    exit 1
fi

echo -e "${R}Isso vai apagar TODOS os usuários VPN, configs, serviços,${NC}"
echo -e "${R}regras de firewall, pacotes, logs e QUALQUER rastro relacionado${NC}"
echo -e "${R}a painéis/proxies. SEM VOLTA. Sem backup. Sem quarentena.${NC}"
echo -e "${Y}Opções: RESET_SSHD=$RESET_SSHD LIMPAR_POSTGRES=$LIMPAR_POSTGRES PURGAR_NGINX=$PURGAR_NGINX RESET_SHELL_RC=$RESET_SHELL_RC${NC}"
echo -ne "${Y}Pressione ENTER para continuar (CTRL+C para cancelar): ${NC}"
read -r _confirm

STEP=0; TOTAL=21
passo() { STEP=$((STEP+1)); echo -e "${C}[${STEP}/${TOTAL}] $*${NC}"; }

# --- BEGIN FUNCOES ----------------------------------------------------------
# Mata processos pelo padrão (regex) SEM matar o próprio script nem o shell pai.
matar_padrao() {
    local pids
    pids=$(pgrep -f -- "$1" 2>/dev/null | grep -vxF -e "$$" -e "$PPID")
    # shellcheck disable=SC2086
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    return 0
}

PADRAO_UNITS='netsimon|sshplus|sshpanel|dragonx|rustyproxy|wstest|dtproxy|security-proxy|whatsapp-bot|checkuser|limiter|badvpn|sshorizon|udpgw|slowdns|dnstt|xray|v2ray|trojan|hysteria|3proxy|squid|dropbear|stunnel|openvpn|wg-quick@|wss@|wss-security@|proxy@|firewalld|fail2ban'

# Lista units .service (instaladas OU carregadas) que casam com o padrão.
listar_units() {
    {
        systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null
        systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null
    } | awk '{for(i=1;i<=NF;i++) if ($i ~ /\.service$/) {print $i; break}}' \
      | grep -Ei "$PADRAO_UNITS" | sort -u
}

# Pacotes que NUNCA podem ser removidos (nem por dependência).
PROTEGIDOS_RE='^(ubuntu-server|ubuntu-server-minimal|ubuntu-minimal|ubuntu-standard|ubuntu-cloud-minimal|ubuntu-pro-client|ubuntu-advantage-tools|openssh-.*|ssh|cloud-init.*|cloud-guest-utils|netplan\.io|sudo|systemd.*|libpam-.*|apt|dpkg|bash|coreutils|grub.*|shim.*|linux-.*|python3|python3-minimal|libc6|iptables|nftables|snapd|oracle-cloud-agent|amazon-ssm-agent|qemu-guest-agent|google-guest-agent|walinuxagent)$'
APT_OPTS=(-o DPkg::Lock::Timeout=120)

# Pacotes que seriam purgados ao remover "$@" (simulação, não altera nada).
simular_purge() { apt-get "${APT_OPTS[@]}" -s purge "$@" 2>/dev/null | awk '/^(Purg|Remv) /{print $2}'; }

# Purga pacote a pacote; pula inexistentes e os que arrastariam pacote protegido.
purgar_seguro() {
    local pkg alvo bloqueado
    for pkg in "$@"; do
        dpkg -l "$pkg" 2>/dev/null | grep -qE '^(ii|rc)' || continue
        bloqueado=""
        for alvo in $(simular_purge "$pkg"); do
            if [[ "$alvo" =~ $PROTEGIDOS_RE ]]; then bloqueado="$alvo"; break; fi
        done
        if [ -n "$bloqueado" ]; then
            echo -e "${Y}  ! pulando $pkg: removeria pacote protegido ($bloqueado)${NC}"
            continue
        fi
        if apt-get "${APT_OPTS[@]}" purge -y "$pkg" &>/dev/null; then
            echo "  - purgado: $pkg"
        else
            echo -e "${Y}  ! não consegui purgar: $pkg${NC}"
        fi
    done
}

# autoremove só roda se a simulação não incluir nenhum pacote protegido.
autoremove_seguro() {
    local p prot=()
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [[ "$p" =~ $PROTEGIDOS_RE ]] && prot+=("$p")
    done < <(apt-get "${APT_OPTS[@]}" -s autoremove --purge 2>/dev/null | awk '/^(Purg|Remv) /{print $2}')
    if [ "${#prot[@]}" -gt 0 ]; then
        echo -e "${Y}  ! autoremove PULADO: removeria pacote(s) protegido(s): ${prot[*]}${NC}"
        return 0
    fi
    apt-get "${APT_OPTS[@]}" autoremove --purge -y &>/dev/null
    echo "  autoremove executado."
}

# Remove um usuário VPN (uid 1000-64999) respeitando whitelist e protegidos.
remover_usuario() {
    local login="$1" w uid
    [[ "$login" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 0
    for w in "${WHITELIST_USERS[@]}"; do [ "$login" = "$w" ] && return 0; done
    id "$login" &>/dev/null || return 0
    uid=$(id -u "$login")
    { [ "$uid" -ge 1000 ] && [ "$uid" -lt 65000 ]; } || return 0
    echo "  -> removendo usuário: $login"
    pkill -KILL -u "$login" 2>/dev/null
    userdel -rf "$login" &>/dev/null
    return 0
}

sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {print tolower($2); exit}'; }

# Limpa/ajusta o sshd_config sem NUNCA piorar o acesso que você tem hoje.
ajustar_sshd() {
    local cfg=/etc/ssh/sshd_config tmp ant_root ant_pass dep_root dep_pass
    if [ ! -f "$cfg" ]; then echo "  sshd_config não encontrado, pulando."; return 0; fi
    command -v sshd &>/dev/null || { echo "  sshd não instalado, pulando."; return 0; }
    mkdir -p /run/sshd
    tmp=$(mktemp)
    cp -p "$cfg" "$tmp"
    ant_root=$(sshd_val permitrootlogin); ant_pass=$(sshd_val passwordauthentication)

    if [ "$RESET_SSHD" = "1" ] && [ -f "$cfg.ucf-dist" ]; then
        cp "$cfg.ucf-dist" "$cfg"
        echo "  sshd_config restaurado a partir do padrão do pacote."
    else
        sed -i '/^HostKeyAlgorithms +ssh-rsa/d; /^Banner /d' "$cfg" 2>/dev/null
        echo -e "${Y}  Apliquei apenas correções pontuais (Banner / HostKeyAlgorithms +ssh-rsa).${NC}"
    fi

    if ! sshd -t 2>/dev/null; then
        cp -p "$tmp" "$cfg"; rm -f "$tmp"
        echo -e "${R}  sshd_config novo falhou no sshd -t — DESFEITO, arquivo original mantido.${NC}"
        return 0
    fi
    dep_root=$(sshd_val permitrootlogin); dep_pass=$(sshd_val passwordauthentication)
    if { [ "$ant_root" = "yes" ] && [ "$dep_root" != "yes" ]; } || \
       { [ "$ant_pass" = "yes" ] && [ "$dep_pass" != "yes" ]; }; then
        cp -p "$tmp" "$cfg"; rm -f "$tmp"
        echo -e "${R}  A restauração tiraria seu login (PermitRootLogin $ant_root->$dep_root, PasswordAuthentication $ant_pass->$dep_pass).${NC}"
        echo -e "${R}  DESFEITO para não te trancar fora. Use RESET_SSHD=0 ou ajuste à mão.${NC}"
        return 0
    fi
    rm -f "$tmp"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
        || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    echo -e "${G}  sshd validado e recarregado (sessões abertas continuam).${NC}"
}
# --- END FUNCOES ------------------------------------------------------------

# --- BEGIN UDPGW ------------------------------------------------------------
# O udpgw (badvpn) é sempre iniciado com as mesmas flags, mesmo quando um
# instalador troca o nome do binário/serviço (ex.: "sshorizon-udp" e
# sshorizon-udp-7300.service). Por isso a detecção é pela ASSINATURA (flags do
# ExecStart / linha de comando), e não só pelo nome "badvpn".
UDPGW_NOME_RE='udpgw|sshorizon'
UDPGW_FLAG='--max-connections-for-client'
UDPGW_UNIT_RE='^[[:space:]]*ExecStart=.*(udpgw|sshorizon|max-connections-for-client)'

# Caminho do binário na primeira linha ExecStart= não vazia de um unit/drop-in
# (ignora os prefixos especiais -, @, +, ! e :).
bin_do_execstart() {
    sed -nE 's/^[[:space:]]*ExecStart=[-@+!:]*[[:space:]]*([^[:space:]]+).*/\1/p' "$1" 2>/dev/null | head -1
}

# Apaga um binário (e o alvo, se for symlink) SÓ se não pertencer a pacote apt e
# estiver em diretório "de instalador". Evita apagar /usr/bin/bash e similares
# quando o ExecStart é "bash -c ...".
remover_binario_orfao() {
    local b="$1" real f
    [ -n "$b" ] || return 0
    [ -e "$b" ] || [ -L "$b" ] || return 0
    real=$(readlink -f -- "$b" 2>/dev/null) || real="$b"
    # Em Ubuntu com /bin -> /usr/bin o dpkg só conhece o caminho /usr/bin/...
    # (dpkg -S /bin/bash falha). Por isso o dono é checado no caminho REAL e no
    # informado, e se QUALQUER um for de pacote nada é apagado.
    if dpkg -S "$real" &>/dev/null || dpkg -S "$b" &>/dev/null; then
        echo -e "${Y}  ! $b pertence a um pacote apt — mantido${NC}"
        return 0
    fi
    for f in "$b" "$real"; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        case "$f" in
            /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/local/*|/opt/*|/root/*|/etc/*|/home/*|/tmp/*|/var/tmp/*) ;;
            *) continue ;;
        esac
        rm -f -- "$f" 2>/dev/null && echo "  - binário removido: $f"
    done
    return 0
}

# Remove TODO udpgw/badvpn, inclusive clones com outro nome. Para units e
# processos ANTES de apagar arquivos (senão o Restart=always religa tudo).
limpar_udpgw() {
    local f u d p pid exe cmd b dono anc
    local -a bins=() files=() units=()
    local -A seen=()

    # PIDs que NUNCA são mortos: este script e TODA a cadeia de pais (sudo, ssh,
    # "bash -c '...'" etc.), cuja linha de comando pode conter o texto das flags.
    anc=" "
    pid=$$
    while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
        anc+="$pid "
        pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
    done

    # (a) units/drop-ins próprios em /etc/systemd/system com a assinatura.
    #     "grep -r" não segue symlinks: só pega arquivos reais, não os links
    #     "wants" do multi-user.target.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        files+=("$f")
        b=$(bin_do_execstart "$f")
        [ -n "$b" ] && bins+=("$b")
        u=""
        case "$f" in
            */*.service.d/*.conf) d=$(dirname "$f"); u=$(basename "$d"); u=${u%.d} ;;
            *.service)            u=$(basename "$f") ;;
        esac
        [ -n "$u" ] && units+=("$u")
    done < <(grep -rlE "$UDPGW_UNIT_RE" /etc/systemd/system 2>/dev/null)

    # (b) para e desabilita as units encontradas
    for u in "${units[@]}"; do
        [ -n "${seen[$u]:-}" ] && continue
        seen[$u]=1
        echo "  -> parando/desabilitando: $u"
        systemctl disable --now "$u" &>/dev/null
        systemctl reset-failed "$u" &>/dev/null
    done

    # (c) mata processos udpgw ainda vivos, mesmo com binário renomeado/apagado
    for p in /proc/[0-9]*; do
        pid=${p#/proc/}
        case "$anc" in *" $pid "*) continue ;; esac
        exe=$(readlink "$p/exe" 2>/dev/null) || continue
        [ -n "$exe" ] || continue
        exe=${exe% (deleted)}
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        if [[ "$(basename "$exe")" =~ $UDPGW_NOME_RE ]] || [[ "$cmd" == *"$UDPGW_FLAG"* ]]; then
            echo "  -> matando PID $pid: ${cmd:0:90}"
            bins+=("$exe")
            kill -9 "$pid" 2>/dev/null
        fi
    done

    # (d) apaga binários órfãos, units e drop-ins
    for b in "${bins[@]}"; do remover_binario_orfao "$b"; done
    for f in "${files[@]}"; do
        if rm -f -- "$f" 2>/dev/null; then echo "  - removido: $f"; fi
        d=$(dirname "$f")
        case "$d" in *.service.d) rmdir "$d" 2>/dev/null ;; esac
    done
    systemctl daemon-reload 2>/dev/null

    # (e) a 7300 precisa ter ficado livre
    sleep 1
    if command -v ss &>/dev/null; then
        dono=$(ss -tulnpH 2>/dev/null | awk '$5 ~ /:7300$/ {print $1, $5, $7}')
        if [ -n "$dono" ]; then
            echo -e "${Y}  ! algo ainda escuta na 7300: $dono${NC}"
        else
            echo "  porta 7300 livre."
        fi
    fi
    return 0
}
# --- END UDPGW --------------------------------------------------------------

WHITELIST_USERS=("opc" "ubuntu" "debian" "root" "centos" "admin")
[ -n "${SUDO_USER:-}" ] && WHITELIST_USERS+=("$SUDO_USER")

# =============================================================================
passo "Parando e desabilitando serviços (descoberta dinâmica)..."
SERVICOS=(xray netsimon-painel netsimon-bhttp badvpn stunnel4 slowdns \
          dropbear security-proxy wstest-plain wstest-tls dtproxy1 dtproxy2 \
          firewalld openvpn wg-quick@wg0 v2ray trojan hysteria-server \
          3proxy squid dnstt-server sshplus sshpanel fail2ban \
          checkuser limiter whatsapp-bot netsimon-stunnel netsimon-terminal)
for s in "${SERVICOS[@]}"; do
    systemctl stop "$s" 2>/dev/null
    systemctl disable "$s" 2>/dev/null
done
for u in $(listar_units); do
    echo "  -> $u"
    systemctl stop "$u" 2>/dev/null
    systemctl disable "$u" 2>/dev/null
done

# =============================================================================
passo "Removendo UDP gateways (badvpn/udpgw), inclusive clones renomeados (ex.: sshorizon-udp)..."
limpar_udpgw

# =============================================================================
passo "Matando PM2 e processos Node.js de painéis..."
command -v pm2 &>/dev/null && pm2 kill &>/dev/null
matar_padrao "PM2|pm2"
matar_padrao "whatsapp_bot\.js"
rm -rf /root/.pm2 /home/*/.pm2

# =============================================================================
passo "Matando processos soltos (por nome e por path)..."
matar_padrao "limit\.sh|proxy\.py|checkuser\.py|painel_api\.py|bot_telegram\.py|udpgw|sshorizon|dnstt-server"
matar_padrao "/etc/SSHPlus|/etc/Security|/etc/dtproxy|/etc/netsimon-wstest|/etc/bot|/opt/rustyproxy|/opt/sshplus|DragonX|/root/painel|/etc/painel/"
matar_padrao "verifatt|uexpired|verifbot|initcheck|infousers|ws_real_tunnel|wss_security|wss_watchdog|wss\.py|vpn_multiplexer|netsimon-bhttp"
matar_padrao "/usr/share/\.plus|/usr/lib/sshplus"
screen -wipe &>/dev/null

# =============================================================================
passo "Removendo unidades systemd (arquivos, drop-ins e links quebrados)..."
for n in xray xray@ netsimon-painel netsimon-bhttp netsimon-bhttpd badvpn badvpn@ slowdns \
         security-proxy wstest-plain wstest-tls dtproxy1 dtproxy2 sshplus sshpanel \
         checkuser limiter whatsapp-bot proxy@ wss@ wss-security@ dnstt-server; do
    rm -f "/etc/systemd/system/$n.service"
done
rm -rf /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d
# badvpn: unit, template (badvpn@), drop-ins (badvpn.service.d/override.conf) e
# links "wants"; também clones do udpgw (sshorizon-udp-7300.service etc.).
find /etc/systemd/system \( -iname 'badvpn*' -o -iname '*sshorizon*' -o -iname '*udpgw*' \) -exec rm -rf {} + 2>/dev/null
find /etc/systemd/system -iname '*netsimon*' -exec rm -rf {} + 2>/dev/null
find /etc/systemd/system \( -iname '*sshplus*' -o -iname '*dragonx*' -o -iname '*rustyproxy*' -o -iname '*sshpanel*' \) -exec rm -rf {} + 2>/dev/null
rmdir /etc/systemd/system/ssh.service.d /etc/systemd/system/sshd.service.d 2>/dev/null
find /etc/systemd/system -xtype l -delete 2>/dev/null
systemctl daemon-reload
systemctl reset-failed &>/dev/null

# =============================================================================
passo "Limpando crontab de TODOS os usuários e /etc/cron.d de painéis..."
for u in $(cut -f1 -d: /etc/passwd); do
    crontab -r -u "$u" 2>/dev/null
done
rm -f /etc/cron.d/xray_watchdog /etc/cron.d/atlas_sync /etc/cron.d/delete_watcher_watchdog \
      /etc/cron.d/dragon_hook /etc/cron.d/sync_usuarios
find /etc/cron.d -maxdepth 1 -type f \( -iname '*netsimon*' -o -iname '*sshplus*' -o -iname '*dragon*' \) -delete 2>/dev/null
rm -rf /var/spool/cron/atjobs/* /var/spool/cron/crontabs/* 2>/dev/null

# =============================================================================
passo "Removendo usuários customizados (mantendo opc/ubuntu/debian/root/admin/centos)..."
mapfile -t LOGINS < <(awk -F: '$3>=1000 && $3<65000 {print $1}' /etc/passwd)
for login in "${LOGINS[@]}"; do
    remover_usuario "$login"
done
if [ -f "$BASE/usuarios.db" ]; then
    while IFS='|' read -r login _; do
        login="${login%$'\r'}"
        [ -n "$login" ] && remover_usuario "$login"
    done < "$BASE/usuarios.db"
fi
if id sshplus &>/dev/null; then
    pkill -KILL -u sshplus 2>/dev/null
    userdel -rf sshplus &>/dev/null
fi

# =============================================================================
passo "Nginx: removendo o site do painel e restaurando o padrão..."
if [ "$PURGAR_NGINX" = "1" ]; then
    systemctl stop nginx 2>/dev/null; systemctl disable nginx 2>/dev/null
    echo "  nginx será desinstalado no passo de pacotes."
else
    rm -f /etc/nginx/sites-enabled/netsimon_web /etc/nginx/sites-available/netsimon_web
    if [ -e /etc/nginx/sites-available/default ] && [ ! -e /etc/nginx/sites-enabled/default ]; then
        ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
        echo "  site padrão do nginx restaurado."
    fi
    rm -rf /var/www/html/*
    if command -v nginx &>/dev/null; then
        if nginx -t &>/dev/null; then
            systemctl enable nginx &>/dev/null
            systemctl restart nginx &>/dev/null
            echo "  nginx reabilitado e reiniciado."
        else
            echo -e "${Y}  nginx -t falhou; nginx deixado parado. Verifique /etc/nginx.${NC}"
        fi
    fi
fi

# =============================================================================
passo "Removendo Xray-core, Stunnel, SlowDNS (remoção local, sem script remoto)..."
rm -f /usr/local/bin/xray
rm -rf /usr/local/share/xray /usr/local/etc/xray /etc/xray-manager /etc/slowdns /etc/stunnel \
       /var/log/xray /var/log/v2ray

# =============================================================================
passo "Removendo diretórios conhecidos de painéis/autoscripts..."
rm -rf /etc/painel /etc/SSHPlus /etc/bot /etc/dtproxy1 /etc/dtproxy2 \
       /etc/netsimon-wstest /etc/netsimon-bhttpd /etc/Security /opt/rustyproxy /opt/sshplus \
       /root/DragonX /root/painel /root/BOT \
       /usr/share/.plus /usr/lib/sshplus /usr/local/sshplus 2>/dev/null
if [ "$LIMPAR_POSTGRES" = "1" ]; then
    echo -e "${Y}  LIMPAR_POSTGRES=1: apagando dados de TODOS os bancos PostgreSQL...${NC}"
    rm -rf /var/lib/postgresql/*/main/base
fi
rm -f /etc/modules-load.d/netsimon-conntrack.conf /etc/modprobe.d/netsimon-nf_conntrack.conf \
      /etc/sysctl.d/99-netsimon-conntrack.conf \
      /etc/fail2ban/filter.d/netsimon-security.conf /etc/fail2ban/jail.d/netsimon-security.conf

# =============================================================================
passo "Removendo arquivos soltos, logs e temporários de autoscripts..."
rm -f /etc/IP /etc/autostart /etc/bannerssh \
      /usr/local/bin/menu /usr/local/bin/badvpn-udpgw /usr/local/bin/dragonx \
      /usr/local/bin/netsimon-bhttpd /usr/local/bin/proxydt.1 /usr/local/bin/proxydt.2 \
      /usr/local/bin/websocat \
      /bin/verifatt /bin/uexpired /bin/menu /usr/bin/h /usr/bin/versao \
      /root/usuarios.db /root/.wget-hsts
rm -rf /home/sshplus
rm -rf /var/log/netsimon_* /var/log/checkuser.log /var/log/vpn-multiplexer.log
rm -rf /tmp/badvpn-src /tmp/netsimon_* /tmp/xray_access_last.log /tmp/painel-fetch.* /tmp/xc.tmp

# =============================================================================
passo "Apagando scripts/binários conhecidos de autoscript..."
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
    mhtop Plus sshpanel netsimon-bhttpd netsimon-bhttp \
    badvpn-udpgw sshorizon-udp sshorizon
)
removidos=0
for dir in /bin /usr/bin /usr/local/bin /usr/sbin /usr/local/sbin; do
    for f in "${KNOWN_BAD_BIN[@]}"; do
        if [ -e "$dir/$f" ] || [ -L "$dir/$f" ]; then
            rm -f "$dir/$f" 2>/dev/null && removidos=$((removidos+1))
        fi
    done
done
echo "  Binários/links removidos: $removidos"

# =============================================================================
passo "Removendo rastros de scripts de limpeza/instalação anteriores..."
rm -rf /root/quarentena_bin /root/backup_antes_limpeza_* /root/backup_limpeza_banner_* \
       /root/auditoria_servidor_*.txt /root/install_log.txt \
       /root/strace_log.txt /root/*.pcap /root/Plus /root/Plus.* \
       /root/*.bak /root/usuarios.db.bak
# backups do badvpn (ex.: /root/badvpn.service.bak-2026-09-30-0453) e da
# remoção manual do sshorizon-udp (/root/bkp-sshorizon)
rm -rf /root/badvpn.service.bak* /root/*.service.bak* /root/bkp-sshorizon
: > /root/.bash_history 2>/dev/null
: > /var/log/auth.log 2>/dev/null
: > /var/log/btmp 2>/dev/null

# =============================================================================
passo "Limpando banner/linhas de autoscript do login (.bashrc, profile, motd, rc.local)..."
# Substitui por ":" (no-op) cada linha que chama lolcat/figlet/banner de
# autoscript ou um script que os contém. Usar ":" em vez de apagar mantém
# if/fi e continuações de linha válidos; cada arquivo editado é validado com
# "bash -n" e, se ficar inválido, é mantido como estava.
python3 - <<'PYEOF'
import os, re, glob, shutil, subprocess

RESET = os.environ.get("RESET_SHELL_RC") == "1"
PAT = re.compile("|".join([
    r"lolcat", r"figlet", r"alfalemos", r"NOME DO SERVIDOR", r"DIGITE \( menu \)",
    r"/etc/SSHPlus", r"/etc/painel", r"/opt/sshplus", r"/usr/share/\.plus",
    r"/usr/lib/sshplus", r"/etc/autostart", r"/etc/bannerssh", r"DragonX", r"rustyproxy",
]), re.I)
TOK = re.compile(r"(~?/[\w./-]+|\b[\w.-]+\.sh\b)")
SAFE_PREFIX = ("/root/", "/etc/", "/opt/", "/usr/local/", "/usr/share/.plus", "/home/")

def rd(p):
    with open(p, encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(s)

def contem(p):
    try:
        return os.path.isfile(p) and os.path.getsize(p) < 500_000 and bool(PAT.search(rd(p)))
    except Exception:
        return False

def sintaxe_ok(p):
    return subprocess.run(["bash", "-n", p], capture_output=True).returncode == 0

def dpkg_owned(p):
    return subprocess.run(["dpkg", "-S", p], capture_output=True).returncode == 0

# --- opcional: recria .bashrc/.profile do root a partir do /etc/skel ---------
if RESET:
    for nome in (".bashrc", ".profile", ".bash_logout"):
        src = os.path.join("/etc/skel", nome)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join("/root", nome))
    for extra in ("/root/.bash_aliases", "/root/.bash_profile", "/root/.bash_login"):
        if os.path.exists(extra):
            os.remove(extra)

rcs = ["/root/.bashrc", "/root/.profile", "/root/.bash_profile", "/root/.bash_login",
       "/root/.bash_aliases", "/root/.bash_logout", "/etc/bash.bashrc", "/etc/profile",
       "/etc/skel/.bashrc", "/etc/rc.local"]
profile_d = sorted(glob.glob("/etc/profile.d/*.sh"))
rcs += profile_d
for pat in ("/home/*/.bashrc", "/home/*/.profile", "/home/*/.bash_aliases"):
    rcs += glob.glob(pat)
RCSET = {os.path.realpath(r) for r in rcs}

mexidos, falhos, refs, removidos = [], [], set(), []

def limpar(rc):
    original = rd(rc)
    linhas = original.split("\n")
    i, mudou = 0, False
    while i < len(linhas):
        ln = linhas[i]
        s = ln.strip()
        if not s or s.startswith("#"):
            i += 1
            continue
        ruim = bool(PAT.search(ln))
        if not ruim:
            for t in TOK.findall(ln):
                p = t.replace("~", "/root", 1) if t.startswith("~") else t
                if os.path.realpath(p) not in RCSET and contem(p):
                    ruim = True
                    refs.add(p)
        if ruim:
            ind = re.match(r"\s*", ln).group()
            j = i
            while linhas[j].rstrip("\r").endswith("\\") and j + 1 < len(linhas):
                j += 1
            for k in range(i, j + 1):
                linhas[k] = (ind + ":") if k == i else ":"
            mudou = True
            i = j + 1
        else:
            i += 1
    if not mudou:
        return
    tmp = rc + ".limpeza.tmp"
    wr(tmp, "\n".join(linhas))
    if sintaxe_ok(rc) and not sintaxe_ok(tmp):
        os.remove(tmp)
        falhos.append(rc)
        return
    shutil.copymode(rc, tmp)
    st = os.stat(rc)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except Exception:
        pass
    os.replace(tmp, rc)
    mexidos.append(rc)
    # arquivo de /etc/profile.d que virou só ":" -> era 100% autoscript: remove
    if rc in profile_d and not dpkg_owned(rc):
        uteis = [l for l in rd(rc).split("\n")
                 if l.strip() and not l.strip().startswith("#") and l.strip() != ":"]
        if not uteis:
            os.remove(rc)
            removidos.append(rc)

for rc in rcs:
    if os.path.isfile(rc):
        try:
            limpar(rc)
        except Exception as e:
            falhos.append("%s (%s)" % (rc, e))

# scripts chamados pelo banner (fora dos rc, fora de pacotes): remove
for p in sorted(refs):
    if p.startswith(SAFE_PREFIX) and os.path.isfile(p) and not dpkg_owned(p):
        try:
            os.remove(p)
            removidos.append(p)
        except Exception:
            pass

# executados direto no login: update-motd.d (não-dpkg) e /etc/motd
for p in sorted(glob.glob("/etc/update-motd.d/*")):
    if contem(p) and not dpkg_owned(p):
        os.remove(p)
        removidos.append(p)
if contem("/etc/motd"):
    open("/etc/motd", "w").close()
    removidos.append("/etc/motd (esvaziado)")

print("  Arquivos de login limpos :", mexidos or "nenhum")
print("  Arquivos removidos       :", removidos or "nenhum")
if falhos:
    print("  ATENÇÃO - NÃO alterados (edição deixaria sintaxe inválida; revise à mão):", falhos)
PYEOF

# =============================================================================
passo "Ajustando /etc/ssh/sshd_config (sem tirar o seu acesso)..."
ajustar_sshd

# =============================================================================
passo "Zerando firewall (iptables + nftables) com políticas em ACCEPT..."
for ipt in iptables ip6tables; do
    command -v "$ipt" &>/dev/null || continue
    "$ipt" -P INPUT ACCEPT; "$ipt" -P FORWARD ACCEPT; "$ipt" -P OUTPUT ACCEPT
    "$ipt" -F; "$ipt" -t nat -F; "$ipt" -t mangle -F
    "$ipt" -X; "$ipt" -t nat -X; "$ipt" -t mangle -X
done 2>/dev/null
command -v nft &>/dev/null && nft flush ruleset 2>/dev/null
command -v netfilter-persistent &>/dev/null && netfilter-persistent save &>/dev/null

# =============================================================================
passo "Tratando firewalld e ufw (se instalados)..."
if command -v firewall-cmd &>/dev/null; then
    systemctl stop firewalld 2>/dev/null
    systemctl disable firewalld 2>/dev/null
fi
if command -v ufw &>/dev/null; then
    ufw --force reset &>/dev/null
    ufw disable &>/dev/null
fi

# =============================================================================
passo "Restaurando sysctl relacionado a rede (ip_forward e tuning do painel)..."
sed -i -E '/^[[:space:]]*net\.ipv4\.(ip_forward|tcp_tw_reuse|ip_local_port_range|tcp_fin_timeout)[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null
if command -v docker &>/dev/null; then
    echo -e "${Y}  Docker detectado: mantendo ip_forward ativo em runtime.${NC}"
else
    sysctl -w net.ipv4.ip_forward=0 &>/dev/null
fi

# =============================================================================
passo "Removendo pacotes ligados a painéis/proxies (simulando antes de cada um)..."
PKGS=(stunnel4 socat screen figlet boxes lolcat nload speedtest-cli dos2unix at \
      dnsutils net-tools sqlite3 iptables-persistent netfilter-persistent \
      firewalld fail2ban nodejs)
[ "$PURGAR_NGINX" = "1" ] && PKGS+=(nginx nginx-common nginx-core nginx-full nginx-light)
purgar_seguro "${PKGS[@]}"
rm -f /etc/apt/sources.list.d/nodesource.list /etc/apt/sources.list.d/nodesource.sources \
      /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/nodesource.gpg \
      /etc/apt/preferences.d/nodejs /etc/apt/preferences.d/nsolid
autoremove_seguro
apt-get clean &>/dev/null
if [ "$PURGAR_NGINX" = "1" ]; then
    rm -rf /etc/nginx /var/www/html /var/log/nginx
fi
echo -e "${G}  Etapa de pacotes concluída.${NC}"

# =============================================================================
passo "Varredura final: links simbólicos quebrados e binários órfãos..."
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

# Binários em /usr/local que não pertencem a nenhum pacote apt são removidos.
# ATENÇÃO: isso apaga QUALQUER coisa sua em /usr/local/bin e /usr/local/sbin.
shopt -s nullglob
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
shopt -u nullglob
echo "  Binários órfãos removidos de /usr/local: $removidos_orfaos"

# =============================================================================
passo "Verificação final (o que ainda sobrou)..."
echo "  Processos suspeitos:"
restos=$(pgrep -fa "xray|stunnel|badvpn|udpgw|sshorizon|dnstt|slowdns|dtproxy|wstest|sshplus|checkuser|painel_api|whatsapp_bot|pm2|wss\.py|proxy\.py" 2>/dev/null \
         | grep -vE "pgrep|limpar_servidor|/dev/fd/") 
[ -n "$restos" ] && echo "$restos" | sed 's/^/    /' || echo "    nenhum"
echo "  Units com falha:"
falhas=$(systemctl --failed --no-legend --no-pager 2>/dev/null)
[ -n "$falhas" ] && echo "$falhas" | sed 's/^/    /' || echo "    nenhuma"
echo "  Portas escutando agora, com o processo dono (esperado: só ssh/dns local):"
if command -v ss &>/dev/null; then
    ss -tulnpH 2>/dev/null | awk '{print "    " $1, $5, $7}' | sort -u
    if ss -tulnH 2>/dev/null | awk '$5 ~ /:7300$/ {f=1} END {exit !f}'; then
        echo -e "${Y}  ! ATENÇÃO: ainda há algo escutando na porta 7300 (udpgw). Veja o processo dono acima.${NC}"
    fi
fi

echo ""
echo -e "${G}✅ Limpeza concluída. Servidor o mais próximo possível de recém-formatado.${NC}"
echo -e "${G}   Nenhum backup, quarentena ou log de auditoria foi mantido.${NC}"
echo -e "${Y}   RECOMENDADO: reinicie (reboot) para zerar sockets, sysctl em memória e${NC}"
echo -e "${Y}   processos que ainda estejam rodando. Depois rode: history -c${NC}"
