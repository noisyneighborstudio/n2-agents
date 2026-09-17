#!/bin/zsh
set -euo pipefail

channel=${1:?channel required}
version=${2:?version required}
build_version=${3:?build version required}
download_url=${4:?download URL required}
artifact=${5:?artifact required}
signature=${6:?Sparkle EdDSA signature required}
output=${7:?output path required}

[[ $channel == stable || $channel == continuous ]] || { echo "invalid channel" >&2; exit 1; }
[[ $version =~ '^[A-Za-z0-9.-]+$' ]] || { echo "invalid version" >&2; exit 1; }
[[ $download_url == *"/N2Agents-${channel}-"* ]] || { echo "artifact URL does not match channel" >&2; exit 1; }
[[ ${download_url:t} == ${artifact:t} ]] || { echo "artifact URL filename mismatch" >&2; exit 1; }
[[ $build_version =~ '^[0-9]+(\.[0-9]+)*$' ]] || { echo "invalid build version" >&2; exit 1; }
[[ ${#signature} -eq 88 && $signature =~ '^[A-Za-z0-9+/]{86}==$' ]] || { echo "invalid signature" >&2; exit 1; }
[[ -f $artifact ]] || { echo "artifact not found" >&2; exit 1; }

length=$(stat -f %z "$artifact")
published=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')
mkdir -p "${output:h}"
{
  print '<?xml version="1.0" encoding="utf-8"?>'
  print '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  print '<channel><title>Claudes Updates</title><item>'
  print "<title>Claudes ${version}</title><pubDate>${published}</pubDate>"
  print "<sparkle:channel>${channel}</sparkle:channel>"
  print "<enclosure url=\"${download_url}\" sparkle:version=\"${build_version}\" sparkle:shortVersionString=\"${version}\" length=\"${length}\" type=\"application/octet-stream\" sparkle:edSignature=\"${signature}\"/>"
  print '</item></channel></rss>'
} > "$output"
