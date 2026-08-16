#!/usr/bin/env bash
#==============================================================================
# setup-takserver.sh — one-shot, idempotent local bring-up of TAK Server 5.7
# (standalone, non-docker). Reproduces LOCAL_DEV_SETUP.md end to end:
#   build -> certs -> config -> database -> start/stop scripts -> launch -> enroll admin
#
# Safe to re-run: every step detects work already done and skips it.
# Run from the repo root:  ./setup-takserver.sh   (or: bash setup-takserver.sh)
# The database step uses `sudo -u postgres` and will prompt for your sudo password.
#==============================================================================
set -euo pipefail

SRV="$(cd "$(dirname "$0")" && pwd)"
LOCAL_ENV="${TAKSERVER_LOCAL_ENV:-$SRV/.takserver-local.env}"
if [ -f "$LOCAL_ENV" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$LOCAL_ENV"
  set +a
fi

#--------------------------- CONFIG (edit for your host) ----------------------
CAPASS="${CAPASS:-atakatak}"               # CA + every keystore password
DB_NAME="${DB_NAME:-cot}"
DB_USER="${DB_USER:-martiuser}"
DB_PASS="${DB_PASS:-atakatak}"             # stored in CoreConfig.xml; must match the role's password

CERT_STATE="${CERT_STATE:-NY}"             # required by cert-metadata.sh
CERT_CITY="${CERT_CITY:-NYC}"
CERT_OU="${CERT_OU:-TAK}"
CA_NAME="${CA_NAME:-TAKServer}"            # CA common name (also CoreConfig certificateSigning CA=)
SERVER_CN="${SERVER_CN:-takserver}"        # server cert common name
ADMIN_CN="${ADMIN_CN:-admin}"              # admin client cert common name

# SANs for the server cert — every hostname / IP a client may use to reach this box.
# Put machine-specific values in .takserver-local.env so they do not get committed.
SAN_DNS="${SAN_DNS:-takserver localhost}"
SAN_IP="${SAN_IP:-127.0.0.1}"

# JVM heap sizes (MB) — tuned for a 4GB Pi (≈2.3GB total).
HEAP_MESSAGING="${HEAP_MESSAGING:-1024}"
HEAP_CONFIG="${HEAP_CONFIG:-512}"
HEAP_API="${HEAP_API:-768}"

DO_START="${DO_START:-1}"                  # 1 = launch the server at the end; 0 = configure only
#------------------------------------------------------------------------------

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

CORE="$SRV/src/takserver-core"
EX="$CORE/example"
CERTS="$CORE/scripts/certs"
[ -d "$CORE" ] || die "expected $CORE — run this script from the repo root."

first() { ls -1 $1 2>/dev/null | head -n1 || true; }   # first glob match (unquoted on purpose; never fails)

san_lines() {
  local i=1 d ip
  for d  in $SAN_DNS; do echo "DNS.$i = $d";  i=$((i+1)); done
  i=1
  for ip in $SAN_IP;  do echo "IP.$i = $ip";  i=$((i+1)); done
}

#============================ 0. prerequisites ================================
log "Checking prerequisites"
command -v java    >/dev/null || die "java (JDK 17) not found on PATH"
command -v psql    >/dev/null || die "psql (PostgreSQL client) not found on PATH"
command -v openssl >/dev/null || die "openssl not found on PATH"
command -v keytool >/dev/null || die "keytool (from the JDK) not found on PATH"
command -v ss      >/dev/null || die "ss (iproute2) not found on PATH"
info "java: $(java -version 2>&1 | head -1)"
java -version 2>&1 | head -1 | grep -q '"17\.' || warn "JDK is not 17 — TAK 5.7 expects Temurin 17"

#============================ 1. build artifacts =============================
log "Building artifacts (WAR + UserManager + SchemaManager)"
WAR="$(first "$CORE/build/libs/takserver-core-*.war")"
UM="$(first "$SRV/src/takserver-usermanager/build/libs/UserManager-*-all.jar")"
SM="$(first "$SRV/src/takserver-schemamanager/build/libs/schemamanager-*-uber.jar")"
if [ -n "$WAR" ] && [ -n "$UM" ] && [ -n "$SM" ]; then
  info "artifacts already present — skipping build"
else
  ( cd "$SRV/src" && ./gradlew takserver-core:bootWar takserver-usermanager:shadowJar \
                               takserver-schemamanager:shadowJar --console=plain )
  ( cd "$SRV/src" && ./gradlew --stop ) || true   # release the daemon's heap before we run the server
  WAR="$(first "$CORE/build/libs/takserver-core-*.war")"
  UM="$(first "$SRV/src/takserver-usermanager/build/libs/UserManager-*-all.jar")"
  SM="$(first "$SRV/src/takserver-schemamanager/build/libs/schemamanager-*-uber.jar")"
fi
[ -n "$WAR" ] && [ -n "$UM" ] && [ -n "$SM" ] || die "build did not produce the expected artifacts"
info "WAR:          $WAR"
info "UserManager:  $UM"
info "SchemaManager:$SM"

#============================ 2. certificates ===============================
log "Generating certificates (root CA, server, admin)"
if [ -f "$CERTS/files/ca.pem" ]; then
  info "CA already exists ($CERTS/files/ca.pem) — skipping CA + server/admin certs"
else
  # makeCert.sh server normally writes only a single SAN (DNS.1=<CN>). Inject the full
  # multi-SAN list so clients can reach the server by any name/IP. Idempotent: only
  # rewrites the stock line, and only affects server certs.
  if grep -q '^\$ALTNAMEFIELD = \$SNAME$' "$CERTS/makeCert.sh"; then
    info "patching makeCert.sh server SAN block (adds: $SAN_DNS / $SAN_IP)"
    awk -v repl="$(san_lines)" '/^\$ALTNAMEFIELD = \$SNAME$/{print repl; next} {print}' \
        "$CERTS/makeCert.sh" > "$CERTS/makeCert.sh.tmp"
    mv "$CERTS/makeCert.sh.tmp" "$CERTS/makeCert.sh"; chmod +x "$CERTS/makeCert.sh"
  else
    info "makeCert.sh SAN block already customized"
  fi
  ( cd "$CERTS"
    export STATE="$CERT_STATE" CITY="$CERT_CITY" ORGANIZATIONAL_UNIT="$CERT_OU" \
           CAPASS="$CAPASS" PASS="$CAPASS"
    ./makeRootCa.sh --ca-name "$CA_NAME"
    ./makeCert.sh server "$SERVER_CN"
    ./makeCert.sh client "$ADMIN_CN"
  )
  info "server cert SAN: $(openssl x509 -in "$CERTS/files/$SERVER_CN.pem" -noout -ext subjectAltName | tail -1 | sed 's/^ *//')"
fi

#============================ 3. ca-signing.jks =============================
log "Building ca-signing.jks (signing keystore for :8446 enrollment)"
if [ -f "$CERTS/files/ca-signing.jks" ]; then
  info "ca-signing.jks exists — skipping"
else
  ( cd "$CERTS/files"
    openssl pkcs12 -export -in ca.pem -inkey ca-do-not-share.key -passin pass:"$CAPASS" \
      -name ca -out ca-signing.p12 -passout pass:"$CAPASS"
    keytool -importkeystore -srckeystore ca-signing.p12 -srcstoretype PKCS12 -srcstorepass "$CAPASS" \
      -destkeystore ca-signing.jks -deststoretype JKS -deststorepass "$CAPASS" )
fi

#============================ 4. cert symlink ===============================
log "Linking example/certs/files -> scripts/certs/files"
mkdir -p "$EX/certs"
ln -sfn "$CERTS/files" "$EX/certs/files"
info "$(ls -l "$EX/certs/files" | sed 's/.*-> /-> /')"

#============================ 5. config files ===============================
log "Writing config files (only if missing — the config service rewrites CoreConfig on boot)"
if [ -f "$EX/CoreConfig.xml" ]; then
  info "CoreConfig.xml exists — leaving as-is"
else
  info "creating CoreConfig.xml from CoreConfig.example.xml (DB password + certificateSigning + disable QUIC)"
  awk -v dbpass="$DB_PASS" -v caname="$CA_NAME" -v capass="$CAPASS" '
    /<connection url=.*username="martiuser" password=""/ { sub(/password=""/, "password=\"" dbpass "\"") }
    /<input _name="quic"/ && $0 !~ /<!--/ { print "\t\t<!-- " $0 " (disabled for local dev) -->"; next }
    /<vbm / {
      print "\t<certificateSigning CA=\"" caname "\">"
      print "\t\t<certificateConfig><nameEntries>"
      print "\t\t\t<nameEntry name=\"O\" value=\"TAK\"/>"
      print "\t\t\t<nameEntry name=\"OU\" value=\"TAK\"/>"
      print "\t\t</nameEntries></certificateConfig>"
      print "\t\t<TAKServerCAConfig keystore=\"JKS\" keystoreFile=\"certs/files/ca-signing.jks\" keystorePass=\"" capass "\" validityDays=\"30\" signatureAlg=\"SHA256WithRSA\"/>"
      print "\t</certificateSigning>"
    }
    { print }
  ' "$EX/CoreConfig.example.xml" > "$EX/CoreConfig.xml"
fi
[ -f "$EX/TAKIgniteConfig.xml" ] || { cp "$EX/TAKIgniteConfig.example.xml" "$EX/TAKIgniteConfig.xml"; info "created TAKIgniteConfig.xml"; }
if [ ! -f "$EX/UserAuthenticationFile.xml" ]; then
  cat > "$EX/UserAuthenticationFile.xml" <<'UAF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<UserAuthenticationFile xmlns="http://bbn.com/marti/xml/bindings">
</UserAuthenticationFile>
UAF
  info "created UserAuthenticationFile.xml"
fi

#============================ 6. start/stop scripts =========================
log "Installing start-tak.sh / stop-tak.sh (only if missing)"
if [ -f "$EX/start-tak.sh" ]; then
  info "start-tak.sh exists — leaving as-is"
else
  cat > "$EX/start-tak.sh" <<'STARTEOF'
#!/bin/sh
# start-tak.sh — launch TAK Server standalone microservices: messaging -> config -> api.
#   - messaging starts FIRST (only Ignite *server* in standalone; config/api are clients).
#   - /opt/tak temp/Ignite dirs are redirected to a writable runtime dir under example/.
#   - logback files are truncated per run so readiness greps match THIS run's "Started" line.
cd "$(dirname "$0")" || exit 1
EX="$PWD"
WAR=$(ls -1 ../build/libs/takserver-core-*.war 2>/dev/null | head -n1)
[ -n "$WAR" ] || { echo "ERROR: no takserver-core-*.war under ../build/libs/. Build it first."; exit 1; }
WAR=$(readlink -f "$WAR"); echo "Using WAR: $WAR"
RT="$EX/tak-runtime"; mkdir -p "$RT"; export IGNITE_HOME="$RT"
export JDK_JAVA_OPTIONS="-Dloader.path=WEB-INF/lib-provided,WEB-INF/lib,WEB-INF/classes -Dio.netty.tmpdir=$RT -Djava.io.tmpdir=$RT -Dio.netty.native.workdir=$RT -Djava.net.preferIPv4Stack=true -Djava.security.egd=file:/dev/./urandom -DIGNITE_UPDATE_NOTIFIER=false -DIGNITE_QUIET=true -Djdk.tls.client.protocols=TLSv1.2"
export JDK_JAVA_OPTIONS="${JDK_JAVA_OPTIONS}
--add-opens=java.base/sun.security.pkcs=ALL-UNNAMED
--add-opens=java.base/sun.security.pkcs10=ALL-UNNAMED
--add-opens=java.base/sun.security.util=ALL-UNNAMED
--add-opens=java.base/sun.security.x509=ALL-UNNAMED
--add-opens=java.base/sun.security.tools.keytool=ALL-UNNAMED
--add-opens=java.base/jdk.internal.misc=ALL-UNNAMED
--add-opens=java.base/sun.nio.ch=ALL-UNNAMED
--add-opens=java.management/com.sun.jmx.mbeanserver=ALL-UNNAMED
--add-opens=jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED
--add-opens=java.base/sun.reflect.generics.reflectiveObjects=ALL-UNNAMED
--add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED
--add-opens=java.base/java.io=ALL-UNNAMED
--add-opens=java.base/java.nio=ALL-UNNAMED
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent.locks=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-opens=java.base/java.lang.invoke=ALL-UNNAMED
--add-opens=java.base/java.math=ALL-UNNAMED
--add-opens=java.sql/java.sql=ALL-UNNAMED
--add-opens=java.base/javax.net.ssl=ALL-UNNAMED
--add-opens=java.base/java.net=ALL-UNNAMED
--add-opens=jdk.unsupported/sun.misc=ALL-UNNAMED
--add-opens=java.base/java.lang.ref=ALL-UNNAMED
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED
--add-opens=java.base/java.security=ALL-UNNAMED
--add-opens=java.base/java.security.cert=ALL-UNNAMED
--add-opens=java.base/sun.security.provider.certpath=ALL-UNNAMED
--add-opens=java.base/sun.security.rsa=ALL-UNNAMED
--add-opens=java.base/sun.security.ssl=ALL-UNNAMED
--add-opens=java.base/sun.security.validator=ALL-UNNAMED
--add-opens=java.base/sun.security.x500=ALL-UNNAMED
--add-opens=jdk.crypto.cryptoki/sun.security.pkcs11=ALL-UNNAMED
--add-opens=java.base/sun.security.pkcs12=ALL-UNNAMED
--add-opens=java.base/sun.security.provider=ALL-UNNAMED
--add-opens=java.base/javax.security.auth.x500=ALL-UNNAMED"
JVM_COMMON="-server -XX:+AlwaysPreTouch -XX:+UseG1GC -XX:+ScavengeBeforeFullGC -XX:+DisableExplicitGC"
launch() {
  profile="$1"; heap="$2"; extra="$3"
  : > "$EX/${profile}.log"
  [ -f "$EX/logs/takserver-${profile}.log" ] && : > "$EX/logs/takserver-${profile}.log"
  echo "Starting ${profile} (Xmx${heap}m)..."
  setsid nohup java $JVM_COMMON -Xmx${heap}m -Dspring.profiles.active=${profile} ${extra} -jar "$WAR" > "$EX/${profile}.log" 2>&1 &
}
alive() { pgrep -f "profiles.active=$1 .*takserver-core-.*\.war" >/dev/null 2>&1; }
wait_messaging() {
  timeout=300; waited=0
  while [ $waited -lt $timeout ]; do
    if ss -tln 2>/dev/null | grep -qE ':(47100|47500) '; then echo "  messaging: Ignite port up (${waited}s)"; return 0; fi
    if grep -q "Topology snapshot" "$EX/messaging.log" 2>/dev/null; then echo "  messaging: Ignite topology ready (${waited}s)"; return 0; fi
    if ! alive messaging; then echo "  ERROR: messaging exited early — see messaging.log"; return 1; fi
    sleep 3; waited=$((waited+3))
  done
  echo "  WARNING: messaging readiness not detected after ${timeout}s (continuing)"; return 1
}
wait_started() {
  profile="$1"; timeout="$2"; waited=0; lf="$EX/logs/takserver-${profile}.log"
  while [ $waited -lt $timeout ]; do
    if grep -qE "Started ServerConfiguration in [0-9]" "$lf" 2>/dev/null; then echo "  ${profile}: spring started (${waited}s)"; return 0; fi
    if ! alive "$profile"; then echo "  ERROR: ${profile} exited early — see ${profile}.log / $lf"; return 1; fi
    sleep 3; waited=$((waited+3))
  done
  echo "  WARNING: ${profile} 'Started' not seen after ${timeout}s (continuing)"; return 1
}
wait_for_port() {
  port="$1"; label="$2"; timeout="$3"; waited=0
  while [ $waited -lt $timeout ]; do
    if ss -tln 2>/dev/null | grep -q ":${port} "; then echo "  ${label}: port ${port} up (${waited}s)"; return 0; fi
    sleep 3; waited=$((waited+3))
  done
  echo "  WARNING: ${label}: port ${port} not up after ${timeout}s (continuing)"; return 1
}
echo "== messaging =="; launch messaging 1024 ""; wait_messaging; sleep 10
echo "== config =="; launch config 512 "-Dkeystore.pkcs12.legacy"; wait_started config 240; sleep 5
echo "== api =="; launch api 768 "-Dkeystore.pkcs12.legacy"; wait_started api 240
wait_for_port 8443 "api admin UI" 120; wait_for_port 8446 "api enrollment" 60; wait_for_port 8089 "messaging input" 120
echo; echo "Readiness summary (ports listening):"
ss -tln | grep -E ':(8089|8443|8444|8446)' || echo "  (no TAK ports yet — check the logs)"
echo "App logs:     $EX/logs/takserver-{messaging,config,api}.log"
echo "Console logs: $EX/{messaging,config,api}.log"
STARTEOF
  chmod +x "$EX/start-tak.sh"
  # apply configured heaps (the embedded template uses the default 1024/512/768 literals)
  sed -i -e "s/launch messaging 1024 /launch messaging $HEAP_MESSAGING /" \
         -e "s/launch config 512 /launch config $HEAP_CONFIG /" \
         -e "s/launch api 768 /launch api $HEAP_API /" "$EX/start-tak.sh"
  info "created start-tak.sh"
fi
if [ -f "$EX/stop-tak.sh" ]; then
  info "stop-tak.sh exists — leaving as-is"
else
  cat > "$EX/stop-tak.sh" <<'STOPEOF'
#!/bin/sh
# stop-tak.sh — SIGTERM the three TAK microservices, then SIGKILL survivors after 30s.
ANY="profiles.active=.* .*takserver-core-.*\.war"
echo "Stopping TAK (api, config, messaging)..."
for p in api config messaging; do
  pkill -TERM -f "profiles.active=$p .*takserver-core-.*\.war" 2>/dev/null && echo "  SIGTERM -> $p"
done
waited=0
while [ $waited -lt 30 ]; do
  pgrep -f "$ANY" >/dev/null 2>&1 || { echo "All services stopped cleanly (${waited}s)."; exit 0; }
  sleep 2; waited=$((waited+2))
done
echo "Forcing remaining processes (SIGKILL)..."
for p in api config messaging; do
  pkill -KILL -f "profiles.active=$p .*takserver-core-.*\.war" 2>/dev/null && echo "  SIGKILL -> $p"
done
echo "Done."
STOPEOF
  chmod +x "$EX/stop-tak.sh"
  info "created stop-tak.sh"
fi

#============================ 7. database + schema =========================
log "Database role / db / schema"
if PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1' >/dev/null 2>&1; then
  info "$DB_USER can already connect to $DB_NAME — role/db OK"
else
  warn "Need PostgreSQL superuser access — sudo will prompt for your password."
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
  ELSE
    CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${DB_NAME}')\gexec
SQL
  sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS postgis;"
  PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1' >/dev/null \
    || die "still cannot connect as $DB_USER after setup"
  info "role/db/postgis ready"
fi
info "loading/upgrading schema (idempotent)"
( cd "$EX" && java -jar "$SM" upgrade )

#============================ 8. start the server =========================
if [ "$DO_START" = "1" ]; then
  log "Starting TAK Server (messaging -> config -> api)"
  if ss -tln 2>/dev/null | grep -qE ':(8443|8089) '; then
    info "TAK ports already listening — server appears to be running; skipping start"
  else
    ( cd "$EX" && ./start-tak.sh )
  fi
else
  warn "DO_START=0 — server not launched. Start later with: (cd $EX && ./start-tak.sh)"
fi

#============================ 9. enroll admin ============================
if [ "$DO_START" = "1" ]; then
  log "Enrolling admin certificate as ROLE_ADMIN"
  if grep -q 'identifier="admin"' "$EX/UserAuthenticationFile.xml" 2>/dev/null; then
    info "admin already present in UserAuthenticationFile.xml — skipping"
  else
    ( cd "$EX" && java -jar "$UM" certmod -A certs/files/admin.pem )
  fi
fi

#============================ done ======================================
log "Done"
cat <<DONE
TAK Server bring-up complete.

  Verify ports:   ss -tln | grep -E ':(8089|8443|8444|8446)'
  Admin UI:       https://${SAN_DNS%% *}:8443/   (also any SAN: $SAN_DNS / $SAN_IP)
  Admin cert:     $CERTS/files/admin.p12   (password: $CAPASS)
                  import into your browser/keychain to access :8443
  Copy cert -> PC: run this ON THE OTHER computer to pull the admin cert:
                  scp $(whoami)@${SAN_IP%% *}:$CERTS/files/admin.p12 .
                  (then import admin.p12 — password: $CAPASS)
  Add a client:   (cd $EX && java -jar "$UM" usermod -p '<password>' <username>)
  Stop / start:   (cd $EX && ./stop-tak.sh) ; (cd $EX && ./start-tak.sh)
  Logs:           $EX/logs/takserver-{messaging,config,api}.log
DONE
