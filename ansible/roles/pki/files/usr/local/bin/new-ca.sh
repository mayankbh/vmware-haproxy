#!/bin/bash

# Copyright 2020 HAProxy Technologies
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http:#www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

USAGE="
usage: ${0} [FLAGS] COMMON_NAME [OUT_DIR]
  Creates a self-signed certificate authority and writes its public
  and private keys as two PEM-encoded files, ca.crt and ca.key.

COMMON_NAME
  The certificate's common name. This is a required argument.

OUT_DIR
  An optional argument that specifies the directory to which to write
  the public and private keys. If omitted, they files are written to
  the working directory.

FLAGS
  -h    show this help and exit
  -c    country (defaults to US)
  -s    state or province (defaults to CA)
  -l    locality (defaults to Palo Alto)
  -o    organization (defaults to VMware)
  -u    organizational unit (defaults to CAPV)
  -b    bit size (defaults to 2048)
  -d    days until expiry (defaults to 3650)
  -f    file name prefix (defaults to ca)
  -n    skip overwriting a certificate and key if one already exists.
"

function error() {
  local exit_code="${?}"
  echo "${@}" 1>&2
  return "${exit_code}"
}

function fatal() {
  error "${@}" || exit 1
}

# Start of main script
while getopts ":hvnc:s:l:o:u:b:d:f:" opt; do
  case ${opt} in
    h)
      error "${USAGE}" && exit 1
      ;;
    c)
      TLS_COUNTRY_NAME="${OPTARG}"
      ;;
    s)
      TLS_STATE_OR_PROVINCE_NAME="${OPTARG}"
      ;;
    l)
      TLS_LOCALITY_NAME="${OPTARG}"
      ;;
    o)
      TLS_ORG_NAME="${OPTARG}"
      ;;
    u)
      TLS_OU_NAME="${OPTARG}"
      ;;
    b)
      TLS_DEFAULT_BITS="${OPTARG}"
      ;;
    d)
      TLS_DEFAULT_DAYS="${OPTARG}"
      ;;
    f)
      TLS_FILE_PREFIX="${OPTARG}"
      ;;
    n)
      NO_OVERWRITE=1
      ;;
    v)
      VERBOSE=1
      set -x
      ;;
    \?)
      error "invalid option: -${OPTARG} ${USAGE}" && exit 1
      ;;
    :)
      error "option -${OPTARG} requires an argument" && exit 1
      ;;
  esac
done
shift $((OPTIND-1))

# Verbose mode
VERBOSE="${VERBOSE-}"
NO_OVERWRITE="${NO_OVERWRITE-}"

# The strength of the generated certificate
TLS_DEFAULT_BITS=${TLS_DEFAULT_BITS:-2048}

# The number of days until the certificate expires. The default
# value is 10 years.
TLS_DEFAULT_DAYS=${TLS_DEFAULT_DAYS:-3650}

# The components that make up the certificate's distinguished name.
TLS_COUNTRY_NAME=${TLS_COUNTRY_NAME:-US}
TLS_STATE_OR_PROVINCE_NAME=${TLS_STATE_OR_PROVINCE_NAME:-California}
TLS_LOCALITY_NAME=${TLS_LOCALITY_NAME:-Palo Alto}
TLS_ORG_NAME=${TLS_ORG_NAME:-VMware}
TLS_OU_NAME=${TLS_OU_NAME:-CAPV}

# The file name prefix for the public and private keys.
TLS_FILE_PREFIX=${TLS_FILE_PREFIX:-ca}

# The directory to which to write the public and private keys.
{ [ "${#}" -gt "1" ] && OUT_DIR="${2}"; } || OUT_DIR="$(pwd)"
mkdir -p "${OUT_DIR}"

if { [ -f "${OUT_DIR}/${TLS_FILE_PREFIX}.crt" ] || [ -f "${OUT_DIR}/${TLS_FILE_PREFIX}.key" ]; } && [ $NO_OVERWRITE ]; then
  echo "Existing ${TLS_FILE_PREFIX}.crt or ${TLS_FILE_PREFIX}.key "\
  "exists in ${OUT_DIR}. Skipping cert generation."
  exit 0
fi

# The certificate's common name.
if [ "${#}" -lt "1" ]; then
  fatal "COMMON_NAME is required ${USAGE}"
fi
TLS_COMMON_NAME="${1}"

# Make a temporary directory and switch to it.
OLD_DIR="$(pwd)"
pushd "$(mktemp -d)"
TLS_TMP_DIR="$(pwd)"

# Returns the absolute path of the provided argument.
abspath() {
  { [ "$(printf %.1s "${1}")" = "/" ] && echo "${1}"; } || echo "${OLD_DIR}/${1}"
}

# Write the SSL config file to disk.
cat >ssl.conf <<EOF
[ req ]
default_bits           = ${TLS_DEFAULT_BITS}
encrypt_key            = no
default_md             = sha1
prompt                 = no
utf8                   = yes
distinguished_name     = dn
req_extensions         = ext
x509_extensions        = ext

[ dn ]
countryName            = ${TLS_COUNTRY_NAME}
stateOrProvinceName    = ${TLS_STATE_OR_PROVINCE_NAME}
localityName           = ${TLS_LOCALITY_NAME}
organizationName       = ${TLS_ORG_NAME}
organizationalUnitName = ${TLS_OU_NAME}
commonName             = ${TLS_COMMON_NAME}

[ ext ]
basicConstraints       = critical, CA:TRUE
keyUsage               = critical, cRLSign, digitalSignature, keyCertSign
subjectKeyIdentifier   = hash
EOF

[ -z "${VERBOSE}" ] || cat ssl.conf

# Generate a a self-signed certificate:
openssl req -config ssl.conf \
            -new \
            -nodes \
            -x509 \
            -days "${TLS_DEFAULT_DAYS}" \
            -keyout "${TLS_FILE_PREFIX}.key" \
            -out "${TLS_FILE_PREFIX}.crt"

# "Fix" the private key. Keys generated by "openssl req" are not
# in the correct format.
openssl rsa -in "${TLS_FILE_PREFIX}.key" -out "${TLS_FILE_PREFIX}.key.fixed"
mv -f "${TLS_FILE_PREFIX}.key.fixed" "${TLS_FILE_PREFIX}.key"

if [[ ! -f "${TLS_FILE_PREFIX}.crt" || ! -f "${TLS_FILE_PREFIX}.key" ]]; then
  echo "failed to output certificate and key"
  exit 1
fi

# Copy the files to OUT_DIR
cp -f "${TLS_FILE_PREFIX}.crt" "${TLS_FILE_PREFIX}.key" "$(abspath "${OUT_DIR}")"

# Print the certificate's information if requested.
[ -z "${VERBOSE}" ] || { echo && openssl x509 -noout -text <"${TLS_FILE_PREFIX}.crt"; }

# Return to the original directory and cleanup the temporary TLS dir.
popd
rm -fr "${TLS_TMP_DIR}"

