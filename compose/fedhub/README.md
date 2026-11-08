# Federation Hub in Docker Compose

Runs TAK Federation Hub, from the TAK Product Center. TAK Servers federate with the hub instead of with each other, and a policy on the hub decides what flows between them.

## Requirements

- The tak.gov `takserver-fedhub-docker-<version>.zip`, unzipped into [`release/`](release/README.md).
- Docker with Compose.
- Ports 9100 and 9102 free on this computer.

## Quick start

```sh
./setup.sh
docker compose up -d --build
```

On first start, the hub creates its own certificate authority, `TAK-STACK-HUB-CA`, a server certificate and an admin certificate. They're kept in the `fedhub` Docker volume.

## Connecting TAK Servers

1. Put each TAK Server's CA certificates in `config/federation/`. On a TAK Server from this repository, `./share-ca.sh` writes them to a file.
2. Run `./share-ca.sh` here, and put the hub's CA file in each TAK Server's `config/federation/`.
3. On each TAK Server, set `FEDERATION=true` and `FEDERATE_WITH=<hub address>:9102`, then restart it.
4. Restart the hub: `docker compose up -d --force-recreate`.

The hub refuses servers until its active policy includes their CA. The log says so:

```text
Permission Denied. Federate/CA Group not found in the policy graph
```

## The web interface and policy

Copy the admin certificate out, and import it into your browser with `ADMIN_CERT_PASS` from `config/secrets.env`:

```sh
docker compose cp fedhub:/opt/tak/federation-hub/certs/files/admin.p12 .
```

Open `https://localhost:9100`. In **Policy Manager**, create a policy, drag a **CA Group** onto the canvas for each TAK Server and choose its CA, then drag from one node to another to let data flow that way. Click the cloud icon to make the policy active. Connected servers turn green.

The active policy is saved in the volume, and the hub loads it again when it restarts.

## What `init/start-fedhub.sh` does

| Step | Why |
|---|---|
| Copies the programs from `release/` on each start | Upgrading means replacing `release/` and restarting |
| Creates the hub's CA and certificates once | Upstream's steps make you run the certificate scripts by hand |
| Builds the hub's truststore from `config/federation/` | Each CA in it becomes a CA Group in the policy editor |
| Sets the passwords and certificate names in the configuration | Upstream's files use the default password `atakatak` |
| Turns off protocol version 1 | Our TAK Servers use version 2 |
| Authorizes the admin certificate | Lets it into the web interface |

The hub's database is optional and isn't run here. The guide says it's only needed for mission federation disruption tolerance, which is off.

## Useful commands

```sh
docker compose logs -f fedhub     # the hub's log
./share-ca.sh                     # write the hub's CA to a file, for TAK Servers
docker compose down               # stop, keeping certificates and policies
docker compose down -v            # stop and delete everything, including the hub's CA
```

Tested with Federation Hub 5.8-RELEASE-92.
