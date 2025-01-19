#!/usr/bin/env bash

#
# Script d'initialisation ("kickstart") pour une base Debian/Ubuntu.
# Auteur : Creeper
#

########################################
#             STYLISME / COULEURS      #
########################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_banner() {
  clear
  echo -e "${GREEN}${BOLD}"
  cat << "EOF"
   _____                                __      
  / ____|                              / _|     
 | |     _ __ ___  ___ _ __   ___ _ __| |_ _ __ 
 | |    | '__/ _ \/ _ \ '_ \ / _ \ '__|  _| '__|
 | |____| | |  __/  __/ |_) |  __/ |_ | | | |   
  \_____|_|  \___|\___| .__/ \___|_(_)|_| |_|   
                      | |                       
                      |_|                       
EOF
  echo -e "${RESET}"
  echo -e "Bienvenue dans le script Kickstart de ${GREEN}Creeper${RESET} ! 🚀"
  echo
}

########################################
#             CONFIGURATION            #
########################################

detect_package_manager() {
  if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
  elif command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
  else
    echo -e "${RED}Erreur${RESET} : ni 'apt' ni 'apt-get' n'est installé sur ce système."
    exit 1
  fi
}

# On sépare WireGuard en deux groupes pour éviter de casser le DNS
WIREGUARD_PRE=(
  "wireguard-tools"
  "iptables"
)

WIREGUARD_POST=(
  "resolvconf"
)

BASE_PACKAGES=(
  "htop"
  "nload"
  "iotop"
  "ncdu"
  "bpytop"
  "bash"
  "sudo"
  "curl"
  "wget"
  "zip"
  "unzip"
  "rsync"
  "mtr-tiny"
  "whois"
  "nano"
)

VIRTUALBOX_PACKAGES=(
  "make"
  "gcc"
  "dkms"
  "linux-source"
  "linux-headers-amd64"
)

VMWARE_PACKAGES=(
  "open-vm-tools-desktop"
)

QEMU_PACKAGES=(
  "qemu-guest-agent"
  "spice-vdagent"
)

SSH_KEY_URL="https://identity.creeper.fr/assets/creeper.fr.pub.authorized_keys"

########################################
#             FONCTIONS                #
########################################

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ce script doit être exécuté en root (ou via sudo).${RESET}"
    exit 1
  fi
}

# Pose une question oui/non avec un comportement par défaut (y/n).
ask_yes_no() {
  local prompt="$1"
  local default="$2"  # "yes" ou "no"

  local default_label="(y/n)"
  if [[ "$default" == "yes" ]]; then
    default_label="(${GREEN}Y${RESET}/${RED}n${RESET})"
  elif [[ "$default" == "no" ]]; then
    default_label="(${RED}y${RESET}/${GREEN}N${RESET})"
  fi

  while true; do
    echo -en "${BLUE}${prompt}${RESET} $default_label : " > /dev/tty
    read -r REPLY < /dev/tty
    if [[ -z "$REPLY" ]]; then
      # Enter => valeur par défaut
      if [[ "$default" == "yes" ]]; then
        return 0
      else
        return 1
      fi
    fi

    case "${REPLY,,}" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo -e "${RED}Réponse invalide. Merci de répondre par y/yes ou n/no.${RESET}" > /dev/tty
        ;;
    esac
  done
}

reload_ssh_service() {
  if systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd
  elif systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh
  elif systemctl list-unit-files | grep -q '^openssh-server\.service'; then
    systemctl reload openssh-server
  else
    service ssh reload     2>/dev/null || \
    service sshd reload    2>/dev/null || \
    service openssh-server reload 2>/dev/null || \
    echo -e "${YELLOW}Impossible de recharger le service SSH (non trouvé).${RESET}" > /dev/tty
  fi
}

install_apt_packages() {
  echo -e "${GREEN}==> Mise à jour du système... 🛠️${RESET}" > /dev/tty
  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    $PKG_MANAGER update
    $PKG_MANAGER dist-upgrade -y
  else
    $PKG_MANAGER update
    $PKG_MANAGER full-upgrade -y
  fi

  $PKG_MANAGER autoremove -y
  $PKG_MANAGER autoclean -y

  echo -e "${GREEN}==> Installation des paquets de base... 🗂️${RESET}" > /dev/tty
  $PKG_MANAGER install -y "${BASE_PACKAGES[@]}"

  echo -e "${GREEN}==> Installation de unattended-upgrades... 🤖${RESET}" > /dev/tty
  $PKG_MANAGER install -y unattended-upgrades

  echo -e "${GREEN}==> Activation des unattended-upgrades...${RESET}" > /dev/tty
  dpkg-reconfigure -pmedium unattended-upgrades

  echo -e "${GREEN}==> APT : Mises à jour et installation terminées.${RESET}" > /dev/tty
  echo > /dev/tty
}

install_ssh_keys() {
  echo -e "${GREEN}==> Installation des clés SSH... 🔑${RESET}" > /dev/tty
  local TEMP_KEY_FILE="/tmp/creeperfr_authorized_key"

  curl -sSL "$SSH_KEY_URL" -o "$TEMP_KEY_FILE"
  if [[ ! -s "$TEMP_KEY_FILE" ]]; then
    echo -e "${RED}La clé n'a pas pu être téléchargée ou est vide. Abandon.${RESET}" > /dev/tty
    return
  fi

  local CURRENT_USER="${SUDO_USER:-$USER}"
  local CURRENT_USER_HOME
  CURRENT_USER_HOME="$(eval echo ~"$CURRENT_USER")"

  mkdir -p "${CURRENT_USER_HOME}/.ssh"
  cat "$TEMP_KEY_FILE" >> "${CURRENT_USER_HOME}/.ssh/authorized_keys"
  chown -R "$CURRENT_USER":"$CURRENT_USER" "${CURRENT_USER_HOME}/.ssh"
  chmod 700 "${CURRENT_USER_HOME}/.ssh"
  chmod 600 "${CURRENT_USER_HOME}/.ssh/authorized_keys"

  mkdir -p /root/.ssh
  cat "$TEMP_KEY_FILE" >> /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys

  local SSHD_CONFIG="/etc/ssh/sshd_config"
  if grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
  else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
  fi

  reload_ssh_service
  rm -f "$TEMP_KEY_FILE"

  echo -e "${GREEN}==> Clés SSH installées (utilisateur: $CURRENT_USER et root).${RESET}" > /dev/tty
  echo > /dev/tty
}

install_docker() {
  if command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker est déjà installé. Rien à faire.${RESET}" > /dev/tty
    echo > /dev/tty
    return
  fi

  echo -e "${GREEN}==> Installation de Docker... 🐳${RESET}" > /dev/tty
  curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  echo -e "${GREEN}==> Docker est installé.${RESET}" > /dev/tty
  echo > /dev/tty
}

install_crowdsec() {
  echo -e "${GREEN}==> Installation de CrowdSec... 🛡️${RESET}" > /dev/tty
  curl -s https://install.crowdsec.net | bash

  $PKG_MANAGER update
  $PKG_MANAGER install -y crowdsec
  $PKG_MANAGER install -y crowdsec-firewall-bouncer-iptables

  echo -e "${GREEN}==> CrowdSec est installé et le bouncer iptables configuré.${RESET}" > /dev/tty
  echo > /dev/tty
}

# Première partie de WireGuard (installation de wireguard-tools et iptables)
install_wireguard_part1() {
  echo -e "${GREEN}==> Installation de WireGuard (partie 1 : tools/iptables)... 🔒${RESET}" > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y --no-install-recommends "${WIREGUARD_PRE[@]}"
  echo -e "${GREEN}==> WireGuard (partie 1) est installé.${RESET}" > /dev/tty
  echo > /dev/tty
}

# Seconde partie de WireGuard (resolvconf) à la fin du script
install_wireguard_part2() {
  echo -e "${GREEN}==> Installation de resolvconf (WireGuard part 2)...${RESET}" > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y resolvconf
  echo -e "${GREEN}==> resolvconf est installé.${RESET}" > /dev/tty
  echo > /dev/tty
}

create_user_app() {
  local password="$1"
  echo -e "${GREEN}==> Création de l'utilisateur 'app'... 👤${RESET}" > /dev/tty

  if id "app" &>/dev/null; then
    echo "L'utilisateur 'app' existe déjà. Mise à jour du mot de passe..." > /dev/tty
  else
    echo "Création de l'utilisateur 'app'..." > /dev/tty
    useradd -m -s /bin/bash app
  fi

  echo "app:$password" | chpasswd

  if command -v docker &> /dev/null; then
    echo "Docker est installé. Ajout de 'app' au groupe 'docker'." > /dev/tty
    usermod -aG docker app
  fi

  echo -e "${GREEN}==> Utilisateur 'app' configuré.${RESET}" > /dev/tty
  echo > /dev/tty
}

install_virtualbox_tools() {
  echo -e "${GREEN}==> Installation des paquets nécessaires à VirtualBox Guest Tools... 📦${RESET}" > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${VIRTUALBOX_PACKAGES[@]}"
  echo -e "${GREEN}==> VirtualBox Guest Tools installés (préparation).${RESET}" > /dev/tty
  echo > /dev/tty
}

install_vmware_tools() {
  echo -e "${GREEN}==> Installation des VMWare Guest Tools... 🚀${RESET}" > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${VMWARE_PACKAGES[@]}"
  echo -e "${GREEN}==> VMWare Guest Tools installés.${RESET}" > /dev/tty
  echo > /dev/tty
}

install_qemu_tools() {
  echo -e "${GREEN}==> Installation des Qemu Guest Tools... 🖥️${RESET}" > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${QEMU_PACKAGES[@]}"
  systemctl enable spice-vdagent

  echo -e "${GREEN}==> Qemu Guest Tools installés et spice-vdagent activé.${RESET}" > /dev/tty
  echo > /dev/tty
}

deploy_watchtower() {
  echo -e "${GREEN}==> Déploiement de Watchtower (Docker)... 🔭${RESET}" > /dev/tty

  local APP_HOME
  APP_HOME="$(eval echo ~app)"

  local WATCHTOWER_DIR="${APP_HOME}/WatchTower"
  mkdir -p "$WATCHTOWER_DIR"

  cat <<EOF > "${WATCHTOWER_DIR}/docker-compose.yml"
services:
  watchtower:
    container_name: watchtower
    image: containrrr/watchtower
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock'
    restart: unless-stopped
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_POLL_INTERVAL=3600
      - WATCHTOWER_ROLLING_RESTART=true
EOF

  chown -R app:app "$WATCHTOWER_DIR"

  sudo -u app bash -c "cd '$WATCHTOWER_DIR' && docker compose up -d"

  echo -e "${GREEN}==> Watchtower déployé dans ${WATCHTOWER_DIR}.${RESET}" > /dev/tty
  echo > /dev/tty
}

########################################
#             PROGRAMME MAIN           #
########################################

print_banner  # Efface l'écran et affiche l'ASCII Art

check_root
detect_package_manager

echo -e "${CYAN}Script d'installation de base pour Debian/Ubuntu.${RESET}" > /dev/tty
echo -e "${CYAN}-------------------------------------------------${RESET}" > /dev/tty

# Questions pour les modules
if ask_yes_no "1. Mettre à jour le système et installer les paquets de base ?" "yes"; then
  CHOICE_APT="yes"
else
  CHOICE_APT="no"
fi

if ask_yes_no "2. Installer les clés SSH (utilisateur courant + root) et forcer PermitRootLogin par clé ?" "yes"; then
  CHOICE_SSH="yes"
else
  CHOICE_SSH="no"
fi

if ask_yes_no "3. Installer Docker ?" "no"; then
  CHOICE_DOCKER="yes"
else
  CHOICE_DOCKER="no"
fi

if ask_yes_no "4. Installer CrowdSec ?" "no"; then
  CHOICE_CROWDSEC="yes"
else
  CHOICE_CROWDSEC="no"
fi

# On va d'abord installer la PARTIE 1 de WireGuard (sans resolvconf)
if ask_yes_no "5. Installer WireGuard ? (Sans resolvconf au début)" "no"; then
  CHOICE_WIREGUARD="yes"
else
  CHOICE_WIREGUARD="no"
fi

APP_PASS=""
if ask_yes_no "6. Créer l'utilisateur 'app' et définir son mot de passe ?" "no"; then
  CHOICE_USER="yes"
  echo -en "${BLUE}Entrez le mot de passe pour l'utilisateur 'app': ${RESET}" > /dev/tty
  read -r -s APP_PASS < /dev/tty
  echo > /dev/tty
else
  CHOICE_USER="no"
fi

if ask_yes_no "7. Installer les paquets nécessaires à VirtualBox Guest Tools ?" "no"; then
  CHOICE_VBOX="yes"
else
  CHOICE_VBOX="no"
fi

if ask_yes_no "8. Installer VMware Guest Tools ?" "no"; then
  CHOICE_VMWARE="yes"
else
  CHOICE_VMWARE="no"
fi

if ask_yes_no "9. Installer Qemu Guest Tools ?" "no"; then
  CHOICE_QEMU="yes"
else
  CHOICE_QEMU="no"
fi

CHOICE_WATCHTOWER="no"
if [[ "$CHOICE_DOCKER" == "yes" && "$CHOICE_USER" == "yes" ]]; then
  if ask_yes_no "10. Déployer Watchtower (pour surveiller et mettre à jour les containers) ?" "no"; then
    CHOICE_WATCHTOWER="yes"
  fi
fi

echo -e "${CYAN}-------------------------------------------------${RESET}" > /dev/tty
echo -e "${CYAN}Démarrage de l'installation selon vos réponses...${RESET}" > /dev/tty
echo -e "${CYAN}-------------------------------------------------${RESET}" > /dev/tty

# Lancement des modules en fonction des réponses
if [[ "$CHOICE_APT" == "yes" ]]; then
  install_apt_packages
fi

if [[ "$CHOICE_SSH" == "yes" ]]; then
  install_ssh_keys
fi

if [[ "$CHOICE_DOCKER" == "yes" ]]; then
  install_docker
fi

if [[ "$CHOICE_CROWDSEC" == "yes" ]]; then
  install_crowdsec
fi

# WireGuard - partie 1 (sans resolvconf)
if [[ "$CHOICE_WIREGUARD" == "yes" ]]; then
  install_wireguard_part1
fi

if [[ "$CHOICE_USER" == "yes" ]]; then
  create_user_app "$APP_PASS"
fi

if [[ "$CHOICE_VBOX" == "yes" ]]; then
  install_virtualbox_tools
fi

if [[ "$CHOICE_VMWARE" == "yes" ]]; then
  install_vmware_tools
fi

if [[ "$CHOICE_QEMU" == "yes" ]]; then
  install_qemu_tools
fi

if [[ "$CHOICE_WATCHTOWER" == "yes" ]]; then
  deploy_watchtower
fi

# FIN DU SCRIPT : si WireGuard = yes, on installe resolvconf
if [[ "$CHOICE_WIREGUARD" == "yes" ]]; then
  install_wireguard_part2
fi

# Enfin, on propose de redémarrer la machine
echo -e "${CYAN}-------------------------------------------------${RESET}" > /dev/tty
if ask_yes_no "Souhaitez-vous redémarrer la machine maintenant ?" "no"; then
  echo -e "${YELLOW}Redémarrage en cours...${RESET}" > /dev/tty
  reboot
else
  echo -e "${GREEN}Aucun redémarrage ne sera effectué.${RESET}" > /dev/tty
fi

echo -e "${GREEN}-------------------------------------------------${RESET}" > /dev/tty
echo -e "${GREEN}Installation terminée. ✅${RESET}" > /dev/tty
echo -e "${GREEN}-------------------------------------------------${RESET}" > /dev/tty

exit 0
