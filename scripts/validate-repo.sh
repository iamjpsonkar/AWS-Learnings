#!/usr/bin/env bash
# validate-repo.sh — Repository health checks for Cloud-Learnings
#
# Usage:
#   ./scripts/validate-repo.sh           # run all checks
#   ./scripts/validate-repo.sh --images  # run image checks only
#   ./scripts/validate-repo.sh --brand   # run branding checks only
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
WARN=0

log_info()  { echo "  [INFO]  $*"; }
log_pass()  { echo "  [PASS]  $*"; ((PASS++)); }
log_fail()  { echo "  [FAIL]  $*" >&2; ((FAIL++)); }
log_warn()  { echo "  [WARN]  $*"; ((WARN++)); }

section() { echo ""; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# Check: no broken local image src= references
# ---------------------------------------------------------------------------
check_image_refs() {
    section "Local image src= references"
    local broken=0

    while IFS= read -r file; do
        local dir
        dir="$(dirname "$file")"
        # Extract values from src="..." attributes, stripping code blocks first
        local content
        # Remove fenced code blocks (``` ... ```) to avoid checking example paths
        content="$(awk '/^```/{in_block=!in_block; next} !in_block{print}' "$file" 2>/dev/null)"
        while IFS= read -r src; do
            # Skip external URLs — those are checked separately
            if [[ "$src" == http* ]]; then
                continue
            fi
            # Skip template placeholders (paths containing { or })
            if [[ "$src" == *"{"* || "$src" == *"}"* ]]; then
                continue
            fi
            local resolved="$dir/$src"
            if [[ ! -f "$resolved" ]]; then
                log_fail "BROKEN: $file → src=\"$src\" (resolved: $resolved)"
                broken=1
            fi
        done < <(echo "$content" | grep -o 'src="[^"]*"' 2>/dev/null | sed 's/src="//;s/"//')
    done < <(find "$REPO_ROOT" -name "*.md" -not -path "*/.git/*")

    if [[ "$broken" -eq 0 ]]; then
        log_pass "All local image src= paths resolve to existing files"
    fi
}

# ---------------------------------------------------------------------------
# Check: no external image URLs
# ---------------------------------------------------------------------------
check_external_images() {
    section "External image URLs"
    local found=0

    while IFS= read -r file; do
        while IFS= read -r src; do
            if [[ "$src" == http* ]]; then
                log_fail "EXTERNAL IMAGE: $file → src=\"$src\""
                found=1
            fi
        done < <(grep -o 'src="[^"]*"' "$file" 2>/dev/null | sed 's/src="//;s/"//')
    done < <(find "$REPO_ROOT" -name "*.md" -not -path "*/.git/*")

    if [[ "$found" -eq 0 ]]; then
        log_pass "No external image URLs found in Markdown files"
    fi
}

# ---------------------------------------------------------------------------
# Check: no old AWS-Learnings branding in Markdown
# ---------------------------------------------------------------------------
check_branding() {
    section "Old branding check (aws-learnings)"
    local found=0

    while IFS= read -r file; do
        if grep -qi "aws-learnings\|AWS Learnings" "$file" 2>/dev/null; then
            # Allow it in files that legitimately reference the old name
            local basename
            basename="$(basename "$file")"
            if [[ "$basename" == "CHANGELOG.md" \
               || "$basename" == "validate-repo.sh" \
               || "$basename" == "PULL_REQUEST_TEMPLATE.md" ]]; then
                continue
            fi
            log_fail "OLD BRANDING: $file"
            grep -ni "aws-learnings\|AWS Learnings" "$file" | while IFS= read -r line; do
                log_info "  $line"
            done
            found=1
        fi
    done < <(find "$REPO_ROOT" -name "*.md" -not -path "*/.git/*")

    if [[ "$found" -eq 0 ]]; then
        log_pass "No old 'aws-learnings' branding found"
    fi
}

# ---------------------------------------------------------------------------
# Check: every non-asset, non-.github directory has a README.md
# ---------------------------------------------------------------------------
check_readmes() {
    section "README.md presence in directories"
    local missing=0

    while IFS= read -r dir; do
        if [[ ! -f "$dir/README.md" ]]; then
            log_fail "MISSING README: $dir"
            missing=1
        fi
    done < <(find "$REPO_ROOT" \
        -mindepth 1 -maxdepth 4 -type d \
        -not -path "*/.git*" \
        -not -path "*/.github*" \
        -not -path "*/.claude*" \
        -not -path "*/assets/images*" \
        -not -path "*/assets/diagrams*" \
        -not -path "*/assets/prompts*" \
        -not -path "*/node_modules*" \
        -not -path "*/__pycache__*")

    if [[ "$missing" -eq 0 ]]; then
        log_pass "All checked directories contain README.md"
    fi
}

# ---------------------------------------------------------------------------
# Check: every <img> tag has a non-empty alt attribute
# ---------------------------------------------------------------------------
check_alt_attributes() {
    section "<img> alt attribute coverage"
    local found=0

    while IFS= read -r file; do
        # Match <img> tags missing alt entirely, or with empty alt=""
        if grep -qE '<img [^>]*(alt=""|(?!.*alt=)[^>]*)>' "$file" 2>/dev/null; then
            log_warn "MISSING/EMPTY ALT: $file"
            grep -nE '<img [^>]*(alt=""|(?!.*alt=)[^>]*)>' "$file" | while IFS= read -r line; do
                log_info "  $line"
            done
            found=1
        fi
    done < <(find "$REPO_ROOT" -name "*.md" -not -path "*/.git/*")

    if [[ "$found" -eq 0 ]]; then
        log_pass "All <img> tags have non-empty alt attributes"
    else
        log_warn "Some <img> tags have missing or empty alt attributes (warnings, not failures)"
    fi
}

# ---------------------------------------------------------------------------
# Check: no untagged TODO stubs
# ---------------------------------------------------------------------------
check_todos() {
    section "TODO stubs"
    local found=0

    while IFS= read -r file; do
        # Flag TODOs that are NOT prefixed with "# TODO:" (i.e., bare TODOs in prose)
        if grep -qiE '^\s*TODO[^:]|TODO\s*$|\bTODO\b[^:]' "$file" 2>/dev/null; then
            local basename
            basename="$(basename "$file")"
            # Allow in templates (they use {placeholder} syntax, not TODO)
            if [[ "$(dirname "$file")" == */templates ]]; then
                continue
            fi
            log_warn "UNTAGGED TODO: $file"
            grep -niE '^\s*TODO[^:]|TODO\s*$|\bTODO\b[^:]' "$file" | while IFS= read -r line; do
                log_info "  $line"
            done
            found=1
        fi
    done < <(find "$REPO_ROOT" -name "*.md" -not -path "*/.git/*")

    if [[ "$found" -eq 0 ]]; then
        log_pass "No untagged TODO stubs found"
    else
        log_warn "Untagged TODOs found — use '# TODO:' prefix for intentional stubs"
    fi
}

# ---------------------------------------------------------------------------
# Check: image file sizes (warn if > 500KB)
# ---------------------------------------------------------------------------
check_image_sizes() {
    section "Image file sizes (limit: 500KB)"
    local oversized=0
    local limit_bytes=512000  # 500KB

    while IFS= read -r img; do
        local size
        size="$(wc -c <"$img" 2>/dev/null || echo 0)"
        if [[ "$size" -gt "$limit_bytes" ]]; then
            local size_kb=$(( size / 1024 ))
            log_warn "OVERSIZED (${size_kb}KB): $img"
            oversized=1
        fi
    done < <(find "$REPO_ROOT/assets/images" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) 2>/dev/null)

    if [[ "$oversized" -eq 0 ]]; then
        log_pass "All images are within the 500KB limit"
    else
        log_warn "Some images exceed 500KB — run ./scripts/optimize-images.sh"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "================================================"
    echo " Validation summary"
    echo "================================================"
    echo "  Passed:   $PASS"
    echo "  Warnings: $WARN"
    echo "  Failed:   $FAIL"
    echo "================================================"
    if [[ "$FAIL" -gt 0 ]]; then
        echo "  STATUS: FAILED — fix the errors above before committing."
        echo "================================================"
        exit 1
    else
        echo "  STATUS: PASSED"
        echo "================================================"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    echo "Cloud-Learnings repository validation"
    echo "Repo root: $REPO_ROOT"

    local run_all=true
    local -a checks=()

    for arg in "$@"; do
        case "$arg" in
            --images)  run_all=false; checks+=(check_image_refs check_external_images check_image_sizes) ;;
            --brand)   run_all=false; checks+=(check_branding) ;;
            --readmes) run_all=false; checks+=(check_readmes) ;;
            --alt)     run_all=false; checks+=(check_alt_attributes) ;;
            --todos)   run_all=false; checks+=(check_todos) ;;
            --help|-h)
                echo "Usage: $0 [--images] [--brand] [--readmes] [--alt] [--todos]"
                echo "       Omit flags to run all checks."
                exit 0
                ;;
            *)
                echo "Unknown flag: $arg. Use --help for usage." >&2
                exit 1
                ;;
        esac
    done

    if [[ "$run_all" == true ]]; then
        checks=(
            check_image_refs
            check_external_images
            check_branding
            check_readmes
            check_alt_attributes
            check_todos
            check_image_sizes
        )
    fi

    for check in "${checks[@]}"; do
        "$check"
    done

    print_summary
}

main "$@"
