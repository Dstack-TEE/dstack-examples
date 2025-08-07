#!/bin/bash

# Dstack Examples - Development Helper Script

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="${SCRIPT_DIR}"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Find all docker-compose files
find_compose_files() {
    find "${EXAMPLES_DIR}" -name "docker-compose.y*ml" -not -path "./.github/*" -not -path "./.git/*"
}

# Show help
show_help() {
    cat << EOF
Dstack Examples Development Helper

Usage: $0 <command> [options]

Commands:
    list                List all examples
    validate <example>  Validate a specific example
    validate-all        Validate all examples
    security            Run security checks
    lint                Run linting (shellcheck, yamllint)
    check-all           Run all checks (validate, security, lint)
    build <example>     Build Docker image for an example
    docs                Show documentation status
    help                Show this help message

Examples:
    $0 validate attestation/configid-based
    $0 build custom-domain/dstack-ingress
    $0 check-all

Note: Examples run in dstack cloud environments, not locally.
EOF
}

# List examples
list_examples() {
    log_info "Available examples:"
    find_compose_files | xargs dirname | sort | uniq | sed 's/^/  - /'
}

# Validate structure
validate_structure() {
    local example=$1
    
    if [ ! -d "${example}" ]; then
        log_error "Example directory not found: ${example}"
        return 1
    fi
    
    if [ ! -f "${example}/README.md" ]; then
        log_error "Missing README.md in: ${example}"
        return 1
    fi
    
    if [ ! -f "${example}/docker-compose.yml" ] && [ ! -f "${example}/docker-compose.yaml" ]; then
        log_error "Missing docker-compose file in: ${example}"
        return 1
    fi
    
    log_success "Structure validation passed"
    return 0
}

# Validate compose syntax
validate_compose() {
    local example=$1
    
    log_info "Validating Docker Compose syntax..."
    if cd "${example}" && docker compose config --quiet > /dev/null 2>&1; then
        log_success "Docker Compose syntax is valid"
        return 0
    else
        log_error "Docker Compose syntax is invalid"
        return 1
    fi
}

# Validate single example
validate_example() {
    local example=$1
    
    if [ -z "${example}" ]; then
        log_error "Please specify an example: $0 validate <path/to/example>"
        exit 1
    fi
    
    log_info "Validating example: ${example}"
    
    local failed=0
    validate_structure "${example}" || failed=$((failed + 1))
    validate_compose "${example}" || failed=$((failed + 1))
    
    if [ ${failed} -eq 0 ]; then
        log_success "All validations passed for: ${example}"
        return 0
    else
        log_error "${failed} validation(s) failed for: ${example}"
        return 1
    fi
}

# Validate all examples
validate_all() {
    log_info "Validating all examples..."
    local failed=0
    
    find_compose_files | while read -r compose_file; do
        example_dir=$(dirname "${compose_file}")
        echo ""
        validate_example "${example_dir}" || failed=$((failed + 1))
    done
    
    if [ ${failed} -eq 0 ]; then
        log_success "All examples validated successfully!"
    else
        log_error "${failed} example(s) failed validation"
    fi
}

# Security checks
security_checks() {
    log_info "Running security checks..."
    
    # Check for hardcoded secrets
    log_info "Scanning for potential secrets..."
    if grep -r -i -E "(password|secret|key|token|api_key).*=.*['\"][^'\"]{8,}['\"]" "${EXAMPLES_DIR}" \
        --exclude-dir=.git --exclude-dir=.github --exclude="*.md" --exclude="Makefile" --exclude="dev.sh" 2>/dev/null; then
        log_warning "Potential hardcoded secrets found!"
    else
        log_success "No obvious hardcoded secrets detected"
    fi
    
    # Check Docker Compose security
    log_info "Checking Docker Compose security..."
    find_compose_files | while read -r compose_file; do
        if grep -q "privileged.*true" "${compose_file}"; then
            log_error "Privileged container found in: ${compose_file}"
        fi
        if grep -q "network_mode.*host" "${compose_file}"; then
            log_warning "Host network mode found in: ${compose_file}"
        fi
        if grep -q "/var/run/docker.sock" "${compose_file}"; then
            log_error "Docker socket mount found in: ${compose_file}"
        fi
    done
    
    log_success "Security checks completed"
}

# Lint checks
lint_checks() {
    log_info "Running lint checks..."
    
    # Shellcheck
    if command -v shellcheck >/dev/null 2>&1; then
        log_info "Linting shell scripts..."
        find "${EXAMPLES_DIR}" -name "*.sh" -not -path "./.git/*" -exec shellcheck {} \; || log_warning "ShellCheck issues found"
    else
        log_warning "shellcheck not installed, skipping shell script linting"
    fi
    
    # Yamllint
    if command -v yamllint >/dev/null 2>&1; then
        log_info "Linting YAML files..."
        find "${EXAMPLES_DIR}" -name "*.yml" -o -name "*.yaml" | grep -v ".git" | xargs yamllint || log_warning "YAML linting issues found"
    else
        log_warning "yamllint not installed, skipping YAML linting"
    fi
    
    log_success "Lint checks completed"
}

# Build Docker image
build_image() {
    local example=$1
    
    if [ -z "${example}" ]; then
        log_error "Please specify an example: $0 build <path/to/example>"
        exit 1
    fi
    
    if [ ! -d "${example}" ]; then
        log_error "Example directory not found: ${example}"
        exit 1
    fi
    
    if [ -f "${example}/build-image.sh" ]; then
        log_info "Building Docker image using build script: ${example}"
        cd "${example}" && ./build-image.sh
    elif [ -f "${example}/Dockerfile" ]; then
        log_info "Building Docker image: ${example}"
        cd "${example}" && docker build -t "$(basename "${example}"):latest" .
    else
        log_warning "No Dockerfile or build script found in: ${example}"
    fi
}

# Documentation status
docs_status() {
    log_info "Documentation status:"
    echo ""
    find_compose_files | while read -r compose_file; do
        example_dir=$(dirname "${compose_file}")
        if [ -f "${example_dir}/README.md" ]; then
            echo -e "  ${GREEN}✓${NC} ${example_dir}"
        else
            echo -e "  ${RED}✗${NC} ${example_dir} (missing README.md)"
        fi
    done
}

# Run all checks
check_all() {
    log_info "Running comprehensive checks..."
    echo ""
    
    validate_all
    echo ""
    
    security_checks
    echo ""
    
    lint_checks
    echo ""
    
    log_success "All checks completed!"
}

# Main script logic
main() {
    case "${1:-help}" in
        list)
            list_examples
            ;;
        validate)
            validate_example "${2:-}"
            ;;
        validate-all)
            validate_all
            ;;
        security)
            security_checks
            ;;
        lint)
            lint_checks
            ;;
        check-all)
            check_all
            ;;
        build)
            build_image "${2:-}"
            ;;
        docs)
            docs_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"