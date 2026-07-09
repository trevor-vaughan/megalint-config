# Custom MegaLinter Flavor Generation

This document covers the automated generation of custom MegaLinter flavors from shared configuration files. The custom flavor system allows you to package your MegaLinter configuration into a distributable Docker image.

## Overview

The custom flavor generation system converts your `.mega-linter.yml` configuration into a complete custom flavor package that includes:

- **Dockerfile** - Container image definition with pre-configured linters
- **Flavor configuration** - `mega-linter-flavor.yml` with the flavor name, the upstream MegaLinter version it was built against, and the linter list
- **Validation** - Automated testing and verification tools

This eliminates the need to manage configuration files across multiple repositories and provides a consistent, versioned linting experience.

## Quick Start

### Basic Usage

Generate a custom flavor from your configuration:

```bash
task flavor:generate
```

This creates a `./custom-flavor/` directory with all necessary files using default settings:
- Configuration file: `.mega-linter.yml`
- Flavor name: `shared-config`
- Base image: the upstream MegaLinter image at the pinned `MEGALINTER_VERSION` (default `9.6.0`), which the generator clones and extends

### Custom Configuration

Generate with specific parameters:

```bash
task flavor:generate \
  CONFIG_FILE=my-config.yml \
  OUTPUT_DIR=./my-flavor \
  FLAVOR_NAME=my-custom-flavor
```

To build against a different upstream MegaLinter version, set
`MEGALINTER_VERSION` (it re-clones the pinned source the flavor extends):

```bash
task flavor:generate MEGALINTER_VERSION=9.6.0
```

### Validation and Testing

Validate the generated flavor:

```bash
task flavor:validate
```

Run integration tests:

```bash
task flavor:test
```

### Docker Operations

Build the custom flavor Docker image:

```bash
task flavor:build
```

Test the Docker image:

```bash
task flavor:test
```

## Task Reference

### Core Tasks

| Task              | Description                               | Dependencies    |
|-------------------|-------------------------------------------|-----------------|
| `flavor:generate` | Generate custom flavor from configuration | flavor:clone    |
| `flavor:validate` | Validate generated flavor structure       | flavor:generate |
| `flavor:unit`     | Run unit tests for flavor generation      | None            |
| `flavor:build`    | Build Docker image                        | flavor:generate |
| `flavor:test`     | Test Docker image                         | flavor:build    |
| `flavor:clean`    | Clean up generated files                  | None            |

### Task Variables

#### `flavor:generate`

| Variable             | Default            | Description                                                 |
|----------------------|--------------------|-------------------------------------------------------------|
| `CONFIG_FILE`        | `.mega-linter.yml` | MegaLinter configuration file path                          |
| `OUTPUT_DIR`         | `./custom-flavor`  | Output directory for generated files                        |
| `FLAVOR_NAME`        | `shared-config`    | Name of the custom flavor                                   |
| `MEGALINTER_VERSION` | `9.6.0`            | Upstream MegaLinter version to clone and extend as the base |

#### `flavor:validate`

| Variable     | Default           | Description                       |
|--------------|-------------------|-----------------------------------|
| `FLAVOR_DIR` | `./custom-flavor` | Directory containing flavor files |

#### `flavor:build`

| Variable           | Default                                  | Description                              |
|--------------------|------------------------------------------|------------------------------------------|
| `FLAVOR_DIR`       | `./custom-flavor`                        | Directory containing flavor files        |
| `MEGALINTER_IMAGE` | `megalinter-local:v<MEGALINTER_VERSION>` | Full image reference (name:tag) to build |

## Configuration

### Source Configuration File

The system parses your `.mega-linter.yml` configuration file to extract:

- **Enabled linters** - From `ENABLE_LINTERS` list
- **Linter arguments** - Tool-specific configurations
- **File filters** - Include/exclude patterns
- **Custom variables** - Environment and flavor settings

### Required Configuration Elements

Your `.mega-linter.yml` must include:

```yaml
# Essential: Define which linters to include
ENABLE_LINTERS:
  - YAML_YAMLLINT
  - MARKDOWN_MARKDOWNLINT
  - BASH_SHELLCHECK
  # Add your required linters
```

### Supported Linter Categories

The generator supports all MegaLinter linter categories:

- **Language linters** - Python, JavaScript, Go, Java, etc.
- **Format linters** - YAML, JSON, XML, Markdown
- **Infrastructure** - Dockerfile, Kubernetes, Terraform
- **Security** - Secret detection, vulnerability scanning
- **Quality** - Code complexity, documentation

## Generated Structure

A complete custom flavor contains:

```
custom-flavor/
├── Dockerfile                 # Container image definition
└── mega-linter-flavor.yml     # Flavor config (name, megalinter_version, linter list)
```

### Dockerfile

The generated Dockerfile:
- Extends the upstream MegaLinter base image at the pinned version
- Installs only the required linters (reducing image size)
- Copies linter configurations
- Sets appropriate labels and metadata

## Docker Usage

### Local Development

Build and use your custom flavor locally:

```bash
# Generate and build
task flavor:generate
task flavor:build

# Run against current directory
docker run --rm \
  -v "$(pwd)":/workspace:Z \
  megalinter-local:latest
```

### Custom Image Names

Use a specific image reference:

```bash
task flavor:build \
  MEGALINTER_IMAGE=myorg/mylinter:v1.0.0
```

### Registry Publishing

After building, publish to your registry:

```bash
docker tag megalinter-local:latest myorg/mylinter:v1.0.0
docker push myorg/mylinter:v1.0.0
```

## GitHub Actions Integration

### Using the Generated Dockerfile

Build and push your custom flavor image in CI, then reference it in lint workflows:

```yaml
name: Lint
on: [push, pull_request]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run custom MegaLinter flavor
        run: |
          docker run --rm \
            -v "$(pwd)":/workspace:Z \
            ghcr.io/myorg/megalinter:v9
```

### Publishing Your Image

To share your custom flavor:

1. **Build the image** using `task flavor:build`
2. **Tag for your registry** (e.g., `ghcr.io/myorg/megalinter:v9`)
3. **Push to the registry** using `docker push`
4. **Reference in workflows** using the published image tag

## Examples

### Minimal Shared Configuration

`.mega-linter.yml`:
```yaml
ENABLE_LINTERS:
  - YAML_YAMLLINT
  - MARKDOWN_MARKDOWNLINT
```

Generate:
```bash
task flavor:generate \
  FLAVOR_NAME=docs-linter
```

### Comprehensive Development Environment

`.mega-linter.yml`:
```yaml
ENABLE_LINTERS:
  - PYTHON_PYLINT
  - PYTHON_BLACK
  - JAVASCRIPT_ES
  - TYPESCRIPT_ES
  - YAML_YAMLLINT
  - MARKDOWN_MARKDOWNLINT
  - DOCKERFILE_HADOLINT
  - BASH_SHELLCHECK

PYTHON_PYLINT_ARGUMENTS: "--max-line-length=88"
JAVASCRIPT_ES_ARGUMENTS: "--max-warnings 0"
```

Generate and test:
```bash
task flavor:generate \
  FLAVOR_NAME=fullstack-linter \
  OUTPUT_DIR=./linters/fullstack

task flavor:validate \
  FLAVOR_DIR=./linters/fullstack

task flavor:build \
  FLAVOR_DIR=./linters/fullstack \
  MEGALINTER_IMAGE=myorg/fullstack-linter:v2.0.0
```

### Organization-Wide Standard

For enterprise deployment:

```bash
# Generate with a pinned upstream version
task flavor:generate \
  CONFIG_FILE=.mega-linter-enterprise.yml \
  FLAVOR_NAME=enterprise-standard \
  OUTPUT_DIR=./dist/enterprise-linter \
  MEGALINTER_VERSION=9.6.0

# Validate
task flavor:validate \
  FLAVOR_DIR=./dist/enterprise-linter

# Build for registry
task flavor:build \
  FLAVOR_DIR=./dist/enterprise-linter \
  MEGALINTER_IMAGE=enterprise.registry.com/megalinter:2024.1.0
```

## Troubleshooting

### Common Issues

#### Generation Failures

**Error: "Configuration file not found"**
```bash
# Verify file exists and path is correct
ls -la .mega-linter.yml
task flavor:generate CONFIG_FILE=path/to/config.yml
```

**Error: "Invalid output directory"**
```bash
# Ensure parent directory exists
mkdir -p ./custom-flavors
task flavor:generate OUTPUT_DIR=./custom-flavors/my-flavor
```

**Error: "Unknown linter in ENABLE_LINTERS"**
- Check linter name spelling against MegaLinter documentation
- Verify the linter exists in the pinned MegaLinter version
- Change the pinned version to one that includes it: `task flavor:generate MEGALINTER_VERSION=<version>`

#### Validation Failures

**Error: "Dockerfile missing required files"**
```bash
# Regenerate with verbose output
task flavor:generate
# Check generated structure
ls -la ./custom-flavor/
```

**Error: "Docker build failed"**
```bash
# Test build manually for detailed errors
cd ./custom-flavor
docker build -t test-flavor .
```

#### Docker Issues

**Error: "Container engine not found"**
```bash
# Check container engine availability
podman --version || docker --version
```

**Error: "Permission denied on Docker socket"**
```bash
# Add user to docker group
sudo usermod -aG docker $USER
# Or use rootless containers
systemctl --user start podman.socket
```

**Error: "failed to authorize ... 400/429" from `auth.docker.io` during build**

The generated Dockerfile pulls several linter builder stages from Docker
Hub. On shared CI runner IPs, Docker Hub throttles anonymous pulls and the
build fails resolving an image (commonly `mvdan/shfmt`). Mitigations applied
in this repo's workflows:

- Stages whose images are published to GHCR (`hadolint`, `gitleaks`) are
  rewritten to `ghcr.io` automatically by `_qualify_from_image`.
- The remaining Docker Hub stages (`shfmt`, `shellcheck`, and the
  official `rust`/`alpine` images) are pulled authenticated when the
  optional `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repository secrets are
  set. The login step is skipped when they are absent (e.g. fork PRs), so
  builds still run — just against the throttled anonymous quota.

### Debug Mode

Run validation with manual inspection:

```bash
task flavor:validate FLAVOR_DIR=./custom-flavor
# Then check generated files directly
ls -la ./custom-flavor/
cat ./custom-flavor/mega-linter-flavor.yml
```

### Integration Test Failures

Run tests with detailed output:

```bash
task flavor:unit
task flavor:validate
```

### Performance Issues

**Large image builds**
- Use newer base images with pre-installed tools
- Consider multi-stage builds for production
- Limit `ENABLE_LINTERS` to essential tools only

**Slow generation**
- Check disk space: `df -h`
- Verify template directory permissions
- Use SSD storage for temp directories

### Recovery Commands

Clean up and restart:

```bash
# Remove all generated artifacts
task flavor:clean REMOVE_IMAGE=true

# Clear Docker build cache
docker system prune -f

# Regenerate from scratch
task flavor:generate
task flavor:validate
```

## Advanced Configuration

### Multi-Environment Flavors

Generate different flavors for different environments:

```bash
# Development flavor
task flavor:generate \
  CONFIG_FILE=.mega-linter-dev.yml \
  FLAVOR_NAME=dev-linter \
  OUTPUT_DIR=./flavors/dev

# Production flavor  
task flavor:generate \
  CONFIG_FILE=.mega-linter-prod.yml \
  FLAVOR_NAME=prod-linter \
  OUTPUT_DIR=./flavors/prod
```

### Automated CI/CD Integration

Include in your deployment pipeline:

```yaml
# .github/workflows/build-flavor.yml
name: Build Custom Flavor
on:
  push:
    paths: ['.mega-linter*.yml']

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate custom flavor
        run: task flavor:generate
      - name: Validate flavor
        run: task flavor:validate
      - name: Build and push
        run: |
          task flavor:build \
            MEGALINTER_IMAGE=ghcr.io/${{ github.repository }}/megalinter:${{ github.sha }}
          docker push ghcr.io/${{ github.repository }}/megalinter:${{ github.sha }}
```

## Best Practices

1. **Version your configurations** - Tag configuration changes
2. **Test thoroughly** - Run `task flavor:validate` and `task flavor:build`
3. **Document customizations** - Update flavor descriptions
4. **Pin the base version** - Set `MEGALINTER_VERSION` to an exact upstream version
5. **Automate updates** - Use CI/CD for flavor regeneration
6. **Share responsibly** - Review security implications before publishing

## Support

- **Issues**: Report problems to the repository issue tracker
- **Documentation**: Refer to MegaLinter official documentation for linter-specific configuration
- **Examples**: See the [Examples](#examples) section above for working configurations

---

*Generated by MegaLinter Custom Flavor Generation System*