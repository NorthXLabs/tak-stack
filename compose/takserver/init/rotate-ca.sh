#!/usr/bin/env bash
# Rotates the certificate authorities. Run through ../rotate-ca.sh, not directly.
#
#   status         show each CA and when it expires
#   intermediate   replace the intermediate CA, keeping the old one trusted
#   root           replace the root and intermediate CAs, keeping the old ones trusted
#   retire         stop trusting the old CAs, once every device has moved over
set -euo pipefail
: "${CA_NAME:?}" "${CA_PASS:?}" "${ADMIN_CERT_NAME:?}"

source /init/ca-common.sh

die() { echo "$*" >&2; exit 1; }

archive() {
  local from=$1 to=$2 f
  for f in "$FILES/$from".* "$FILES/$from"-*; do
    [[ -e "$f" ]] || continue
    local base
    base=$(basename "$f")
    # Leave the other CA's files alone: intermediate-2.pem isn't ours to move.
    [[ "$base" =~ ^$from(\.|-do-not-share|-trusted|-signing) ]] || continue
    [[ "$base" == *.generation ]] && continue
    mv "$f" "$FILES/${base/#$from/$to}"
  done
}

# Certificates made on the server are reissued by the new CA on the next start.
# The old files stay valid until you retire the old CA, so nothing drops off.
supersede_client_certs() {
  local name stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$FILES/superseded/$stamp"
  for name in "$ADMIN_CERT_NAME" ${CLIENT_CERTS:-}; do
    [[ -f "$FILES/$name.pem" ]] || continue
    mv "$FILES/$name".{pem,key,csr,p12,jks} "$FILES/$name-trusted.pem" "$FILES/superseded/$stamp/" 2>/dev/null || true
    echo "Will reissue on next start: $name (old files in superseded/$stamp)"
  done
}

status() {
  local ca
  for ca in "${CA_NAMES[@]}"; do
    [[ -f "$FILES/$ca.pem" ]] || continue
    printf '%-17s %-28s expires %s\n' "$ca" "$(cert_cn "$FILES/$ca.pem")" \
      "$(openssl x509 -noout -enddate -in "$FILES/$ca.pem" | cut -d= -f2)"
  done
  if [[ -f "$FILES/takserver.pem" ]]; then
    printf '%-17s %-28s issued by %s\n' "server" "takserver" \
      "$(openssl x509 -noout -issuer -nameopt multiline -in "$FILES/takserver.pem" | awk -F' = ' '/commonName/ {print $2}')"
  fi
}

case "${1:-}" in
  status)
    status
    ;;

  intermediate)
    [[ -f "$FILES/intermediate-old.pem" ]] && die "A rotation is already in progress. Finish it with: ./rotate-ca.sh retire"
    echo "Keeping the current intermediate trusted as intermediate-old"
    archive intermediate intermediate-old
    make_intermediate
    supersede_client_certs
    status
    ;;

  root)
    [[ -f "$FILES/root-ca-old.pem" || -f "$FILES/intermediate-old.pem" ]] &&
      die "A rotation is already in progress. Finish it with: ./rotate-ca.sh retire"
    current=$(cert_cn "$FILES/root-ca.pem")
    [[ "$current" == "$CA_NAME" ]] &&
      die "The new root needs a new name. Change CA_NAME in config/takserver.env (it's $current now), then run this again."
    echo "Keeping the current root and intermediate trusted as root-ca-old and intermediate-old"
    archive root-ca root-ca-old
    archive intermediate intermediate-old
    rm -f "$FILES"/ca.pem "$FILES"/ca-do-not-share.key "$FILES"/ca-trusted.pem \
      "$FILES"/truststore-root.{jks,p12}
    echo "Creating root CA: $CA_NAME"
    bash makeRootCa.sh --ca-name "$CA_NAME"
    make_intermediate
    supersede_client_certs
    status
    ;;

  retire)
    [[ -f "$FILES/root-ca-old.pem" || -f "$FILES/intermediate-old.pem" ]] || die "Nothing to retire."
    # A device could still present the old intermediate alongside its own
    # certificate. If the current root signed it, revoke it, so the root's
    # revocation list refuses that chain too.
    if [[ -f "$FILES/intermediate-old.pem" && "$(issuing_ca "$FILES/intermediate-old.pem")" == root-ca ]]; then
      echo "Revoking the old intermediate: $(cert_cn "$FILES/intermediate-old.pem")"
      (cd "$FILES" && openssl ca -config ../config.cfg -revoke intermediate-old.pem \
        -keyfile "$(ca_key root-ca)" -key "$CAPASS" -cert root-ca.pem)
    fi
    stamp=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$FILES/retired/$stamp"
    for f in "$FILES"/root-ca-old* "$FILES"/intermediate-old*; do
      [[ -e "$f" ]] && mv "$f" "$FILES/retired/$stamp/"
    done
    echo "Retired the old CAs (files in retired/$stamp)"
    # The server certificate moves to the new CA last, so devices that only
    # trust the old root could still connect until now.
    if [[ -z "$(issuing_ca "$FILES/takserver.pem")" ]]; then
      rm -f "$FILES"/takserver.{pem,key,csr,p12,jks} "$FILES/takserver-trusted.pem"
      echo "Will reissue on next start: takserver"
    fi
    status
    ;;

  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
