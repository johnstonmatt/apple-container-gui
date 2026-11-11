#!/bin/zsh
# Interactive credential validation and upload, adapted from Lock In.
set -euo pipefail
unsetopt XTRACE VERBOSE
umask 077
cd "${0:A:h}/.."
[[ "$(uname -s)" == Darwin && -t 0 ]] || { print -u2 'Run this in an interactive macOS terminal.'; exit 1; }
gh auth status
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
print -r -- "Release credential setup for Container ($repo)"
print -- 'Export a Developer ID Application certificate with its private key as .p12.'
read -r 'certificate?Path to .p12: '
certificate=${(Q)certificate}
certificate=${certificate/#\~/$HOME}
[[ -f "$certificate" ]] || { print -u2 'Certificate file not found.'; exit 1; }
read -rs 'certificate_password?Export password (may be empty): '
print
setup_temp=$(mktemp -d)
keychain="$setup_temp/verify.keychain-db"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf -- "$setup_temp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
keychain_password=$(uuidgen)
security create-keychain -p "$keychain_password" "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -k "$keychain" -P "$certificate_password" -T /usr/bin/codesign >/dev/null
identities=("${(@f)$(security find-identity -v -p codesigning "$keychain" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p')}")
(( ${#identities} > 0 )) && [[ -n "$identities[1]" ]] || { print -u2 'No valid Developer ID Application identity with private key found.'; exit 1; }
identity="$identities[1]"
if (( ${#identities} > 1 )); then
  select identity in "${identities[@]}"; do [[ -n "$identity" ]] && break; done
fi
print -r -- "Verified signing identity: $identity"
print -- 'Use an App Store Connect Team API key with notarization access.'
read -r 'api_key?Path to AuthKey_*.p8: '
api_key=${(Q)api_key}
api_key=${api_key/#\~/$HOME}
[[ -f "$api_key" ]] || { print -u2 'API key file not found.'; exit 1; }
read -r 'key_id?API key ID: '
read -r 'issuer?Issuer UUID: '
xcrun notarytool history --key "$api_key" --key-id "$key_id" --issuer "$issuer" > "$setup_temp/notary-check.txt"
print -- 'Apple accepted the notarization credentials.'
print -r -- "Will set/replace these secrets on $repo:"
secret_names=(MACOS_CERTIFICATE MACOS_CERTIFICATE_PASSWORD MACOS_SIGN_IDENTITY APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER)
print -rl -- "${secret_names[@]}"
read -r 'answer?Write these secrets to GitHub? [y/N] '
[[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { print 'Nothing was uploaded.'; exit 0; }
# Values go through stdin, never gh arguments or terminal output.
base64 < "$certificate" | tr -d '\n' | gh secret set MACOS_CERTIFICATE --repo "$repo"
print -rn -- "$certificate_password" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$repo"
print -rn -- "$identity" | gh secret set MACOS_SIGN_IDENTITY --repo "$repo"
base64 < "$api_key" | tr -d '\n' | gh secret set APPLE_API_KEY --repo "$repo"
print -rn -- "$key_id" | gh secret set APPLE_API_KEY_ID --repo "$repo"
print -rn -- "$issuer" | gh secret set APPLE_API_ISSUER --repo "$repo"
print -- 'Release secrets configured. Local credential files were kept.'
print -- 'Optional: set RELEASE_PLEASE_TOKEN so release PRs can trigger CI.'
