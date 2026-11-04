#!/usr/bin/env bash
set -e

REDOCLY="npx -y @redocly/cli@2.19.0"

rm -rf build/redoc
mkdir -p build/redoc
mkdir -p publish

# Function to update operationId with the suffix, as they may overlap with other specs
update_operation_ids() {
    local file="$1"
    local suffix="$2"

    # Use yq to add the suffix to the operationId
    yq eval '(.paths[] | .[] | select(has("operationId")) | .operationId) += "'"$suffix"'"' -i "$file"
}

# Descriptions link to tags and operations by their pre-join names, so the operationId rename
# above and the tag prefixing done by `redocly join` leave those anchors pointing at nothing.
# Rename them the same way, which means this must be given the same suffix as update_operation_ids.
# A tag segment that already holds an underscore is a link into another spec, and keeps the prefix
# it was written with.
rewrite_anchor_links() {
    PREFIX="$1" OP_SUFFIX="$2" perl -0777 -pe '
        my ($p, $s) = ($ENV{PREFIX}, $ENV{OP_SUFFIX});
        s{\(\#tag/(?![^)/]*_)([^)/]+)/operation/([^)]+)\)}{(#tag/${p}_$1/operation/$2$s)}g;
        s{\(\#tag/(?![^)/]*_)([^)/]+)((?:/[^)]+)?)\)}{(#tag/${p}_$1$2)}g;
    '
}

update_anchor_links() {
    local file="$1"
    local tmp="${file}.anchors"

    rewrite_anchor_links "$2" "$3" < "$file" > "$tmp"
    mv "$tmp" "$file"
}

for projectFolder in pull/*/ ; do
    folderName=$(basename "$projectFolder")

    # Check if the folder name contains only numbers, in which case it's an old Monolith-only pull and should be skipped
    if [[ "$folderName" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # We get the newest folder by alphabetical order, as subsequent pushes will get higher numbers
    newestSubfolder=$(ls -d "$projectFolder"* | grep -v "^~/$" | sort | tail -n 1)

    find "$newestSubfolder" -type f -name '*.yaml' | while read -r file; do
        # Extract the x-prefix
        prefix=$(yq eval '.info["x-prefix"]' "$file")

        # Check if the x-prefix is not null, add it and fallback to application (folder) name
        if [[ "$prefix" == "null" ]]; then
            echo "No x-prefix found in $file"
            echo "Falling back to folder name: $folderName"
            prefix=folderName
        fi

        # Copy the file to the build folder, and add the prefix to avoid duplicates from across apps
        buildFile="build/redoc/${prefix}-$(basename "$file")"
        cp "$file" "$buildFile"

        originalPrefix=$(yq eval '.info["x-prefix"]' "$file")

        if [[ "$originalPrefix" == "null" ]]; then
            yq eval ".info[\"x-prefix\"] = \"${prefix}\"" -i "$buildFile"
        fi

        opSuffix="--${prefix}"

        update_operation_ids "$buildFile" "$opSuffix"
        update_anchor_links "$buildFile" "$prefix" "$opSuffix"
    done
done

$REDOCLY join build/redoc/*.yaml -o build/redoc/openapi.yaml --prefix-components-with-info-prop x-prefix --prefix-tags-with-info-prop x-prefix

# Set OpenAPI version and title
yq eval '.openapi = "3.1.0"' -i build/redoc/openapi.yaml
yq eval '.info.title = "Ankorstore APIs"' -i build/redoc/openapi.yaml

spec='build/redoc/openapi.yaml'

# Generate changelog and inject it into the combined spec. It is read back out of the Ankorstore
# spec as it was pulled, so its anchors still need renaming.
CHANGELOG=$(./hack/generate-changelog.sh | rewrite_anchor_links Ankorstore "--Ankorstore")
yq '.tags = [{"name": "Changelog", "description": "PLACEHOLDER"}] + .tags' -i "$spec"
CHANGELOG="$CHANGELOG" yq '(.tags[] | select(.name == "Changelog")).description = strenv(CHANGELOG)' -i "$spec"
# Remove the old prefixed Ankorstore_Changelog from tags and x-tagGroups, replaced by the new combined one
yq 'del(.tags[] | select(.name == "Ankorstore_Changelog"))' -i "$spec"
yq '.x-tagGroups[0].tags = ["Changelog"] + (.x-tagGroups[0].tags | map(select(. != "Ankorstore_Changelog")))' -i "$spec"
# The combined Changelog tag is the one exception to the prefixing, so point its links back at it
perl -pi -e 's{\(\#tag/Ankorstore_Changelog(?=[/)])}{(#tag/Changelog}g' "$spec"

$REDOCLY build-docs -t redoc/index.hbs -o build/docs/index.html "$spec" --config redoc/redocly.yaml

cp build/docs/index.html publish/index.html
