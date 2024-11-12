## Ankorstore API Documentation
This contains the centralised documentation for public APIs exposed by Ankorstore applications

## Adding an API

### Requirements
* Your API spec must use version 3.1.0 of the OpenAPI Specification (OAS) to be included in this documentation.
* Your API spec must be in YAML format to be included in this documentation.
* Your API spec must have a x-prefix property with the name of your application
* Your API spec must be self-contained, without references
* You may publish multiple spec files per application, but each must individually follow the rules above

### Preparing specification files
If your API spec is composed of multiple files with $refs, please bundle them into a single file before submitting.
```bash
npx -y swagger-cli bundle -r -t yaml --outfile output.yaml input.yaml
```

### Publishing your API
To publish your API spec, include the following GitHub Actions workflow:
```yaml
  - name: Format target folder number
    id: format_run_number
    run: printf 'formatted=%05d\n' "${{ github.run_number }}" >> "$GITHUB_OUTPUT"
  - name: Publish 🚀
    uses: JamesIves/github-pages-deploy-action@v4
    with:
      repository-name: ankorstore/api-docs
      branch: main
      folder: build
      token: ${{ secrets.PAT }}
      target-folder: pull/<your-app-name-here>/${{ steps.format_run_number.outputs.formatted }}
      force: false
```

The API documentation will be updated & published automatically upon this action
