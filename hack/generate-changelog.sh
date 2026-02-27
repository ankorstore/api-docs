#!/usr/bin/env bash
set -e

# Generate a changelog by comparing the two most recent spec versions for each app.
# Outputs markdown to stdout: auto-detected changes first, then manual changelog history.

manual_changelog=""
auto_sections=""
has_changes=false

for projectFolder in pull/*/; do
    folderName=$(basename "$projectFolder")

    # Skip numeric-only legacy folders
    if [[ "$folderName" =~ ^[0-9]+$ ]]; then
        continue
    fi

    # Get the two most recent version subfolders
    versions=($(ls -d "$projectFolder"*/ 2>/dev/null | sort | tail -n 2))

    if [[ ${#versions[@]} -lt 2 ]]; then
        echo "Skipping $folderName: fewer than 2 versions available" >&2
        continue
    fi

    old_dir="${versions[0]}"
    new_dir="${versions[1]}"

    section=""

    # Compare each matching YAML file pair
    for new_file in "$new_dir"*.yaml; do
        [ -f "$new_file" ] || continue
        base=$(basename "$new_file")
        old_file="${old_dir}${base}"
        [ -f "$old_file" ] || continue

        # Extract manual changelog from source spec (Ankorstore only, first match)
        if [[ -z "$manual_changelog" ]]; then
            manual_desc=$(yq eval '.tags[] | select(.name == "Changelog") | .description' "$new_file" 2>/dev/null)
            if [[ -n "$manual_desc" && "$manual_desc" != "null" ]]; then
                manual_changelog="$manual_desc"
            fi
        fi

        # Compare paths
        old_paths=$(yq eval '.paths | keys | .[]' "$old_file" 2>/dev/null | sort)
        new_paths=$(yq eval '.paths | keys | .[]' "$new_file" 2>/dev/null | sort)

        added_paths=$(comm -13 <(echo "$old_paths") <(echo "$new_paths"))
        removed_paths=$(comm -23 <(echo "$old_paths") <(echo "$new_paths"))

        # Compare operations (path + method combos)
        old_ops=$(yq eval '.paths | to_entries[] | .key as $p | .value | keys | .[] | $p + " " + .' "$old_file" 2>/dev/null | sort)
        new_ops=$(yq eval '.paths | to_entries[] | .key as $p | .value | keys | .[] | $p + " " + .' "$new_file" 2>/dev/null | sort)

        # Filter to HTTP methods only
        old_ops=$(echo "$old_ops" | grep -E ' (get|post|put|patch|delete|head|options|trace)$' || true)
        new_ops=$(echo "$new_ops" | grep -E ' (get|post|put|patch|delete|head|options|trace)$' || true)

        added_ops=$(comm -13 <(echo "$old_ops") <(echo "$new_ops"))
        removed_ops=$(comm -23 <(echo "$old_ops") <(echo "$new_ops"))

        # Exclude operations on entirely new/removed paths (already reported as path changes)
        if [[ -n "$added_paths" ]]; then
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                added_ops=$(echo "$added_ops" | grep -v "^${p} " || true)
            done <<< "$added_paths"
        fi
        if [[ -n "$removed_paths" ]]; then
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                removed_ops=$(echo "$removed_ops" | grep -v "^${p} " || true)
            done <<< "$removed_paths"
        fi

        # Compare component schemas
        old_schemas=$(yq eval '.components.schemas | keys | .[]' "$old_file" 2>/dev/null | sort)
        new_schemas=$(yq eval '.components.schemas | keys | .[]' "$new_file" 2>/dev/null | sort)

        added_schemas=$(comm -13 <(echo "$old_schemas") <(echo "$new_schemas"))
        removed_schemas=$(comm -23 <(echo "$old_schemas") <(echo "$new_schemas"))

        # Build section content
        if [[ -n "$added_paths" && "$added_paths" =~ [^[:space:]] ]]; then
            section+=$'\n**New endpoints**\n\n'
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                # Find methods for this new path
                methods=$(yq eval ".paths[\"$p\"] | keys | .[]" "$new_file" 2>/dev/null | grep -E '^(get|post|put|patch|delete|head|options|trace)$' || true)
                if [[ -n "$methods" ]]; then
                    while IFS= read -r m; do
                        summary=$(yq eval ".paths[\"$p\"][\"$m\"].summary // \"\"" "$new_file" 2>/dev/null)
                        method_upper=$(echo "$m" | tr '[:lower:]' '[:upper:]')
                        if [[ -n "$summary" && "$summary" != "null" ]]; then
                            section+="- \`${method_upper} ${p}\` — ${summary}"$'\n'
                        else
                            section+="- \`${method_upper} ${p}\`"$'\n'
                        fi
                    done <<< "$methods"
                else
                    section+="- \`${p}\`"$'\n'
                fi
            done <<< "$added_paths"
        fi

        if [[ -n "$removed_paths" && "$removed_paths" =~ [^[:space:]] ]]; then
            section+=$'\n**Removed endpoints**\n\n'
            while IFS= read -r p; do
                [ -z "$p" ] && continue
                section+="- \`${p}\`"$'\n'
            done <<< "$removed_paths"
        fi

        if [[ -n "$added_ops" && "$added_ops" =~ [^[:space:]] ]]; then
            section+=$'\n**New operations**\n\n'
            while IFS= read -r op; do
                [ -z "$op" ] && continue
                path=$(echo "$op" | awk '{print $1}')
                method=$(echo "$op" | awk '{print $2}')
                method_upper=$(echo "$method" | tr '[:lower:]' '[:upper:]')
                summary=$(yq eval ".paths[\"$path\"][\"$method\"].summary // \"\"" "$new_file" 2>/dev/null)
                if [[ -n "$summary" && "$summary" != "null" ]]; then
                    section+="- \`${method_upper} ${path}\` — ${summary}"$'\n'
                else
                    section+="- \`${method_upper} ${path}\`"$'\n'
                fi
            done <<< "$added_ops"
        fi

        if [[ -n "$removed_ops" && "$removed_ops" =~ [^[:space:]] ]]; then
            section+=$'\n**Removed operations**\n\n'
            while IFS= read -r op; do
                [ -z "$op" ] && continue
                path=$(echo "$op" | awk '{print $1}')
                method=$(echo "$op" | awk '{print $2}')
                method_upper=$(echo "$method" | tr '[:lower:]' '[:upper:]')
                section+="- \`${method_upper} ${path}\`"$'\n'
            done <<< "$removed_ops"
        fi

        if [[ -n "$added_schemas" && "$added_schemas" =~ [^[:space:]] ]]; then
            section+=$'\n**New schemas**\n\n'
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                section+="- \`${s}\`"$'\n'
            done <<< "$added_schemas"
        fi

        if [[ -n "$removed_schemas" && "$removed_schemas" =~ [^[:space:]] ]]; then
            section+=$'\n**Removed schemas**\n\n'
            while IFS= read -r s; do
                [ -z "$s" ] && continue
                section+="- \`${s}\`"$'\n'
            done <<< "$removed_schemas"
        fi
    done

    # Format the app section
    # Capitalize first letter
    display_name="$(echo "${folderName:0:1}" | tr '[:lower:]' '[:upper:]')${folderName:1}"
    if [[ -n "$section" && "$section" =~ [^[:space:]] ]]; then
        auto_sections+=$'\n#### '"$display_name"$'\n'"$section"
        has_changes=true
    else
        auto_sections+=$'\n#### '"$display_name"$'\n\n_No changes detected_\n'
    fi
done

# Build final output
output="ℹ️ This page tracks notable changes to the Ankorstore APIs, including new features,
improvements, deprecations, and breaking changes."

if [[ "$has_changes" == true ]]; then
    output+=$'\n\n### Latest API Changes (auto-detected)\n'
    output+="$auto_sections"
fi

if [[ -n "$manual_changelog" ]]; then
    # Strip the intro text before the first ## heading to avoid duplicating the auto-generated intro,
    # then downgrade all ## headings to ### (and ### to ####) so ReDoc doesn't split them into sub-sections
    manual_history=$(echo "$manual_changelog" | sed -n '/^## /,$p' | sed 's/^### /#### /; s/^## /### /')
    if [[ -n "$manual_history" ]]; then
        output+=$'\n\n---\n\n'
        output+="$manual_history"
    fi
fi

echo "$output"
