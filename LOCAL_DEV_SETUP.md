# TAK Server 5.7 — Local Dev Setup (reproduction guide)

This is exactly how this server (`~/Desktop/Server`) was configured and brought up the
first time, written so it can be reproduced in a fresh checkout / another folder. It
captures the **divergences from the upstream README** that actually matter — the README's
happy path does not work as-written against a locally-installed Postgres and standalone
(non-docker) JVMs.

Throughout, `$SRV` = the checkout root (here `~/Desktop/Server`) and most work happens in
`$SRV/src/takserver-core`. Version in this checkout is `5.7-RELEASE-14`; substitute your
own version string in the filenames below if it differs.

Everything uses the password **`atakatak`** (CA, all keystores, the DB user). That's the
`CAPASS` default baked into `scripts/certs/cert-metadata.sh`.

---

## 0. Prerequisites

| Component | Version used here | Notes |
|-----------|-------------------|-------|
| JDK | Temurin **17** (`java -version` → 17.0.18) | TAK 5.7 builds and runs on 17. |
| PostgreSQL | **15** (with PostGIS) | Locally installed, not docker. This is the source of the biggest README divergence (see §2). |
| Gradle | bundled wrapper | Used once to build the WAR + helper jars. |
| Host | `pi-dev`, LAN IP `192.168.100.73` | A Raspberry Pi (4 GB). Heap sizes in §5 are tuned for that. |

---

## 1. Build the artifacts

From `$SRV/src`, build the core WAR plus the two helper jars (these were built once and
reused — you don't rebuild to start the server):

```bash
cd $SRV/src
./gradlew takserver-core:bootWar             # -> takserver-core/build/libs/takserver-core-<ver>.war
./gradlew takserver-usermanager:shadowJar    # -> takserver-usermanager/build/libs/UserManager-<ver>-all.jar
./gradlew takserver-schemamanager:shadowJar  # -> takserver-schemamanager/build/libs/schemamanager-<ver>-uber.jar
```

Resulting artifacts in this checkout:
- `takserver-core/build/libs/takserver-core-5.7-RELEASE-14.war`
- `takserver-usermanager/build/libs/UserManager-5.7-RELEASE-14-all.jar`
- `takserver-schemamanager/build/libs/schemamanager-5.7-RELEASE-14-uber.jar`

> The `start-tak.sh` script auto-discovers the WAR by glob, so the exact version in the
> filename doesn't matter to it.

---

## 2. PostgreSQL database  ⚠️ README divergence

The DB is named `cot`, owned by role `martiuser`.

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE martiuser LOGIN PASSWORD 'atakatak';
CREATE DATABASE cot OWNER martiuser;
\c cot
CREATE EXTENSION IF NOT EXISTS postgis;
SQL
```

Then load/upgrade the schema with the schema manager:

```bash
cd $SRV/src/takserver-schemamanager
java -jar build/libs/schemamanager-5.7-RELEASE-14-uber.jar upgrade
```

(Connection defaults to `jdbc:postgresql://127.0.0.1:5432/cot` as `martiuser`, matching
CoreConfig.)

### ⚠️ Why `martiuser`'s password is `atakatak`, not empty

The upstream README seeds martiuser with the hash
`md564d5850dcafc6b4ddd03040ad1260bc2`, which is `md5("" + "martiuser")` — i.e. an **empty**
password. That works only with the docker image's `POSTGRES_HOST_AUTH_METHOD=trust`. On a
locally-installed Postgres 15, the default `scram-sha-256` auth **rejects empty passwords**
("the password is an empty string"). So we give martiuser a real password (`atakatak`) and
store it in `CoreConfig.xml`. **Do not revert to the empty-password hash.**

`CoreConfig.xml` repository line reflects this:

```xml
<connection url="jdbc:postgresql://127.0.0.1:5432/cot" username="martiuser" password="atakatak"/>
```

---

## 3. Certificates  ⚠️ README divergence (script location)

### ⚠️ The cert scripts moved

The README points at `/utils/misc/certs/`. In this checkout they actually live at
**`src/takserver-core/scripts/certs/`**. All commands below run from there.

```bash
cd $SRV/src/takserver-core/scripts/certs
```

These three vars are **required** by `cert-metadata.sh` or it aborts — export them first:

```bash
export STATE=NY CITY=NYC ORGANIZATIONAL_UNIT=TAK
# (COUNTRY defaults US, ORGANIZATION defaults TAK, CAPASS/PASS default atakatak)
```

Generate the root CA, the server cert (with a multi-SAN so clients can reach it by name or
IP), and an admin client cert:

```bash
./makeRootCa.sh --ca-name TAKServer
./makeCert.sh server takserver
./makeCert.sh client admin
```

#### Server cert SAN

`takserver.jks` was regenerated with a SAN covering every name/IP a client might use:

```
DNS: takserver, pi-dev, localhost
IP:  192.168.100.73, 127.0.0.1
```

If your new host has a different hostname/IP, regenerate the server cert with the right
SAN (edit the `makeCert.sh server` invocation / its SAN config) — otherwise browsers and
ATAK will reject the server identity.

#### ⚠️ Make CoreConfig's relative cert paths resolve — the symlink

CoreConfig references certs as `certs/files/...` (relative to the `example/` working dir),
but the generated certs live under `scripts/certs/files/`. This is bridged with a symlink:

```bash
ln -s $SRV/src/takserver-core/scripts/certs/files \
      $SRV/src/takserver-core/example/certs/files
```

#### ⚠️ `ca-signing.jks` — required for ATAK enrollment (not produced by makeRootCa.sh)

For ATAK/clients to **enroll** for a cert over `:8446`, CoreConfig needs a
`<certificateSigning>` block plus a signing keystore `certs/files/ca-signing.jks`.
`makeRootCa.sh` does **not** produce it (only `makeCert.sh ca <name>` does, which wasn't
run here). We built it from the existing root CA directly:

```bash
cd $SRV/src/takserver-core/scripts/certs/files
openssl pkcs12 -export -in ca.pem -inkey ca-do-not-share.key -name ca \
  -out ca-signing.p12 -passout pass:atakatak
keytool -importkeystore -srckeystore ca-signing.p12 -srcstoretype PKCS12 \
  -srcstorepass atakatak -destkeystore ca-signing.jks -deststoretype JKS \
  -deststorepass atakatak
```

Issued client certs are then signed directly by the root CA — fine for dev; a prod setup
would use a proper intermediate.

---

## 4. CoreConfig.xml & friends

These live in `$SRV/src/takserver-core/example/`. Copy `CoreConfig.example.xml` →
`CoreConfig.xml` and apply the dev specifics. The working `CoreConfig.xml` in this checkout
already has them; key sections:

- **DB connection** with the real password (§2).
- **Connectors / inputs:**
  - `:8089`  TLS streaming input (ATAK/clients, mTLS)
  - `:8443`  https admin UI (requires client cert)
  - `:8446`  `clientAuth="false"` — cert enrollment endpoint (no client cert required)
- **`<security><tls>`** pointing at `certs/files/takserver.jks` + `truststore-root.jks`, all
  pass `atakatak`, `context="TLSv1.2"`.
- **`<certificateSigning CA="TAKServer">`** → `certs/files/ca-signing.jks` (§3), needed for
  enrollment.
- **`<auth><File location="UserAuthenticationFile.xml"/></auth>`**

`TAKIgniteConfig.xml` is effectively empty (just the root element) — that's fine for
standalone.

---

## 5. Start / stop scripts

The whole reason these scripts exist: to avoid re-pasting the giant `JDK_JAVA_OPTIONS`
java command from the README every session, and to launch the three microservices **in the
right order**.

- **`$SRV/src/takserver-core/example/start-tak.sh`** — launches `messaging` → `config` →
  `api`, each under `setsid nohup` so they survive SSH logout. Heap: messaging 1024m, api
  768m, config 512m (≈2.3 GB total, fits the 4 GB Pi alongside OS + Postgres).
- **`$SRV/src/takserver-core/example/stop-tak.sh`** — SIGTERMs all three, then SIGKILLs
  anything still alive after 30s.

```bash
cd $SRV/src/takserver-core/example
./start-tak.sh
# ...
./stop-tak.sh
```

### ⚠️ Ignite startup ordering (messaging FIRST, not config)

The README says start config first. **Don't.** `IgniteConfigurationHolder` makes the
config service an Ignite *client*; messaging is the only Ignite *server* in standalone.
Start config first and it hangs in `ClientImpl.spiStart` forever waiting for a cluster to
join. `start-tak.sh` launches **messaging first**, waits for it, then config + api.

### ⚠️ Don't trust the script's "ready" message — poll the ports

`start-tak.sh`'s wait-gate greps the app log for `Started ServerConfiguration in`, but
logback **appends across runs**, so on the 2nd+ launch it matches the *previous* run's line
and declares "ready" in ~30s while the JVMs actually need 2–3 minutes to bind ports. To
check **real** readiness:

```bash
ss -tln | grep -E ':(8443|8446|8089)'
```

---

## 6. Enroll the admin user  ⚠️ separate post-setup step

Without this, `/swagger-ui` and `/Marti/admin` return 403/500 even with a valid client
cert. After the server is up at least once, register `admin.pem` as a ROLE_ADMIN:

```bash
cd $SRV/src/takserver-core/example
java -jar ../../takserver-usermanager/build/libs/UserManager-5.7-RELEASE-14-all.jar \
  certmod -A certs/files/admin.pem
```

This writes the admin entry (with its cert fingerprint) into `UserAuthenticationFile.xml`.
In this checkout admin's fingerprint is
`1A:86:9D:61:9E:8D:9D:5B:54:94:0A:4E:02:5E:33:64:24:A3:35:E6:2D:EB:3F:E0:D4:67:18:54:7B:A2:8A:A3`
(yours will differ — it's derived from the admin cert you generated).

---

## 7. Adding client users (username/password enrollment)

The intended client flow for this setup is **username/password enrollment** (the phone
connects to `:8446`, authenticates, and is issued a cert), not pre-provisioned certs. Add a
user with a password:

```bash
java -jar ../../takserver-usermanager/build/libs/UserManager-5.7-RELEASE-14-all.jar \
  usermod -p '<password>' <username>
```

### ⚠️ UserManager CLI gotchas
- **No "list users" command** — read `example/UserAuthenticationFile.xml` directly.
- An **unknown flag is silently treated as the username** and creates a junk user
  (e.g. `usermod -l` makes a user literally named via the next token). Delete with
  `usermod -D <username>`.
- UserManager **rewrites the whole XML** from its in-memory cache on every call, so manual
  edits to `UserAuthenticationFile.xml` get reverted on the next UserManager invocation.
  Purge junk users via UserManager, not by hand-editing.

---

## 8. Connecting clients

### Mac browser (admin UI)
Import `certs/files/admin.p12` (pass `atakatak`) into macOS Keychain, then visit
`https://<host>:8443/`. macOS handles the cert format fine, which is why admin worked
end-to-end on the Mac.

### Android / ATAK (username/password enrollment)
1. Build/import a Mission Package containing the **CA truststore** (`truststore-root.p12`)
   and a `cert/server.pref` with:
   `enrollForCertificateWithTrust0=true`, `useAuth0=true`,
   `caLocation0=cert/truststore-root.p12`, `caPassword0=atakatak`,
   `cacheCreds0=Cache credentials`.
   (A working enrollment-only bundle for this host is at
   `~/Desktop/atak-bundles/enroll-pi.zip`.)
2. In ATAK: Address `192.168.100.73`, Port `8089` (Advanced Options), SSL/TLS, Use
   Authentication ON, Enroll for Client Certificate ON.
3. Enter username + password → phone enrolls via `:8446`, gets a server-issued cert, joins
   on `:8089` over mTLS.

⚠️ **The CA truststore on the phone is mandatory.** Without it ATAK shows "The TAK Server's
identity could not be verified" (Cancel/Retry only, no Trust option) and the server logs
are *completely silent* — the TLS handshake fails before reaching any TAK code. Quick
Connect / username-password fields alone are not enough.

### ⚠️ TAK's `makeCert.sh` produces two artifacts broken for Android
macOS tolerates them, so this only bites Android. If you pre-provision certs for an Android
client (vs. enrollment), fix both:

1. **Truststore `.p12` has 0 trust-anchor entries** — the CA lands in the cert bag but
   isn't marked as a trust anchor (`keytool -list` reports "0 entries"). Android
   BouncyCastle then loads no CAs → server appears as
   `SSLV3_ALERT_CERTIFICATE_UNKNOWN`. Rebuild:
   ```bash
   openssl pkcs12 -legacy -in truststore-root.p12.bak -nokeys -passin pass:atakatak -out /tmp/ca.pem
   keytool -importcert -alias root -file /tmp/ca.pem \
     -keystore truststore-root.p12 -storetype PKCS12 -storepass atakatak -noprompt
   ```
2. **Both `.p12`s use `pbeWithSHA1And40BitRC2-CBC`** — modern Android BC dropped it. Convert
   via a **tempfile** (piping the two openssl commands drops the cert silently):
   ```bash
   openssl pkcs12 -legacy -in client.p12.bak -nodes -passin pass:atakatak -out /tmp/c.pem
   openssl pkcs12 -export -in /tmp/c.pem -out client.p12 -name <alias> \
     -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 -passout pass:atakatak
   ```

---

## 9. Quick checklist for the new folder

1. [ ] JDK 17 + Postgres 15/PostGIS installed.
2. [ ] Build WAR + UserManager + SchemaManager jars (§1).
3. [ ] Create `cot` DB + `martiuser` with password `atakatak`; run schemamanager `upgrade` (§2).
4. [ ] `export STATE/CITY/ORGANIZATIONAL_UNIT`; `makeRootCa.sh` + `makeCert.sh server takserver` (with correct SAN) + `makeCert.sh client admin` (§3).
5. [ ] Build `ca-signing.jks` from the root CA (§3).
6. [ ] Symlink `example/certs/files` → `scripts/certs/files` (§3).
7. [ ] Put `CoreConfig.xml` in place with DB password, connectors, tls, certificateSigning (§4).
8. [ ] `./start-tak.sh`; verify with `ss -tln | grep -E ':(8443|8446|8089)'` (§5).
9. [ ] Enroll admin: `certmod -A certs/files/admin.pem` (§6).
10. [ ] Add client users with `usermod -p` (§7), connect clients (§8).

---

### Ports reference
| Port | Purpose | Client cert? |
|------|---------|--------------|
| 8089 | TLS streaming input (ATAK/clients) | yes (mTLS) |
| 8443 | Admin UI / Swagger / Marti API | yes (`admin.p12`) |
| 8446 | Certificate enrollment | no (`clientAuth="false"`) |
| 8444 | Federation https | fed truststore |
| 9001 | Federation v2 | — |
