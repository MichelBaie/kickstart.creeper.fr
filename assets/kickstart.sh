#!/usr/bin/env bash

#
# Script d'initialisation ("kickstart") pour une base Debian/Ubuntu.
# Auteur : Creeper
# Date   : 2025-01-19
#

########################################
#             CONFIGURATION            #
########################################

detect_package_manager() {
  # Détection du gestionnaire de paquets
  if command -v apt &> /dev/null; then
    PKG_MANAGER="apt"
  elif command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
  else
    echo "Erreur : ni 'apt' ni 'apt-get' n'est installé sur ce système."
    exit 1
  fi
}

# Liste de paquets de base
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
)

# Paquets nécessaires pour WireGuard
WIREGUARD_PACKAGES=(
  "wireguard-tools"
  "resolvconf"
)

# VirtualBox Guest Tools
VIRTUALBOX_PACKAGES=(
  "make"
  "gcc"
  "dkms"
  "linux-source"
  "linux-headers-amd64"
)

# VMware Guest Tools
VMWARE_PACKAGES=(
  "open-vm-tools-desktop"
)

# Qemu Guest Tools
QEMU_PACKAGES=(
  "qemu-guest-agent"
  "spice-vdagent"
)

# URL de la clé publique à installer
SSH_KEY_URL="https://identity.creeper.fr/assets/creeper.fr.pub.authorized_keys"

########################################
#             FONCTIONS                #
########################################

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit être exécuté en root (ou via sudo)."
    exit 1
  fi
}

# Pose une question à l'utilisateur avec un "oui/non" et un comportement par défaut.
# Utilisation:
#   ask_yes_no "Message" "yes"  -> (Y/n) => Enter = yes
#   ask_yes_no "Message" "no"   -> (y/N) => Enter = no
# Renvoie 0 si "yes", 1 si "no".
ask_yes_no() {
  local prompt="$1"
  local default="$2"  # "yes" ou "no"

  local default_label="(y/n)"
  if [[ "$default" == "yes" ]]; then
    default_label="(Y/n)"
  elif [[ "$default" == "no" ]]; then
    default_label="(y/N)"
  fi

  while true; do
    # On lit depuis /dev/tty pour garantir l'interactivité même si script via pipe
    read -r -p "$prompt $default_label : " REPLY < /dev/tty

    # Si l'utilisateur n'a rien saisi, on prend la valeur par défaut
    if [[ -z "$REPLY" ]]; then
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
        echo "Réponse invalide. Merci de répondre par y/yes ou n/no." > /dev/tty
        ;;
    esac
  done
}

reload_ssh_service() {
  # Tente de recharger le service SSH selon la dénomination
  if systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd
  elif systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh
  elif systemctl list-unit-files | grep -q '^openssh-server\.service'; then
    systemctl reload openssh-server
  else
    # Fallback SysV init
    service ssh reload     2>/dev/null || \
    service sshd reload    2>/dev/null || \
    service openssh-server reload 2>/dev/null || \
    echo "Impossible de recharger le service SSH (non trouvé)." > /dev/tty
  fi
}

install_apt_packages() {
  echo "==> Mise à jour du système..." > /dev/tty
  if [[ "$PKG_MANAGER" == "apt-get" ]]; then
    $PKG_MANAGER update
    $PKG_MANAGER dist-upgrade -y
  else
    $PKG_MANAGER update
    $PKG_MANAGER full-upgrade -y
  fi

  $PKG_MANAGER autoremove -y
  $PKG_MANAGER autoclean -y

  echo "==> Installation des paquets de base..." > /dev/tty
  $PKG_MANAGER install -y "${BASE_PACKAGES[@]}"

  echo "==> Installation de unattended-upgrades..." > /dev/tty
  $PKG_MANAGER install -y unattended-upgrades

  echo "==> Activation d'unattended-upgrades (dpkg-reconfigure -pmedium)..." > /dev/tty
  dpkg-reconfigure -pmedium unattended-upgrades

  echo "==> APT : Mise à jour et installation terminées." > /dev/tty
  echo > /dev/tty
}

install_ssh_keys() {
  echo "==> Installation/Configuration des clés SSH..." > /dev/tty
  TEMP_KEY_FILE="/tmp/creeperfr_authorized_key"

  curl -sSL "$SSH_KEY_URL" -o "$TEMP_KEY_FILE"
  if [[ ! -s "$TEMP_KEY_FILE" ]]; then
    echo "La clé n'a pas pu être téléchargée ou est vide. Abandon." > /dev/tty
    return
  fi

  # Ajout de la clé pour l'utilisateur courant
  CURRENT_USER="${SUDO_USER:-$USER}"
  CURRENT_USER_HOME="$(eval echo ~"$CURRENT_USER")"

  mkdir -p "${CURRENT_USER_HOME}/.ssh"
  cat "$TEMP_KEY_FILE" >> "${CURRENT_USER_HOME}/.ssh/authorized_keys"
  chown -R "$CURRENT_USER":"$CURRENT_USER" "${CURRENT_USER_HOME}/.ssh"
  chmod 700 "${CURRENT_USER_HOME}/.ssh"
  chmod 600 "${CURRENT_USER_HOME}/.ssh/authorized_keys"

  # Ajout de la clé pour root
  mkdir -p /root/.ssh
  cat "$TEMP_KEY_FILE" >> /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys

  # Forcer l’authentification par clé pour root
  SSHD_CONFIG="/etc/ssh/sshd_config"
  if grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
  else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
  fi

  reload_ssh_service
  rm -f "$TEMP_KEY_FILE"

  echo "==> Clés SSH installées (utilisateur: $CURRENT_USER et root)." > /dev/tty
  echo > /dev/tty
}

install_docker() {
  if command -v docker &> /dev/null; then
    echo "Docker est déjà installé. Rien à faire." > /dev/tty
    echo > /dev/tty
    return
  fi

  echo "==> Installation de Docker (stable channel)..." > /dev/tty
  curl -sSL https://get.docker.com/ | CHANNEL=stable bash
  echo "==> Docker est installé." > /dev/tty
  echo > /dev/tty
}

install_crowdsec() {
  echo "==> Installation de CrowdSec..." > /dev/tty
  curl -s https://install.crowdsec.net | bash

  $PKG_MANAGER update
  $PKG_MANAGER install -y crowdsec
  $PKG_MANAGER install -y crowdsec-firewall-bouncer-iptables

  echo "==> CrowdSec est installé et le bouncer iptables configuré." > /dev/tty
  echo > /dev/tty
}

install_wireguard() {
  echo "==> Installation de WireGuard..." > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y --no-install-recommends "${WIREGUARD_PACKAGES[@]}"
  echo "==> WireGuard est installé." > /dev/tty
  echo > /dev/tty
}

create_user_app() {
  echo "==> Création de l'utilisateur 'app'..." > /dev/tty

  # Demande du mot de passe
  echo -n "Entrez le mot de passe pour l'utilisateur 'app': " > /dev/tty
  read -r -s APP_PASS < /dev/tty  # -s : pas d'affichage
  echo > /dev/tty   # saut de ligne

  # Vérifie si l'utilisateur existe déjà
  if id "app" &>/dev/null; then
    echo "L'utilisateur 'app' existe déjà. Mise à jour du mot de passe..." > /dev/tty
  else
    echo "Création de l'utilisateur 'app'..." > /dev/tty
    useradd -m -s /bin/bash app
  fi

  # Mettre à jour le mot de passe
  echo "app:$APP_PASS" | chpasswd

  # Vérifie si Docker est installé : si oui, on ajoute l'utilisateur au groupe docker
  if command -v docker &> /dev/null; then
    echo "Docker est installé. Ajout de 'app' au groupe 'docker'." > /dev/tty
    usermod -aG docker app
  fi

  echo "==> Utilisateur 'app' configuré." > /dev/tty
  echo > /dev/tty
}

install_virtualbox_tools() {
  echo "==> Installation des VirtualBox Guest Tools (préparation)..." > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${VIRTUALBOX_PACKAGES[@]}"
  echo "==> VirtualBox Guest Tools installés (préparation)." > /dev/tty
  echo > /dev/tty
}

install_vmware_tools() {
  echo "==> Installation des VMWare Guest Tools..." > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${VMWARE_PACKAGES[@]}"
  echo "==> VMWare Guest Tools installés." > /dev/tty
  echo > /dev/tty
}

install_qemu_tools() {
  echo "==> Installation des Qemu Guest Tools..." > /dev/tty
  $PKG_MANAGER update
  $PKG_MANAGER install -y "${QEMU_PACKAGES[@]}"
  echo "==> Qemu Guest Tools installés." > /dev/tty
  echo > /dev/tty
}

########################################
#             PROGRAMME MAIN           #
########################################

check_root
detect_package_manager

echo "Script d'installation de base pour Debian/Ubuntu." > /dev/tty
echo "-------------------------------------------------" > /dev/tty

# 1) Pose toutes les questions au début
# (APT et SSH => yes par défaut ; le reste => no par défaut)

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

if ask_yes_no "3. Installer Docker (si non déjà installé) ?" "no"; then
  CHOICE_DOCKER="yes"
else
  CHOICE_DOCKER="no"
fi

if ask_yes_no "4. Installer CrowdSec ?" "no"; then
  CHOICE_CROWDSEC="yes"
else
  CHOICE_CROWDSEC="no"
fi

if ask_yes_no "5. Installer WireGuard ?" "no"; then
  CHOICE_WIREGUARD="yes"
else
  CHOICE_WIREGUARD="no"
fi

if ask_yes_no "6. Créer l'utilisateur 'app' et définir son mot de passe ?" "no"; then
  CHOICE_USER="yes"
else
  CHOICE_USER="no"
fi

if ask_yes_no "7. Installer VirtualBox Guest Tools (make gcc dkms etc.) ?" "no"; then
  CHOICE_VBOX="yes"
else
  CHOICE_VBOX="no"
fi

if ask_yes_no "8. Installer VMware Guest Tools (open-vm-tools-desktop) ?" "no"; then
  CHOICE_VMWARE="yes"
else
  CHOICE_VMWARE="no"
fi

if ask_yes_no "9. Installer Qemu Guest Tools (qemu-guest-agent spice-vdagent) ?" "no"; then
  CHOICE_QEMU="yes"
else
  CHOICE_QEMU="no"
fi

echo "-------------------------------------------------" > /dev/tty
echo "Démarrage de l'installation selon vos réponses..." > /dev/tty
echo "-------------------------------------------------" > /dev/tty

# 2) Exécute les installations selon les choix
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

if [[ "$CHOICE_WIREGUARD" == "yes" ]]; then
  install_wireguard
fi

if [[ "$CHOICE_USER" == "yes" ]]; then
  create_user_app
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

echo "-------------------------------------------------" > /dev/tty
echo "Installation terminée." > /dev/tty
echo "-------------------------------------------------" > /dev/tty

exit 0
