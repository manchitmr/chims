#!/bin/bash
# =============================================================================
#  cHIMS Unified Installation Script
#  Supports: Ubuntu 20.04+ LTS
# =============================================================================

set -euo pipefail

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Config
NEW_VERSION="0.2"
PAYARA_VERSION="5.2022.5"
PAYARA_HOME="$HOME/payara5"
ASADMIN="${PAYARA_HOME}/bin/asadmin"
DB_NAME="chims_v2"
JNDI_NAME="jdbc/chims_v2"
POOL_NAME="chims_v2"

# Scratch space for files that hold the database password. Kept private and
# removed on exit so the credential never lands on a command line (visible to
# every local user via `ps`) or in a world-readable file.
TMP_DIR="$(mktemp -d)"
chmod 700 "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Banner
echo -e "${BOLD}cHIMS v${NEW_VERSION} Installer${NC}"
echo -e "${CYAN}Modern UI build (Fox Admin–inspired): refreshed dashboard, analysis cards, polished tables/buttons.${NC}"

# Check sudo
if [[ "$EUID" -eq 0 ]]; then error "Run as a normal user (with sudo access), not root."; fi

# 1. System Packages
section() { echo -e "\n${BOLD}--- $* ---${NC}"; }
section "1. Installing System Packages"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  openjdk-11-jdk maven unzip git mysql-server wget curl gh

# 2. MySQL Setup
section "2. Configuring MySQL"
sudo systemctl enable --now mysql

read -rsp "Enter chimsuser password: " MYSQL_CHIMS_PASS; echo
[[ -n "${MYSQL_CHIMS_PASS}" ]] || error "chimsuser password must not be empty."
# The password is embedded in the colon-separated Payara pool property below,
# so these characters would corrupt that string.
if [[ "${MYSQL_CHIMS_PASS}" == *[:\\\"\']* ]]; then
    error "chimsuser password must not contain ':', '\\', '\"' or \"'\". Re-run with a different password."
fi

SQL_FILE="${TMP_DIR}/db-setup.sql"
cat > "${SQL_FILE}" <<MYSQL_SETUP
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'chimsuser'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_CHIMS_PASS}';
ALTER USER 'chimsuser'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_CHIMS_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO 'chimsuser'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SETUP
chmod 600 "${SQL_FILE}"

# A stock Ubuntu install authenticates root@localhost over the unix socket, so
# no root password is needed. Only prompt when that account has already been
# switched to password authentication.
if sudo mysql -u root -e "SELECT 1" >/dev/null 2>&1; then
    sudo mysql -u root < "${SQL_FILE}"
else
    warn "root@localhost does not accept socket authentication; a password is required."
    read -rsp "Enter MySQL root password: " MYSQL_ROOT_PASS; echo
    ROOT_CNF="${TMP_DIR}/root.cnf"
    cat > "${ROOT_CNF}" <<ROOT_CREDS
[client]
user=root
password=${MYSQL_ROOT_PASS}
host=127.0.0.1
ROOT_CREDS
    chmod 600 "${ROOT_CNF}"
    mysql --defaults-extra-file="${ROOT_CNF}" < "${SQL_FILE}" \
      || error "Could not connect to MySQL as root. Check the password and re-run."
fi
success "Database ${DB_NAME} and user chimsuser are ready."

# 3. Payara Setup
section "3. Configuring Payara"
if [[ ! -d "${PAYARA_HOME}" ]]; then
    info "Downloading and extracting Payara..."
    wget -q "https://repo1.maven.org/maven2/fish/payara/distributions/payara/${PAYARA_VERSION}/payara-${PAYARA_VERSION}.zip" -O /tmp/payara.zip
    unzip -q /tmp/payara.zip -d "$HOME"
    rm /tmp/payara.zip
fi

# MySQL Connector
if [[ ! -f "${PAYARA_HOME}/glassfish/lib/mysql-connector-j-8.0.33.jar" ]]; then
    wget -q "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar" -P "${PAYARA_HOME}/glassfish/lib/"
fi

if "${ASADMIN}" list-domains 2>/dev/null | grep -q "^domain1 running"; then
    info "Payara domain1 is already running."
else
    "${ASADMIN}" start-domain \
      || error "Payara failed to start. Check ${PAYARA_HOME}/glassfish/domains/domain1/logs/server.log — ports 8080 and 4848 must be free."
fi

# Already present on the server classpath via glassfish/lib; this only registers
# it with the domain and is expected to fail on re-runs.
"${ASADMIN}" add-library "${PAYARA_HOME}/glassfish/lib/mysql-connector-j-8.0.33.jar" || true

# JDBC Pool & Resource.
# Recreated on every run: a pool left over from an earlier install still holds
# the previous password, and reusing it silently breaks every database call.
JDBC_CMDS="${TMP_DIR}/asadmin-jdbc.txt"
: > "${JDBC_CMDS}"
chmod 600 "${JDBC_CMDS}"
if "${ASADMIN}" list-jdbc-connection-pools 2>/dev/null | grep -qx "${POOL_NAME}"; then
    info "Replacing existing JDBC pool ${POOL_NAME}"
    if "${ASADMIN}" list-jdbc-resources 2>/dev/null | grep -qx "${JNDI_NAME}"; then
        echo "delete-jdbc-resource ${JNDI_NAME}" >> "${JDBC_CMDS}"
    fi
    echo "delete-jdbc-connection-pool --cascade=true ${POOL_NAME}" >> "${JDBC_CMDS}"
fi

# Passed through a private file rather than argv so the password stays off the
# process list.
cat >> "${JDBC_CMDS}" <<JDBC_SETUP
create-jdbc-connection-pool --datasourceclassname com.mysql.cj.jdbc.MysqlDataSource --restype javax.sql.DataSource --property "ServerName=localhost:PortNumber=3306:DatabaseName=${DB_NAME}:User=chimsuser:Password=${MYSQL_CHIMS_PASS}:UseSSL=false:allowPublicKeyRetrieval=true:URL=jdbc\:mysql\://localhost\:3306/${DB_NAME}" ${POOL_NAME}
create-jdbc-resource --connectionpoolid ${POOL_NAME} ${JNDI_NAME}
JDBC_SETUP

"${ASADMIN}" multimode --file "${JDBC_CMDS}" \
  || error "Failed to create the JDBC pool/resource. See the output above."

# Fail here rather than during deployment, where a bad pool surfaces as an
# unrelated persistence error.
"${ASADMIN}" ping-connection-pool "${POOL_NAME}" \
  || error "JDBC pool ${POOL_NAME} cannot reach MySQL. Verify the chimsuser password and that MySQL is listening on localhost:3306."

# 4. Build and Deploy
section "4. Building and Deploying"
mvn package -DskipTests
WAR_FILE="target/chims-${NEW_VERSION}.war"
APP_NAME="chims-${NEW_VERSION}"

# Use redeploy when the app already exists; otherwise fresh deploy.
if "${ASADMIN}" list-applications 2>/dev/null | grep -q "^${APP_NAME}\b"; then
    info "Existing deployment detected — redeploying ${APP_NAME}"
    "${ASADMIN}" redeploy --name "${APP_NAME}" "${WAR_FILE}"
else
    "${ASADMIN}" deploy --force=true --name "${APP_NAME}" "${WAR_FILE}"
fi

success "Installation complete!"
SERVER_IP=$(hostname -I | awk '{print $1}')
info "Access at: http://${SERVER_IP}:8080/${APP_NAME}"
warn "If the UI looks unchanged after an upgrade, hard-refresh your browser (Ctrl+Shift+R) to clear cached CSS."
