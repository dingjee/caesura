# The identity the bundles of this project are signed with.
#
# The identity is resolved in this order:
#   1. CAESURA_NATIVE_SIGN_IDENTITY — the environment always wins.
#   2. native/scripts/signing-identity.local — a plain text file with one
#      line: the name of the certificate ("Apple Development: Name (TEAMID)").
#      The file is ignored by git, so the choice of one developer never
#      reaches another one, and a checkout without it keeps working.
#   3. nothing — the bundles are signed ad-hoc, which needs no identity and
#      no keychain access at all.
#
# Both package-app.sh and install-dist.sh use this file, so the bundle that
# is installed carries the same signature as the bundle that was built:
# install-dist.sh never re-signs a signed bundle ad-hoc.
#
# This file is sourced, never run.

# The root of the repository: the file lives in native/scripts/. It is
# resolved once, while the file is sourced — the prompt expansion of zsh
# names the function, not the file, when it is used inside one.
SIGNING_IDENTITY_ROOT="$(cd "$(dirname "${(%):-%N}")/../.." && pwd)"

# The path of the local identity file.
signing_identity_file() {
  echo "$SIGNING_IDENTITY_ROOT/native/scripts/signing-identity.local"
}

# The identity to sign with — empty when there is none.
resolve_sign_identity() {
  local identity="${CAESURA_NATIVE_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    local file
    file="$(signing_identity_file)"
    if [[ -f "$file" ]]; then
      identity="$(head -1 "$file" | tr -d '\r')"
    fi
  fi
  # A trimmed name: a file with a trailing newline must not break codesign.
  identity="${identity#"${identity%%[![:space:]]*}"}"
  identity="${identity%"${identity##*[![:space:]]}"}"
  printf '%s' "$identity"
}

# Signs a bundle with the resolved identity (ad-hoc when there is none).
#
# The nested executables are signed first — the command line client, then the
# application — and the bundle is sealed over them, so the seal of the bundle
# covers exactly these signatures.
sign_bundle() {
  local app="$1" identity bin
  local runtime=()
  identity="$(resolve_sign_identity)"
  if [[ -n "$identity" ]]; then
    # A notarized release requires the hardened runtime, and the runtime
    # belongs to the release identity: a "Developer ID Application" signature
    # carries it, a development or ad-hoc signature stays as it was.
    [[ "$identity" == "Developer ID Application: "* ]] && runtime=(--options runtime)
    echo "== codesign with the identity: $identity${runtime:+ (hardened runtime)} =="
    if [[ -d "$app/Contents/Frameworks/MediaRemoteAdapter.framework" ]]; then
      codesign --force "${runtime[@]}" --sign "$identity" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
    fi
    for bin in caesura-cli Caesura; do
      if [[ -x "$app/Contents/MacOS/$bin" ]]; then
        codesign --force "${runtime[@]}" --sign "$identity" "$app/Contents/MacOS/$bin"
      fi
    done
    codesign --force "${runtime[@]}" --sign "$identity" "$app"
  else
    echo "== ad-hoc codesign =="
    codesign --force --deep --sign - "$app"
  fi
}

# The authority of the signature of a bundle (empty when it is ad-hoc).
signature_authority() {
  local app="$1"
  codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Authority=//p' | head -1
}

# The team of the signature of a bundle (empty when it is ad-hoc).
signature_team() {
  local app="$1"
  codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1
}

# The designated requirement of a bundle (one line).
designated_requirement() {
  local app="$1"
  codesign -d -r- "$app" 2>/dev/null | sed -n 's/^designated => //p' | head -1
}

# The fingerprint (SHA-1) of the leaf certificate a bundle is signed with.
leaf_fingerprint() {
  local app="$1" dir prefix leaf fingerprint
  dir="$(mktemp -d "${TMPDIR:-/tmp}/caesura-cert-XXXXXX")" || return 1
  prefix="$dir/cert"
  codesign -d --extract-certificates="$prefix" "$app" >/dev/null 2>&1 || {
    rm -rf "$dir"
    return 1
  }
  # The leaf is the first certificate: the number belongs to the prefix
  # (zsh reads "$prefix0" as one variable name).
  leaf="${prefix}0"
  if [[ ! -f "$leaf" ]]; then
    rm -rf "$dir"
    return 1
  fi
  fingerprint="$(openssl x509 -inform der -in "$leaf" -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z')"
  rm -rf "$dir"
  printf '%s' "$fingerprint"
}

# The fingerprint (SHA-1) of a signing identity of this keychain (empty when
# the identity is not here).
identity_fingerprint() {
  local identity="$1"
  security find-identity -v -p codesigning 2>/dev/null | awk -v want="$identity" '
    /^ *[0-9]+\) [0-9A-Fa-f]{40} "/ {
      hash = $2
      name = $0
      sub(/^[^"]*"/, "", name)
      sub(/"$/, "", name)
      if (name == want) { print tolower(hash); exit }
    }'
}

# Checks that a bundle carries the expected identity.
#
# The check is thorough on purpose: the authority of the bundle and of both
# of its executables has to be the expected certificate, the team of the three
# signatures has to be the same one, and the designated requirement of the
# bundle has to be the stable one of that identity — an ad-hoc signature has
# a requirement of nothing but the hash of the binary, and macOS would ask
# for the accessibility permission again after every rebuild.
verify_signed_identity() {
  local app="$1" identity="$2" bin authority team bundle_team requirement
  for bin in caesura-cli Caesura; do
    [[ -x "$app/Contents/MacOS/$bin" ]] || continue
    authority="$(signature_authority "$app/Contents/MacOS/$bin")"
    [[ "$authority" == "$identity" ]] || {
      echo "FAIL: $bin is signed by '$authority' (expected '$identity')" >&2
      return 1
    }
  done
  authority="$(signature_authority "$app")"
  [[ "$authority" == "$identity" ]] || {
    echo "FAIL: the bundle is signed by '$authority' (expected '$identity')" >&2
    return 1
  }
  bundle_team="$(signature_team "$app")"
  [[ -n "$bundle_team" ]] || {
    echo "FAIL: the bundle carries no team identifier (the signature is ad-hoc)" >&2
    return 1
  }
  for bin in caesura-cli Caesura; do
    [[ -x "$app/Contents/MacOS/$bin" ]] || continue
    team="$(signature_team "$app/Contents/MacOS/$bin")"
    [[ "$team" == "$bundle_team" ]] || {
      echo "FAIL: $bin carries the team '$team', the bundle carries '$bundle_team'" >&2
      return 1
    }
  done
  requirement="$(designated_requirement "$app")"
  [[ "$requirement" == *"certificate"* && "$requirement" != *"cdhash"* ]] || {
    echo "FAIL: the designated requirement is not the stable one of the identity: $requirement" >&2
    return 1
  }
  # The leaf certificate of the signature has to be the certificate of that
  # identity: the name alone could carry another certificate of the same
  # person. The team is never written down — it is read from the signature.
  local expected_fingerprint actual_fingerprint
  expected_fingerprint="$(identity_fingerprint "$identity")"
  if [[ -n "$expected_fingerprint" ]]; then
    actual_fingerprint="$(leaf_fingerprint "$app")"
    [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
      echo "FAIL: the bundle is signed with the certificate '$actual_fingerprint', "
      echo "      the identity '$identity' is '$expected_fingerprint'" >&2
      return 1
    }
    echo "  leaf certificate: $actual_fingerprint"
  fi
  echo "  signed with: $identity (team $bundle_team)"
  return 0
}
