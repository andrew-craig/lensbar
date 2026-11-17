#!/usr/bin/env bash
# Verify the signature, entitlements and embedded profiles of a LensBar.app and
# its LensBar Camera system extension.
#
#   scripts/verify-signing.sh <LensBar.app> <stage> [expected archs]
#
# stage:
#   codesign      signature, entitlements, profiles, archs only (any identity)
#   pre-notarize  codesign + Developer ID + Gatekeeper sees an unnotarized Developer ID app
#   post-staple   codesign + Developer ID + Gatekeeper accepts it as notarized, ticket stapled
#
# expected archs: e.g. "arm64" or "arm64 x86_64"; checked on both executables.
# Env: TEAM_ID (default B8A6HLKG3J).
set -euo pipefail

APP="${1:?usage: verify-signing.sh <LensBar.app> <codesign|pre-notarize|post-staple> [archs]}"
STAGE="${2:?missing stage}"
ARCHS="${3:-}"
TEAM_ID="${TEAM_ID:-B8A6HLKG3J}"
EXT="$APP/Contents/Library/SystemExtensions/com.andrewcraig.LensBar.Camera.systemextension"

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok:   $*"; }

entitlement() { # entitlement <bundle> <key>
  local tmp
  tmp="$(mktemp)"
  codesign -d --entitlements - --xml "$1" 2>/dev/null > "$tmp" || true
  [ -s "$tmp" ] && { /usr/libexec/PlistBuddy -c "Print :$2" "$tmp" 2>/dev/null || true; }
  rm -f "$tmp"
}

check_bundle() { # check_bundle <label> <bundle>
  local label="$1" bundle="$2" info
  [ -d "$bundle" ] || { fail "$label missing at $bundle"; return; }

  info="$(codesign -dvv "$bundle" 2>&1 || true)"
  grep -q "^TeamIdentifier=$TEAM_ID$" <<<"$info" \
    && ok "$label team $TEAM_ID" || fail "$label TeamIdentifier is not $TEAM_ID"
  grep -Eq "^CodeDirectory .*flags=.*runtime" <<<"$info" \
    && ok "$label hardened runtime" || fail "$label is not signed with the hardened runtime"
  if [ "$STAGE" != codesign ]; then
    grep -q "^Authority=Developer ID Application:" <<<"$info" \
      && ok "$label signed with Developer ID Application" \
      || fail "$label is not signed with Developer ID Application"
    grep -q "^Timestamp=" <<<"$info" \
      && ok "$label has a secure timestamp" || fail "$label has no secure timestamp"
  fi

  # Development builds only embed a profile when an entitlement needs one, so
  # the extension may have none there. Developer ID builds must embed both.
  if [ -f "$bundle/Contents/embedded.provisionprofile" ]; then
    ok "$label embeds a provisioning profile"
  elif [ "$STAGE" = codesign ]; then
    echo "note: $label has no embedded.provisionprofile"
  else
    fail "$label has no embedded.provisionprofile"
  fi

  if [ -n "$ARCHS" ]; then
    local exe actual
    exe="$bundle/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
    actual="$(lipo -archs "$exe" 2>/dev/null | tr ' ' '\n' | sort | xargs)"
    [ "$actual" = "$(tr ' ' '\n' <<<"$ARCHS" | sort | xargs)" ] \
      && ok "$label archs: $actual" || fail "$label archs are '$actual', expected '$ARCHS'"
  fi
}

echo "== Verifying $APP ($STAGE)"

codesign --verify --deep --strict "$APP" \
  && ok "codesign --verify --deep --strict" || fail "codesign --verify --deep --strict"

check_bundle "app" "$APP"
check_bundle "extension" "$EXT"

# App: may install system extensions, stays unsandboxed (IOKit access).
[ "$(entitlement "$APP" com.apple.developer.system-extension.install)" = true ] \
  && ok "app has system-extension.install" || fail "app lacks com.apple.developer.system-extension.install"
[ "$(entitlement "$APP" com.apple.security.app-sandbox)" != true ] \
  && ok "app is not sandboxed" || fail "app is sandboxed (IOKit UVC control needs it off)"

# Extension: camera extensions must be sandboxed and in the team's app group,
# which prefixes the Mach service name in its Info.plist.
[ "$(entitlement "$EXT" com.apple.security.app-sandbox)" = true ] \
  && ok "extension is sandboxed" || fail "extension is not sandboxed"
groups="$(entitlement "$EXT" com.apple.security.application-groups)"
grep -q "$TEAM_ID.com.andrewcraig.LensBar" <<<"$groups" \
  && ok "extension app group $TEAM_ID.com.andrewcraig.LensBar" \
  || fail "extension app group is not $TEAM_ID.com.andrewcraig.LensBar (got: $groups)"
mach="$(/usr/libexec/PlistBuddy -c 'Print :CMIOExtension:CMIOExtensionMachServiceName' "$EXT/Contents/Info.plist" 2>/dev/null || true)"
[ "$mach" = "$TEAM_ID.com.andrewcraig.LensBar.Camera" ] \
  && ok "extension Mach service $mach" || fail "extension Mach service is '$mach'"

case "$STAGE" in
  codesign) ;;
  pre-notarize)
    # Gatekeeper rejects an unnotarized app; what matters is that it sees Developer ID.
    out="$(spctl -a -vv -t exec "$APP" 2>&1 || true)"
    echo "$out"
    grep -q "source=Unnotarized Developer ID\|source=Notarized Developer ID" <<<"$out" \
      && ok "Gatekeeper sees a Developer ID signature" \
      || fail "Gatekeeper does not see a Developer ID signature"
    ;;
  post-staple)
    out="$(spctl -a -vv -t exec "$APP" 2>&1)" && accepted=1 || accepted=0
    echo "$out"
    [ "$accepted" = 1 ] && grep -q "source=Notarized Developer ID" <<<"$out" \
      && ok "Gatekeeper accepts the notarized app" || fail "Gatekeeper does not accept the app as notarized"
    xcrun stapler validate "$APP" >/dev/null \
      && ok "notarization ticket stapled" || fail "no stapled notarization ticket"
    ;;
  *) echo "unknown stage: $STAGE" >&2; exit 2 ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "== $failures check(s) failed" >&2
  exit 1
fi
echo "== All checks passed"
