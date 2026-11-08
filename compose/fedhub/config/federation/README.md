# TAK Servers

Put the CA certificates of each TAK Server that connects to this hub here, as
`.pem` files. On a TAK Server from this repository, `./share-ca.sh` writes them.
Restart the hub after adding one: `docker compose up -d --force-recreate`.

These are public certificates, never private keys.
