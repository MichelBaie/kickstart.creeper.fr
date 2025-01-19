install_ssh_keys() {
  echo -e "${GREEN}==> Installation des clés SSH... 🔑${RESET}" > /dev/tty
  local TEMP_KEY_FILE="/tmp/creeperfr_authorized_key"

  # Télécharge la clé publique (peut contenir plusieurs lignes)
  curl -sSL "$SSH_KEY_URL" -o "$TEMP_KEY_FILE"
  if [[ ! -s "$TEMP_KEY_FILE" ]]; then
    echo -e "${RED}La clé n'a pas pu être téléchargée ou est vide. Abandon.${RESET}" > /dev/tty
    return
  fi

  local CURRENT_USER="${SUDO_USER:-$USER}"
  local CURRENT_USER_HOME
  CURRENT_USER_HOME="$(eval echo ~"$CURRENT_USER")"

  # S'assure que le dossier .ssh existe
  mkdir -p "${CURRENT_USER_HOME}/.ssh"
  chmod 700 "${CURRENT_USER_HOME}/.ssh"

  # Ajoute chaque ligne de la clé si elle n'est pas déjà présente
  while IFS= read -r line; do
    # On ignore les lignes vides ou commentaires
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    # Vérifie si la ligne existe déjà dans authorized_keys
    if ! grep -Fxq "$line" "${CURRENT_USER_HOME}/.ssh/authorized_keys" 2>/dev/null; then
      echo "$line" >> "${CURRENT_USER_HOME}/.ssh/authorized_keys"
    fi
  done < "$TEMP_KEY_FILE"

  # Assure les bons droits
  chown -R "$CURRENT_USER":"$CURRENT_USER" "${CURRENT_USER_HOME}/.ssh"
  chmod 600 "${CURRENT_USER_HOME}/.ssh/authorized_keys"

  # Fichier pour root
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if ! grep -Fxq "$line" /root/.ssh/authorized_keys 2>/dev/null; then
      echo "$line" >> /root/.ssh/authorized_keys
    fi
  done < "$TEMP_KEY_FILE"

  chmod 600 /root/.ssh/authorized_keys

  # Forcer l’authentification par clé pour root
  local SSHD_CONFIG="/etc/ssh/sshd_config"
  if grep -qE "^PermitRootLogin" "$SSHD_CONFIG"; then
    sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
  else
    echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
  fi

  reload_ssh_service
  rm -f "$TEMP_KEY_FILE"

  echo -e "${GREEN}==> Clés SSH installées (utilisateur: $CURRENT_USER et root), sans doublons.${RESET}" > /dev/tty
  echo > /dev/tty
}
