# Install cHIMS in a Headless Production Server

## Table of Contents

- [Install the OS and the necessary packages](#install-the-os-and-the-necessary-packages)
- [Preparing the database](#preparing-the-database)
- [Downloading and configuring Payara Server 5.x](#downloading-and-configuring-payara-server-5x)
- [Configure JDBC MySQL connector](#configure-jdbc-mysql-connector)
- [Configuring Payara Server](#configuring-payara-server)
- [Installing cHIMS](#installing-chims)
- [Troubleshooting](#troubleshooting)
- [Upgrading cHIMS](#upgrading-chims)

---

## Install the OS and the necessary packages

Download and install the latest Ubuntu Server in your headless Linux server or a cloud VM (e.g., Ubuntu Server 22.04 LTS x64).

You can install the minimised version to limit resource usage.

Select **Install OpenSSH Server** during setup.

Connecting to the Ubuntu Server through SSH:

```shell
ssh USER_NAME@SERVER_IP_ADDRESS
```

Updating the system:

```bash
sudo apt update && sudo apt upgrade -y
```

#### Install `JDK`

```bash
sudo apt install openjdk-11-jdk -y
```

Verify:

```bash
java --version
```

#### Install `git`

```bash
sudo apt install git -y
```

#### Install `unzip`

```bash
sudo apt install unzip -y
```

#### Install `Apache Maven`

```bash
sudo apt install maven -y
```

#### Install `MySQL Server`

```bash
sudo apt install mysql-server -y
```

---

## Preparing the database

Enter the MySQL root shell:

```bash
sudo mysql -u root
```

On a stock Ubuntu install `root@localhost` authenticates over the unix socket, so it needs no password and none should be set. Switching it to password authentication breaks `sudo mysql` for every later step, including re-running `install.sh`.

Create a dedicated database user:

```sql
CREATE USER 'chimsuser'@'localhost' IDENTIFIED WITH mysql_native_password BY 'YourPassword@123';
```

> **Password policy**: MySQL 8 enforces a strong password policy by default. The password must contain uppercase letters, lowercase letters, numbers, and special characters. Weak passwords will be rejected with error `ERROR 1819`.

Create the database:

```sql
CREATE DATABASE chims_v2;
```

Grant privileges:

```sql
GRANT ALL PRIVILEGES ON chims.* TO 'chimsuser'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

#### Uploading a backup dataset (Optional)

```bash
sudo mysql -u root chims_v2 < /path/to/backup.sql
```

---

## Downloading and configuring Payara Server 5.x

Download Payara Server 5.2022.5:

```bash
wget "https://repo1.maven.org/maven2/fish/payara/distributions/payara/5.2022.5/payara-5.2022.5.zip" -O ~/payara-5.2022.5.zip
```

Extract:

```bash
unzip ~/payara-5.2022.5.zip -d ~/
```

Start Payara Server:

```bash
~/payara5/bin/asadmin start-domain
```

#### Disable Hazelcast (Data Grid clustering)

Hazelcast is enabled by default and will attempt to connect to other Payara instances on your network. On a standalone server this causes deployment to hang with a timeout error like `Failed to connect to server X.X.X.X:6136`. Disable it before doing anything else:

```bash
~/payara5/bin/asadmin set-hazelcast-configuration --enabled=false
```

Also patch it in `domain.xml` so it stays disabled after a domain recreation:

```bash
sed -i 's/<hazelcast-runtime-configuration>/<hazelcast-runtime-configuration enabled="false">/' \
  ~/payara5/glassfish/domains/domain1/config/domain.xml
```

#### Change admin password

```bash
~/payara5/bin/asadmin change-admin-password
```

#### Enable secure admin

```bash
~/payara5/bin/asadmin enable-secure-admin
```

#### Restart Payara

```bash
~/payara5/bin/asadmin restart-domain
```

---

## Configure JDBC MySQL connector

Download the MySQL Connector/J:

```bash
wget "https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar" -O ~/mysql-connector-j-8.0.33.jar
```

Add it to Payara using `add-library` (this is the correct method — simply copying the JAR to `glassfish/lib/` is not sufficient for Payara to recognise it as a JDBC driver):

```bash
~/payara5/bin/asadmin add-library ~/mysql-connector-j-8.0.33.jar
```

Restart Payara:

```bash
~/payara5/bin/asadmin restart-domain
```

---

## Configuring Payara Server

### Option A — Command Line (recommended)

Create the JDBC connection pool:

```bash
~/payara5/bin/asadmin create-jdbc-connection-pool \
  --datasourceclassname com.mysql.cj.jdbc.MysqlDataSource \
  --restype javax.sql.DataSource \
  --property "ServerName=localhost:PortNumber=3306:DatabaseName=chims_v2:User=chimsuser:Password=YourPassword@123:UseSSL=false:allowPublicKeyRetrieval=true:URL=jdbc\:mysql\://localhost\:3306/chims_v2" \
  chims_v2
```

> Replace `YourPassword@123` with the password you set for `chimsuser`.

Test the connection:

```bash
~/payara5/bin/asadmin ping-connection-pool chims
```

You should see: `Command ping-connection-pool executed successfully.`

Create the JDBC resource (JNDI name):

```bash
~/payara5/bin/asadmin create-jdbc-resource --connectionpoolid chims_v2 jdbc/chims_v2
```

### Option B — Web Console

Navigate to `http://SERVER_IP_ADDRESS:4848` to access the Payara Admin Console.

#### Configuring JDBC Connection Pool

Go to **Resources → JDBC → JDBC Connection Pools → New**

- **Pool Name:** `chims`
- **Resource Type:** `javax.sql.DataSource`
- **Database Driver Vendor:** `MySql8`

Click **Next**, then add the following **Additional Properties**:

| Name                    | Value                                      |
| ----------------------- | ------------------------------------------ |
| `ServerName`            | `localhost`                                |
| `PortNumber`            | `3306`                                     |
| `DatabaseName`          | `chims_v2`                                 |
| `User`                  | `chimsuser`                                |
| `Password`              | `YourPassword@123`                         |
| `UseSSL`                | `false`                                    |
| `allowPublicKeyRetrieval` | `true`                                   |
| `URL`                   | `jdbc:mysql://localhost:3306/chims_v2`     |

Click **Finish**, then click **Ping** and look for **Ping Succeeded**.

#### Configuring JDBC Resource

Go to **Resources → JDBC → JDBC Resources → New**

- **JNDI Name:** `jdbc/chims_v2`
- **Pool Name:** `chims_v2`

Click **OK**.

---

## Installing cHIMS

Clone the source code:

```bash
git clone https://github.com/lk-gov-health-hiu/chims.git
```

#### Configure `persistence.xml`

Before building, verify that `src/main/resources/META-INF/persistence.xml` contains the following (it should already be correct in the repository):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<persistence version="2.0" xmlns="http://java.sun.com/xml/ns/persistence"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xsi:schemaLocation="http://java.sun.com/xml/ns/persistence http://java.sun.com/xml/ns/persistence/persistence_2_0.xsd">
    <persistence-unit name="hmisPU" transaction-type="JTA">
        <description>cHIMS</description>
        <provider>org.eclipse.persistence.jpa.PersistenceProvider</provider>
        <jta-data-source>jdbc/chims_v2</jta-data-source>
        <properties>
            <property name="eclipselink.ddl-generation" value="create-tables"/>
            <property name="eclipselink.ddl-generation.output-mode" value="database"/>
        </properties>
    </persistence-unit>
</persistence>
```

> **Important**: The JTA data source name `jdbc/chims_v2` must match exactly the JNDI name you created in the Payara configuration step above, or deployment fails.
>
> DDL generation is `create-tables` with `output-mode=database`, so EclipseLink creates the schema directly on first deploy. Deployment logs `expected DDL file ... not available` — that warning is expected and harmless, because no DDL script is written.

#### Build the WAR

```bash
mvn package -DskipTests -f chims
```

#### Deploy to Payara

```bash
~/payara5/bin/asadmin deploy ./chims/target/chims-0.1.war
```

#### Access the application

Open a browser and navigate to:

```
http://SERVER_IP_ADDRESS:8080/chims
```

After creating a user and institution, you can log in and start using the system.

---

## Troubleshooting

### `Failed to connect to server X.X.X.X:6136 (connect timed out)` during deployment

**Cause:** Hazelcast (Payara's data grid / clustering layer) is enabled by default and is trying to reach another Payara node it discovered on the network. Port `6136` is the Hazelcast data grid port.

**Fix:** Disable Hazelcast before deploying:

```bash
~/payara5/bin/asadmin set-hazelcast-configuration --enabled=false
~/payara5/bin/asadmin restart-domain
```

Then retry the deploy.

---

### `ERROR 1819: Your password does not satisfy the current policy requirements`

**Cause:** MySQL 8 enforces a validate-password plugin by default. Simple passwords like `admin` or `password123` are rejected.

**Fix:** Use a strong password with at least one uppercase letter, one lowercase letter, one digit, and one special character (e.g. `MyPassword@123`).

---

### `Application name chims-0.1 is already in use` but `list-applications` shows nothing

**Cause:** A previous deployment attempt left the server in an inconsistent state (partially registered but not fully deployed).

**Fix:** Restart the domain to clear the stale state, then redeploy:

```bash
~/payara5/bin/asadmin restart-domain
~/payara5/bin/asadmin deploy --force=true ./chims/target/chims-0.1.war
```

---

### `Permission denied` when deleting or stopping Payara

**Cause:** Payara was started as `root` (e.g. via a system service or a previous `sudo` invocation), so some files in `~/payara5/` are owned by root.

**Fix:** Use `sudo` to stop the process and delete the directory:

```bash
# Find the Payara PID
ps aux | grep glassfish.jar

# Force-kill it
sudo kill -9 <PID>

# Delete if reinstalling
sudo rm -rf ~/payara5
```

---

### Deployment fails with a SQL syntax error involving `PROCEDURE`

**Cause:** `PROCEDURE` is a reserved word in MySQL. The `Procedure` entity mapped
to a table of that name, so EclipseLink emitted `CREATE TABLE PROCEDURE (...)`
and MySQL rejected it. Deployment still reported success, leaving the schema one
table short and every procedure lookup failing at runtime.

**Fix:** Already applied — the entity declares the table as a delimited
identifier, so the name is emitted inside backticks. Rebuild and redeploy if you
are running code from before that change. Verify with:

```sql
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='chims_v2';
```

A complete schema has 45 tables (44 entities plus `SEQUENCE`).

---

### Checking the Payara server log

All deployment and runtime errors are logged here:

```bash
tail -100 ~/payara5/glassfish/domains/domain1/logs/server.log
```

---

## Upgrading cHIMS

Back up the database before upgrading:

```bash
sudo mysqldump -u root chims > chims_backup_$(date +%F).sql
```

Pull the latest source code:

```bash
cd chims
git pull
```

Rebuild the WAR:

```bash
mvn package -DskipTests
```

Force-deploy the new WAR:

```bash
~/payara5/bin/asadmin deploy --force=true ./target/chims-0.1.war
```
