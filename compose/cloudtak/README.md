# CloudTAK in Docker Compose

Runs [CloudTAK](https://github.com/dfpc-coe/CloudTAK), the open source browser client, beside the TAK Server in [`../takserver`](../takserver). Your users sign in to CloudTAK with their TAK Server username and password.

This folder doesn't change CloudTAK. `setup.sh` downloads a tested release into `src/`, and [`cloudtak-changes.yaml`](cloudtak-changes.yaml) adjusts its Compose file to run beside our server.

## Requirements

- The TAK Server in `../takserver`, running.
- Docker with a recent Compose. Tested with Compose v5.6.1.
- About 8 GB of disk space for the images, plus Docker's build cache.

## Quick start

```sh
./setup.sh
docker compose up -d --build
```

The first build takes a while. Then open `http://localhost:5080` and fill in the setup page:

| Field | Value |
|---|---|
| Server Name | Anything, for example `tak-stack` |
| Server Hostname | `takserver` |
| CoT Port, Marti Port, WebTAK | Leave them at 8089, 8443 and 8446 |
| Admin Certificate | `admin.p12` from TAK Server, and `ADMIN_CERT_PASS` from `../takserver/config/secrets.env` |
| Initial Administrator Username and Password | A TAK Server user from `USERS`, who becomes CloudTAK's administrator |

To copy `admin.p12` out of TAK Server:

```sh
cd ../takserver
docker compose cp takserver:/opt/tak/certs/files/admin.p12 .
```

Delete your copy once it's uploaded.

## What `cloudtak-changes.yaml` changes

| Change | Why |
|---|---|
| The web page is on port 5080 | Port 5000 is taken on macOS |
| The API joins TAK Server's Docker network | CloudTAK reaches it as `takserver`, a name already on the server certificate |
| The API trusts `tak-ca.pem` | CloudTAK checks TAK Server's certificate. `setup.sh` copies our root CA's public certificate, never its key |
| The background services call the API as `http://api:5000` | Upstream's `localhost` means the service's own container |
| The tile server runs as Intel (`linux/amd64`) | On ARM computers, a map library in the ARM image fails to load (`__libc_single_threaded: symbol not found`). The Intel image works, with Docker emulating it |
| The database and file store keep their data in Docker volumes | So data survives containers being recreated and `src/` being replaced |

## Things to know

- **CloudTAK holds a certificate for every user.** When someone signs in, CloudTAK enrolls a certificate for them and keeps it, with its private key, in its database. Protect that database as you would the devices.
- **The admin certificate is TAK Server's admin certificate.** Anyone who controls CloudTAK's API container can act as a TAK Server administrator.
- **After lifting a lockout, run `./forget-certificate.sh <user>`.** CloudTAK keeps using the user's revoked certificate, so they can't sign in until it's gone. The script clears it, and CloudTAK enrolls a new one at their next sign-in.
- **After rotating the root CA, run `./setup.sh` again**, then `docker compose restart api`, so CloudTAK trusts the new root.

## Useful commands

```sh
docker compose ps                        # what's running
docker compose logs -f api               # CloudTAK's API log
./forget-certificate.sh <user>           # make CloudTAK enroll a new certificate for a user
docker compose down                      # stop CloudTAK, keep its data
docker compose down -v                   # stop CloudTAK and delete its data
```

## Versions

Tested with CloudTAK v13.113.0 and TAK Server 5.8-RELEASE-92. Newer CloudTAK releases come out most days. To try one, change `CLOUDTAK_VERSION` in `setup.sh`, run it, and rebuild with `docker compose up -d --build`.

CloudTAK is licensed under the AGPL-3.0. It's downloaded from its own repository and isn't included here.
