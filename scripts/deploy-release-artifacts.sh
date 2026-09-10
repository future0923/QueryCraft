#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/deploy-release-artifacts.sh <version> <artifact-directory>

When QUERYCRAFT_DEPLOY_CLIENT=true, the artifact directory must contain:
  QueryCraft-<version>.zip
  QueryCraft-<version>-x86_64.dmg
  QueryCraft-<version>-arm64.dmg
  appcast.xml
  release-notes.md

When QUERYCRAFT_DEPLOY_DRIVERS=true, it must also contain the MySQL,
PostgreSQL, Doris, Redis, and Elasticsearch manifests and referenced archives
for both architectures.

Required environment when publishing:
  QUERYCRAFT_RESOURCE_DEPLOY_URL    Resource deployment API base URL
  QUERYCRAFT_RESOURCE_DEPLOY_TOKEN  Deployment bearer token

Optional environment:
  QUERYCRAFT_UPDATE_BASE_URL        Default: https://querycraft.debug-tools.cc
  QUERYCRAFT_DEPLOY_VALIDATE_ONLY   Validate without uploading (default: false)
  QUERYCRAFT_DEPLOY_CLIENT          Upload application artifacts (default: true)
  QUERYCRAFT_DEPLOY_DRIVERS         Upload driver artifacts (default: true)
EOF
}

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

version="$1"
artifact_directory="$(cd "$2" && pwd)"
deploy_url="${QUERYCRAFT_RESOURCE_DEPLOY_URL:-}"
deploy_url="${deploy_url%/}"
deploy_token="${QUERYCRAFT_RESOURCE_DEPLOY_TOKEN:-}"
base_url="${QUERYCRAFT_UPDATE_BASE_URL:-https://querycraft.debug-tools.cc}"
base_url="${base_url%/}"
validate_only="${QUERYCRAFT_DEPLOY_VALIDATE_ONLY:-false}"
deploy_client="${QUERYCRAFT_DEPLOY_CLIENT:-true}"
deploy_drivers="${QUERYCRAFT_DEPLOY_DRIVERS:-true}"
temporary_driver_manifest_directory="$(mktemp -d "${RUNNER_TEMP:-/tmp}/querycraft-driver-manifests.XXXXXX")"

cleanup() {
    rm -rf "$temporary_driver_manifest_directory"
}
trap cleanup EXIT

if [[ ! "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 65
fi
if [[ "$base_url" != https://* ]]; then
    echo "QUERYCRAFT_UPDATE_BASE_URL must use HTTPS." >&2
    exit 65
fi
if [[ "$validate_only" != "true" && "$validate_only" != "false" ]]; then
    echo "QUERYCRAFT_DEPLOY_VALIDATE_ONLY must be true or false." >&2
    exit 65
fi
if [[ "$deploy_client" != "true" && "$deploy_client" != "false" ]]; then
    echo "QUERYCRAFT_DEPLOY_CLIENT must be true or false." >&2
    exit 65
fi
if [[ "$deploy_drivers" != "true" && "$deploy_drivers" != "false" ]]; then
    echo "QUERYCRAFT_DEPLOY_DRIVERS must be true or false." >&2
    exit 65
fi
if [[ "$deploy_client" == "false" && "$deploy_drivers" == "false" ]]; then
    echo "At least one application or driver deployment must be enabled." >&2
    exit 65
fi

for command_name in curl jq shasum stat xmllint; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command not found: $command_name" >&2
        exit 69
    fi
done

update_zip="$artifact_directory/QueryCraft-$version.zip"
intel_dmg="$artifact_directory/QueryCraft-$version-x86_64.dmg"
arm_dmg="$artifact_directory/QueryCraft-$version-arm64.dmg"
appcast="$artifact_directory/appcast.xml"
release_notes="$artifact_directory/release-notes.md"
release_build=""
minimum_system_version=""
ed_signature=""
if [[ "$deploy_client" == "true" ]]; then
    for required_file in \
        "$update_zip" \
        "$intel_dmg" \
        "$arm_dmg" \
        "$appcast" \
        "$release_notes"
    do
        if [[ ! -f "$required_file" ]]; then
            echo "Required release artifact not found: $required_file" >&2
            exit 66
        fi
    done

    item_xpath="//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version']]"
    release_build="$(xmllint --xpath "string(($item_xpath/*[local-name()='version'])[1])" "$appcast")"
    minimum_system_version="$(xmllint --xpath "string(($item_xpath/*[local-name()='minimumSystemVersion'])[1])" "$appcast")"
    ed_signature="$(xmllint --xpath "string(($item_xpath/*[local-name()='enclosure']/@*[local-name()='edSignature'])[1])" "$appcast")"
    update_url="$(xmllint --xpath "string(($item_xpath/*[local-name()='enclosure']/@url)[1])" "$appcast")"
    if [[ ! "$release_build" =~ ^[0-9]+$ || -z "$minimum_system_version" || -z "$ed_signature" || \
          "$update_url" != "$base_url/releases/QueryCraft-$version.zip" ]]; then
        echo "The appcast metadata for QueryCraft $version is incomplete or invalid." >&2
        exit 65
    fi
fi

driver_archives=()
driver_manifests=()
for database_type in mysql postgresql doris redis elasticsearch; do
    for architecture in x86_64 arm64; do
        manifest="$artifact_directory/$database_type-$architecture.json"
        if [[ "$deploy_drivers" == "false" ]]; then
            catalog="$temporary_driver_manifest_directory/$database_type-$architecture-catalog.json"
            manifest="$temporary_driver_manifest_directory/$database_type-$architecture.json"
            curl --fail --silent --show-error --location \
                "$base_url/drivers/$database_type-$architecture.json" \
                --output "$catalog"
            if ! jq -e \
                --arg database_type "$database_type" \
                --arg architecture "$architecture" \
                '.schemaVersion == 2 and
                 .databaseType == $database_type and
                 .architecture == $architecture and
                 (.releases | type == "array" and length > 0)' \
                "$catalog" >/dev/null
            then
                echo "Published driver catalog is invalid: $database_type-$architecture.json" >&2
                exit 65
            fi
            jq -e \
                '.releases | max_by([.driverAPIVersion, (.build | tonumber), .version])' \
                "$catalog" > "$manifest"
        fi
        if [[ ! -f "$manifest" ]]; then
            echo "Driver manifest not found: $manifest" >&2
            exit 66
        fi
        if ! jq -e \
            --arg database_type "$database_type" \
            --arg architecture "$architecture" \
            '.databaseType == $database_type and
             (.version | type == "string" and length > 0) and
             (.build | type == "string" and length > 0) and
             (.minimumAppVersion | type == "string" and length > 0) and
             (.driverAPIVersion | type == "number" and . > 0) and
             (.supportedArchitectures | length == 1) and
             .supportedArchitectures[0] == $architecture' \
            "$manifest" >/dev/null
        then
            echo "Driver manifest identity is invalid: $manifest" >&2
            exit 65
        fi
        archive_url="$(jq -er '.downloadURL' "$manifest")"
        archive_name="${archive_url##*/}"
        if [[ ! "$archive_name" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*\.zip$ || \
              "$archive_url" != "$base_url/drivers/$archive_name" ]]; then
            echo "Driver download URL is invalid: $manifest" >&2
            exit 65
        fi
        archive="$artifact_directory/$archive_name"
        if [[ "$deploy_drivers" == "false" ]]; then
            if ! curl --fail --silent --show-error --head --location "$archive_url" -o /dev/null; then
                echo "Published driver archive is unavailable: $archive_url" >&2
                exit 66
            fi
            driver_manifests+=("$manifest")
            continue
        fi
        if [[ ! -f "$archive" ]]; then
            echo "Driver archive not found: $archive" >&2
            exit 66
        fi
        expected_sha256="$(jq -er '.sha256' "$manifest")"
        actual_sha256="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
        expected_size="$(jq -er '.downloadSize' "$manifest")"
        if [[ "$(uname -s)" == "Darwin" ]]; then
            actual_size="$(stat -f %z "$archive")"
        else
            actual_size="$(stat -c %s "$archive")"
        fi
        if [[ "$actual_sha256" != "$expected_sha256" || "$actual_size" != "$expected_size" ]]; then
            echo "Driver archive digest or size does not match: $archive" >&2
            exit 65
        fi
        driver_archives+=("$archive")
        driver_manifests+=("$manifest")
    done
done

if [[ "$validate_only" == "true" ]]; then
    echo "Validated QueryCraft $version selected release artifacts."
    exit 0
fi

if [[ "$deploy_url" != https://* || ${#deploy_token} -lt 32 ]]; then
    echo "A HTTPS QUERYCRAFT_RESOURCE_DEPLOY_URL and a deployment token of at least 32 characters are required." >&2
    exit 64
fi

curl_deploy() {
    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --retry 3 \
        --retry-all-errors \
        --header "Authorization: Bearer $deploy_token" \
        "$@"
}

# Drivers are published first. The application appcast is switched only after
# every database and architecture is ready for the new application release.
if [[ "$deploy_drivers" == "true" ]]; then
    for index in "${!driver_manifests[@]}"; do
        manifest="${driver_manifests[$index]}"
        archive="${driver_archives[$index]}"
        architecture="$(jq -er '.supportedArchitectures[0]' "$manifest")"
        curl_deploy \
            --form-string "database_type=$(jq -er '.databaseType' "$manifest")" \
            --form-string "version=$(jq -er '.version' "$manifest")" \
            --form-string "build=$(jq -er '.build' "$manifest")" \
            --form-string "architecture=$architecture" \
            --form-string "minimum_app_version=$(jq -er '.minimumAppVersion' "$manifest")" \
            --form-string "driver_api_version=$(jq -er '.driverAPIVersion' "$manifest")" \
            --form "archive=@$archive;type=application/zip" \
            "$deploy_url/drivers"
    done
fi

published_application_matches() {
    local candidate remote_signature architecture
    if ! candidate="$(curl --fail --silent --show-error --location "$base_url/appcast.xml")"; then
        return 1
    fi
    if ! xmllint --xpath \
        "boolean(//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version'] and *[local-name()='version' and text()='$release_build']])" \
        - <<<"$candidate" | grep -q true
    then
        return 1
    fi
    remote_signature="$(xmllint --xpath \
        "string((//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version']]/*[local-name()='enclosure']/@*[local-name()='edSignature'])[1])" \
        - <<<"$candidate")"
    if [[ "$remote_signature" != "$ed_signature" ]]; then
        return 1
    fi
    for architecture in x86_64 arm64; do
        if ! curl --fail --silent --show-error --head --location \
            "$base_url/releases/QueryCraft-$version-$architecture.dmg" -o /dev/null
        then
            return 1
        fi
    done
    published_appcast="$candidate"
}

if [[ "$deploy_client" == "true" ]]; then
    if published_application_matches; then
        echo "QueryCraft $version application artifacts are already published; skipping upload."
    else
        if ! curl_deploy \
            --retry 0 \
            --form-string "version=$version" \
            --form-string "build=$release_build" \
            --form-string "minimum_system_version=$minimum_system_version" \
            --form-string "ed_signature=$ed_signature" \
            --form "release_notes=<$release_notes" \
            --form "archive=@$update_zip;type=application/zip" \
            --form "dmg_x86_64=@$intel_dmg;type=application/octet-stream" \
            --form "dmg_arm64=@$arm_dmg;type=application/octet-stream" \
            "$deploy_url/applications"
        then
            echo "Application upload response failed; verifying the published state." >&2
        fi
    fi

    published_appcast="$(curl --fail --silent --show-error --location "$base_url/appcast.xml")"
    if ! xmllint --xpath \
        "boolean(//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version'] and *[local-name()='version' and text()='$release_build']])" \
        - <<<"$published_appcast" | grep -q true
    then
        echo "Published appcast does not contain QueryCraft $version ($release_build)." >&2
        exit 65
    fi
    published_signature="$(xmllint --xpath \
        "string((//*[local-name()='item'][*[local-name()='shortVersionString' and text()='$version']]/*[local-name()='enclosure']/@*[local-name()='edSignature'])[1])" \
        - <<<"$published_appcast")"
    if [[ "$published_signature" != "$ed_signature" ]]; then
        echo "Published appcast signature does not match QueryCraft $version." >&2
        exit 65
    fi
    for architecture in x86_64 arm64; do
        curl --fail --silent --show-error --head --location \
            "$base_url/releases/QueryCraft-$version-$architecture.dmg" -o /dev/null
    done
fi
for manifest in "${driver_manifests[@]}"; do
    manifest_name="$(basename "$manifest")"
    database_type="$(jq -er '.databaseType' "$manifest")"
    driver_version="$(jq -er '.version' "$manifest")"
    driver_build="$(jq -er '.build' "$manifest")"
    architecture="$(jq -er '.supportedArchitectures[0]' "$manifest")"
    local_sha256="$(jq -er '.sha256' "$manifest")"
    remote_sha256="$(curl --fail --silent --show-error --location \
        "$base_url/drivers/$manifest_name" | jq -er \
        --arg database_type "$database_type" \
        --arg driver_version "$driver_version" \
        --arg driver_build "$driver_build" \
        --arg architecture "$architecture" \
        'select(.schemaVersion == 2 and
                .databaseType == $database_type and
                .architecture == $architecture) |
         .releases[] |
         select(.databaseType == $database_type and
                .version == $driver_version and
                .build == $driver_build and
                .supportedArchitectures == [$architecture]) |
         .sha256')"
    if [[ "$remote_sha256" != "$local_sha256" ]]; then
        echo "Published driver manifest does not match: $manifest_name" >&2
        exit 65
    fi
done

echo "Published QueryCraft $version through LicenseServer resource management."
if [[ "$deploy_client" == "true" ]]; then
    echo "Feed: $base_url/appcast.xml"
    echo "Intel DMG: $base_url/releases/QueryCraft-$version-x86_64.dmg"
    echo "Apple Silicon DMG: $base_url/releases/QueryCraft-$version-arm64.dmg"
fi
