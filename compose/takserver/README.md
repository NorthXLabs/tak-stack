# TAK Server in Docker Compose

Runs TAK Server, its database and certificate setup on one machine, driven by configuration files.

## Choose your images

| Option | You need | Architectures |
|---|---|---|
| **1. Build from the tak.gov release** (recommended) | A tak.gov account and the `takserver-docker-hardened` zip | Intel and ARM |
| **2. Use the Docker Hub images** | Nothing extra | Intel only. ARM machines run them under emulation |

## Quick start: option 1

1. Download `takserver-docker-hardened-<version>.zip` from tak.gov.
2. Unzip it, and copy its contents into `release/`, so that you have `release/docker` and `release/tak`.
3. Run the setup script, then start everything:

```sh
./setup.sh
docker compose up -d --build
```

## Quick start: option 2

With no release in `release/`, `setup.sh` picks the Docker Hub version for you.

```sh
./setup.sh
docker compose -f compose.yaml -f compose.dockerhub.yaml up -d
```

## How it works

| File | What it holds | Safe to commit |
|---|---|---|
| `config/takserver.env` | Certificate authority details, users and database settings | Yes |
| `config/secrets.env` | Passwords, created by `setup.sh` | No |
| `.env` | The TAK Server version, written by `setup.sh` from your release | No |
| `init/` | Start-up scripts mounted into the containers | Yes |

Every start runs the same steps:

1. `tak-certs` creates any certificates that don't exist yet, then exits.
2. `tak-database` creates its database if needed, then starts.
3. `takserver` builds `CoreConfig.xml` from your settings, starts, and registers the admin certificate.

Each step only does what's missing, so restarts are safe. To add a user, add a name to `CLIENT_CERTS` and run `docker compose up -d` again.

## Connecting devices

1. In `config/takserver.env`, list every address devices use to reach the server in `SERVER_ADDRESSES`, and each user in `USERS`.
2. Run `./setup.sh` to create any new passwords, then `docker compose up -d`.
3. Build an enrollment package:

```sh
./make-datapackage.sh 192.168.1.50
```

4. Import `datapackages/enroll-192.168.1.50.zip` in ATAK. Each person signs in with their own username and password from `config/secrets.env`, and ATAK requests its own certificate.

The package holds only the server address and the CA certificates, so you can share it with the whole team. For a device that can't enroll, add it to `CLIENT_CERTS` and use `./make-datapackage.sh --with-cert <user> <address>`. That package contains the user's certificate and password, so share it only with that user.

## Useful commands

```sh
docker compose ps                        # status and health
docker compose logs -f takserver         # follow the server log
docker compose cp takserver:/opt/tak/certs/files/admin.p12 .   # copy a certificate out
docker compose down                      # stop, keeping data and certificates
docker compose down -v                   # stop and delete everything, including your CA
```

## Fixes this setup applies

The release works as shipped on the day it's built, but some parts have aged. This setup works around them without changing the release files:

- **Base image:** the server image pins a base image whose OpenSSL is too old for current security updates, so the build uses the current Java 17 base image.
- **Health checks:** the images' checks also verify file checksums, which fail on current base images. These checks test the services instead.
- **Database:** the Docker Hub database image ships with an empty data folder, so the database is created on first start.
- **Admin certificate:** registration waits for the server to finish starting, instead of a fixed delay.
- **Truststores:** client certificates are signed by the intermediate CA, so both the server and the packages use `truststore-intermediate`, which holds the root and the intermediate. Upstream's default `truststore-root` makes enrolled devices fail to connect.
- **Server addresses:** upstream's server certificate names only `takserver`. ATAK checks the certificate against the address it dialled, so the certificate names every address in `SERVER_ADDRESSES`.

On restart, the database log shows "Database 'cot' already exists" and "Aborting". That's an upstream setup step skipping itself, and it's harmless.
