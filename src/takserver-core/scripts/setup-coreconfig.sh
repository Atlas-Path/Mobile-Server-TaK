#!/bin/bash
#
# setup-coreconfig.sh
#
# Creates and sets up the TAK Server CoreConfig.xml for LOCAL (non-Docker)
# development, following README.md ("Configure Local CoreConfig and Certs")
# and src/docs/TAK_Server_Configuration_Guide.pdf (Appendix B: Certificate
# Generation, and "Configure TAK Server Certificate").
#
# This is the local-dev counterpart to the container entrypoint
# (docker/full/docker_entrypoint.sh): it targets takserver-core/example so the
# war can be run from there per the README, instead of /opt/tak in a container.
#
# What it does:
#   1. Copies CoreConfig.example.xml -> CoreConfig.xml in takserver-core/example
#      (where the war looks for CoreConfig.xml when run from that directory).
#   2. Optionally sets the database connection password.
#   3. Points the <tls> keystore references at the generated server cert.
#   4. Generates the local security enclave (CA + server + client certs) with
#      the scripts in scripts/certs, into example/certs/files so CoreConfig's
#      <security>/<tls> and <federation> elements resolve.
#   5. Prints the remaining manual steps (registering the admin cert, importing
#      it into a browser).
#
# Everything is configurable via environment variables (see DEFAULTS below).
# The defaults match CoreConfig.example.xml and the guide, so running with no
# configuration produces a working local dev setup.
#
# Run with --help for usage. This script does not start TAK Server.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths relative to this script so it can be run from anywhere.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../takserver-core/scripts
CORE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"                   # .../takserver-core
EXAMPLE_DIR="${CORE_DIR}/example"                            # where the war looks for CoreConfig.xml
CERT_SCRIPTS_DIR="${SCRIPT_DIR}/certs"                       # source cert-generation scripts
CERT_WORK_DIR="${EXAMPLE_DIR}/certs"                         # where we generate the enclave locally
CERT_FILES_DIR="${CERT_WORK_DIR}/files"                      # final certs/keystores

EXAMPLE_CONFIG="${EXAMPLE_DIR}/CoreConfig.example.xml"
CORECONFIG="${EXAMPLE_DIR}/CoreConfig.xml"

# ---------------------------------------------------------------------------
# DEFAULTS (override via environment variables)
# ---------------------------------------------------------------------------
# cert-metadata.sh requires STATE, CITY and ORGANIZATIONAL_UNIT to be set.
STATE="${STATE:-Virginia}"
CITY="${CITY:-Reston}"
ORGANIZATION="${ORGANIZATION:-TAK}"
ORGANIZATIONAL_UNIT="${ORGANIZATIONAL_UNIT:-TAK}"

# Keystore/truststore passwords. The guide and CoreConfig.example.xml use atakatak.
CAPASS="${CAPASS:-atakatak}"
PASS="${PASS:-$CAPASS}"

# Certificate common names. SERVER_CN defaults to "takserver" so the generated
# keystore is certs/files/takserver.jks, matching CoreConfig.example.xml.
CA_NAME="${CA_NAME:-TAK-Dev-CA}"
SERVER_CN="${SERVER_CN:-takserver}"
# Space-separated list of client certs to generate. "admin" is used for the
# admin UI; "user" is a sample ATAK client cert.
CLIENT_CNS="${CLIENT_CNS:-user admin}"

# Database connection password to write into CoreConfig.xml. Empty by default
# (local dev DB typically uses trust auth). Set DB_PASSWORD to override.
DB_PASSWORD="${DB_PASSWORD:-}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
FORCE_CONFIG=false
FORCE_CERTS=false

usage() {
  cat <<'USAGE'
Creates and sets up the TAK Server CoreConfig.xml for local (non-Docker) development.

Usage:
  ./setup-coreconfig.sh [--force] [--force-certs] [-h|--help]

  --force        Overwrite an existing CoreConfig.xml.
  --force-certs  Regenerate certificates (requires removing example/certs/files first).
  -h, --help     Show this help.

Configuration is via environment variables (defaults in parentheses):
  STATE (Virginia), CITY (Reston), ORGANIZATION (TAK), ORGANIZATIONAL_UNIT (TAK)
  CAPASS (atakatak), PASS (=CAPASS)
  CA_NAME (TAK-Dev-CA), SERVER_CN (takserver), CLIENT_CNS ("user admin")
  DB_PASSWORD (empty)

Example:
  STATE=Virginia CITY=Reston ORGANIZATIONAL_UNIT=TAK \
    DB_PASSWORD=e815f795745e ./setup-coreconfig.sh
USAGE
  exit "${1:-0}"
}

for arg in "$@"; do
  case "$arg" in
    --force)       FORCE_CONFIG=true ;;
    --force-certs) FORCE_CERTS=true ;;
    -h|--help)     usage 0 ;;
    *) echo "Unknown argument: $arg" >&2; usage 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
log "Checking prerequisites"
for tool in openssl keytool perl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not found on PATH."
done
[ -f "$EXAMPLE_CONFIG" ] || die "CoreConfig example not found: $EXAMPLE_CONFIG"
[ -d "$CERT_SCRIPTS_DIR" ] || die "Cert scripts dir not found: $CERT_SCRIPTS_DIR"

# ---------------------------------------------------------------------------
# Step 1: Create CoreConfig.xml from the example
# ---------------------------------------------------------------------------
log "Step 1: Creating CoreConfig.xml in ${EXAMPLE_DIR}"
if [ -f "$CORECONFIG" ] && [ "$FORCE_CONFIG" = false ]; then
  warn "CoreConfig.xml already exists; keeping it (use --force to overwrite)."
else
  cp "$EXAMPLE_CONFIG" "$CORECONFIG"
  log "Wrote ${CORECONFIG}"
fi

# ---------------------------------------------------------------------------
# Step 2: Set the database connection password (optional)
# ---------------------------------------------------------------------------
if [ -n "$DB_PASSWORD" ]; then
  log "Step 2: Setting database password in CoreConfig.xml"
  # Only the active <connection> line carries 'username="martiuser" password=""'.
  perl -pi -e 's/(username="martiuser"\s+password=")[^"]*(")/${1}'"$DB_PASSWORD"'${2}/' "$CORECONFIG"
else
  log "Step 2: No DB_PASSWORD provided; leaving database password unchanged"
fi

# ---------------------------------------------------------------------------
# Step 3: Point CoreConfig <tls> at the generated server keystore
# ---------------------------------------------------------------------------
# CoreConfig.example.xml references certs/files/takserver.jks. If a different
# SERVER_CN was requested, repoint the keystore references to match.
if [ "$SERVER_CN" != "takserver" ]; then
  log "Step 3: Repointing keystore references to certs/files/${SERVER_CN}.jks"
  perl -pi -e 's{certs/files/takserver\.jks}{certs/files/'"$SERVER_CN"'.jks}g' "$CORECONFIG"
else
  log "Step 3: Keystore references already point at certs/files/takserver.jks"
fi

# ---------------------------------------------------------------------------
# Step 4: Generate the certificate enclave (Appendix B)
# ---------------------------------------------------------------------------
log "Step 4: Setting up certificates in ${CERT_WORK_DIR}"

if [ -f "${CERT_FILES_DIR}/ca.pem" ] && [ "$FORCE_CERTS" = false ]; then
  warn "Certificates already exist at ${CERT_FILES_DIR} (ca.pem found)."
  warn "Skipping cert generation. To regenerate, delete ${CERT_FILES_DIR} and re-run."
else
  if [ "$FORCE_CERTS" = true ] && [ -f "${CERT_FILES_DIR}/ca.pem" ]; then
    die "--force-certs given but ${CERT_FILES_DIR} still contains certs. The cert scripts refuse to overwrite an existing CA. Remove ${CERT_FILES_DIR} first, then re-run."
  fi

  # Copy the cert-generation scripts and config alongside the example dir so the
  # enclave is generated locally (CoreConfig resolves certs/files relative to
  # the example directory at runtime).
  mkdir -p "$CERT_WORK_DIR"
  cp "${CERT_SCRIPTS_DIR}/cert-metadata.sh" \
     "${CERT_SCRIPTS_DIR}/makeRootCa.sh" \
     "${CERT_SCRIPTS_DIR}/makeCert.sh" \
     "${CERT_SCRIPTS_DIR}/revokeCert.sh" \
     "${CERT_SCRIPTS_DIR}/config.cfg" \
     "$CERT_WORK_DIR/"
  chmod +x "${CERT_WORK_DIR}/"*.sh

  # Export the metadata consumed by cert-metadata.sh and the make* scripts.
  export STATE CITY ORGANIZATION ORGANIZATIONAL_UNIT CAPASS PASS

  # The cert scripts must run from the certs dir (they read ../config.cfg).
  (
    cd "$CERT_WORK_DIR"

    log "Creating root CA: ${CA_NAME}"
    ./makeRootCa.sh --ca-name "$CA_NAME"

    log "Creating server certificate: ${SERVER_CN}"
    ./makeCert.sh server "$SERVER_CN"

    for cn in $CLIENT_CNS; do
      log "Creating client certificate: ${cn}"
      ./makeCert.sh client "$cn"
    done
  )
  log "Certificates generated in ${CERT_FILES_DIR}"
fi

# ---------------------------------------------------------------------------
# Done — print remaining manual steps
# ---------------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mCoreConfig setup complete.\033[0m')

  CoreConfig.xml : ${CORECONFIG}
  Certificates   : ${CERT_FILES_DIR}

Remaining manual steps (see TAK_Server_Configuration_Guide.pdf, Appendix B):

  1. Start the TAK Server processes (config, messaging, api) as described in
     README.md ("Running TAK server locally for development").

  2. Authorize the admin certificate so it can administer the server (run from
     wherever UserManager.jar is built/installed), e.g.:
       java -jar /opt/tak/utils/UserManager.jar certmod -A \\
         ${CERT_FILES_DIR}/admin.pem

  3. Import the admin client cert into your browser to access the Admin UI:
       File: ${CERT_FILES_DIR}/admin.p12
       Password: ${PASS}
     Then browse to https://localhost:8443 and select the admin certificate.

EOF
