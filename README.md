# RPCS

Opensource Platform for Collection and Analysis of Clinical Data


- Dynamic Form Creation
- Dynamic Quaries

## First-time install (Ubuntu 20.04+ LTS)

cHIMS ships with `install.sh`, a one-shot installer that provisions every
dependency the application needs: OpenJDK 11, Maven, MySQL 8, Payara 5, the
JDBC driver, the database/user, and the deployed WAR. Re-running it later is
safe — the script is idempotent and switches to a redeploy when an existing
`chims-0.2` application is detected.

### Prerequisites

- Ubuntu 20.04 LTS or newer (the script targets Debian/`apt-get`). Verified on
  Ubuntu 24.04 LTS with MySQL 8.0.46.
- A non-root user account with `sudo` access. **Do not run the installer with
  `sudo` or as `root`** — the script aborts in that case and calls `sudo`
  itself only where needed.
- Outbound internet access (to download Payara, the MySQL Connector/J jar, and
  apt packages).
- Port `8080` free (Payara's default HTTP listener).

### Run the installer

```bash
git clone https://github.com/manchitmr/chims.git
cd chims
chmod +x install.sh
./install.sh
```

### What the script does

1. **System packages** — installs `openjdk-11-jdk`, `maven`, `unzip`, `git`,
   `mysql-server`, `wget`, `curl`, and `gh` via `apt-get`.
2. **MySQL** — enables the service and prompts for the **`chimsuser` password**
   (the application database user). On a stock Ubuntu install `root@localhost`
   authenticates over the unix socket, so no root password is needed; the
   script only prompts for one if that account has already been switched to
   password authentication.

   The script then creates database `chims_v2` and grants `chimsuser` full
   privileges on it. The password is never passed on a command line — it is
   written to a private temporary file that is deleted when the script exits.
3. **Payara 5.2022.5** — downloads to `~/payara5/` if missing, installs the
   `mysql-connector-j-8.0.33.jar` driver, starts the domain, and creates the
   JDBC connection pool `chims_v2` along with the JNDI resource
   `jdbc/chims_v2`. The pool is recreated on every run (a pool left from an
   earlier install still holds the old password) and then verified with
   `ping-connection-pool` before the build starts.
4. **Build & deploy** — runs `mvn package -DskipTests`, then deploys the
   resulting `target/chims-0.2.war` (or redeploys it if an existing
   `chims-0.2` application is found).

### After install

The application is reachable at:

```
http://<server-ip>:8080/chims-0.2/
```

After the first deploy (and after every redeploy that touches CSS), do a
**hard browser refresh** (`Ctrl+Shift+R` / `Cmd+Shift+R`) before judging the
UI. Otherwise the browser will keep serving cached stylesheets and the UI
will look unchanged.

### Re-running the installer (upgrades)

`install.sh` is the supported upgrade path, not just a first-install tool.
Pulling the latest code and re-running it will:

- skip Payara/JDK/MySQL setup because they are already in place,
- re-build the WAR from the new sources,
- detect the existing `chims-0.2` deployment and **redeploy** instead of
  failing.

### Common first-run issues

- **`Run as a normal user (with sudo access), not root.`** — you ran the
  script via `sudo` or as the root user. Re-run as a regular user; the script
  escalates with `sudo` internally where required.
- **`Could not connect to MySQL as root.`** — `root@localhost` no longer
  accepts socket authentication and the password you typed was wrong. Reset it
  (e.g. via `sudo mysql_secure_installation`) and re-run the installer.
- **`chimsuser password must not contain ':' ...`** — the password is embedded
  in Payara's colon-separated connection-pool property string, so those
  characters would corrupt it. Choose a password without them.
- **Payara `start-domain` fails / port 8080 already in use** — another
  service is bound to `8080`. Stop it, or change Payara's HTTP listener port
  before re-running. The installer now aborts here instead of continuing with
  a dead domain.
- **`JDBC pool chims_v2 cannot reach MySQL`** — the pool was created but
  cannot open a connection. Confirm MySQL is listening on `localhost:3306` and
  that the `chimsuser` password you entered matches the one in the database.
- **`expected DDL file ... not available` warning during deploy** — harmless.
  EclipseLink is configured with `ddl-generation=create-tables` and
  `output-mode=database`, so it creates the schema directly against
  `chims_v2` instead of writing a DDL script; only the script is missing.

### Manual steps (if you prefer not to use `install.sh`)

If you would rather provision Payara/MySQL yourself, the equivalent
end-to-end commands once the JDBC pool exists are:

```bash
mvn package -DskipTests
~/payara5/bin/asadmin deploy --force=true --name chims-0.2 target/chims-0.2.war
```

For subsequent updates, replace `deploy --force=true` with
`redeploy --name chims-0.2`.
