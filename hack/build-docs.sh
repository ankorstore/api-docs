#!/usr/bin/env bash
set -e

REDOCLY="npx -y @redocly/cli@2.19.0"

rm -rf build/redoc
mkdir -p build/redoc
mkdir -p publish

# Function to update operationId with the prefix, as they may overlap with other specs
update_operation_ids() {
    local file="$1"
    local prefix="$2"
    local folder="$3"

    # Construct the new prefix with the folder name
    local new_prefix="${folder}-${prefix}"

    # Use yq to add the new prefix to the operationId
    yq eval '(.paths[] | .[] | select(has("operationId")) | .operationId) += "-'"$new_prefix"'"' -i "$file"
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

        update_operation_ids "$buildFile" "$prefix"
    done
done

$REDOCLY join build/redoc/*.yaml -o build/redoc/openapi.yaml --prefix-components-with-info-prop x-prefix --prefix-tags-with-info-prop x-prefix

# Set OpenAPI version and title
yq eval '.openapi = "3.1.0"' -i build/redoc/openapi.yaml
yq eval '.info.title = "Ankorstore APIs"' -i build/redoc/openapi.yaml

spec='build/redoc/openapi.yaml'

$REDOCLY build-docs -t redoc/index.hbs -o build/docs/index.html "$spec" --config redoc/redocly.yaml

cp build/docs/index.html publish/index.html
