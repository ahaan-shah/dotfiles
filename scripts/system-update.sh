#!/usr/bin/env bash
# system-update.sh — one script to update repo (core/extra/multilib), AUR
# (via yay) and Flatpak, prompting for the sudo password exactly once.
#
# Shows a single numbered list, grouped core -> extra -> multilib -> other
# -> aur -> flatpak, and lets you type numbers to exclude packages before
# anything runs — no further y/n prompts after that.

if [[ -t 1 ]]; then
    BOLD=$(tput bold); RESET=$(tput sgr0)
    CYAN=$(tput setaf 6); GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3); RED=$(tput setaf 1)
else
    BOLD=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
fi

die() { printf '%s%s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

command -v pacman >/dev/null || die "pacman not found"
command -v yay >/dev/null || die "yay not found"
HAVE_FLATPAK=false
command -v flatpak >/dev/null && HAVE_FLATPAK=true

# One password prompt up front, then keep the ticket alive for the rest of
# the script so the pacman/yay calls further down never prompt again.
sudo -v || die "sudo authentication failed"
(
    while kill -0 "$$" 2>/dev/null; do
        sudo -n true
        sleep 60
    done
) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

printf '%s==>%s Syncing package databases...\n' "$CYAN" "$RESET"
sudo pacman -Sy --quiet || die "pacman -Sy failed"

# repo -> package name membership, used to sort pacman -Qu output into
# core/extra/multilib/other buckets.
declare -A repo_of
for repo in core extra multilib; do
    while read -r r p _; do
        repo_of["$p"]="$r"
    done < <(pacman -Sl "$repo" 2>/dev/null)
done

mapfile -t QU_LINES < <(pacman -Qu 2>/dev/null || true)
mapfile -t AUR_LINES < <(yay -Qua --color=never 2>/dev/null || true)

FLAT_IDS=()
FLAT_NAMES=()
if $HAVE_FLATPAK; then
    while IFS=$'\t' read -r app name; do
        [[ "$app" == *.* ]] || continue
        FLAT_IDS+=("$app")
        FLAT_NAMES+=("$name")
    done < <(flatpak list --updates --columns=application,name 2>/dev/null || true)
fi

declare -A CORE_L EXTRA_L MULTILIB_L OTHER_L
for line in "${QU_LINES[@]}"; do
    name="${line%% *}"
    case "${repo_of[$name]:-other}" in
        core) CORE_L["$name"]="$line" ;;
        extra) EXTRA_L["$name"]="$line" ;;
        multilib) MULTILIB_L["$name"]="$line" ;;
        *) OTHER_L["$name"]="$line" ;;
    esac
done

TOTAL=$(( ${#QU_LINES[@]} + ${#AUR_LINES[@]} + ${#FLAT_IDS[@]} ))
if (( TOTAL == 0 )); then
    printf '%s==>%s System is already up to date.\n' "$GREEN" "$RESET"
    exit 0
fi

# "name oldver -> newver" (AUR lines also have a trailing " [1h2m]" build
# estimate) -> sets P_NAME/P_OLD/P_NEW, used to lay these out as columns.
parse_line() {
    local line="$1" rest after
    P_NAME="${line%% *}"
    rest="${line#* }"
    P_OLD="${rest%% -> *}"
    after="${rest#* -> }"
    P_NEW="${after%% *}"
}

NAME_W=7   # min width to fit the "PACKAGE" header
OLD_W=3    # min width to fit the "OLD" header
for line in "${QU_LINES[@]}" "${AUR_LINES[@]}"; do
    parse_line "$line"
    (( ${#P_NAME} > NAME_W )) && NAME_W=${#P_NAME}
    (( ${#P_OLD} > OLD_W )) && OLD_W=${#P_OLD}
done

declare -A IDX_NAME IDX_SOURCE
idx=0

print_section() {
    local title="$1" count="$2"
    (( count > 0 )) || return
    printf '\n%s%s%s (%d)%s\n' "$BOLD" "$CYAN" "$title" "$count" "$RESET"
    printf '       %s%-*s  %*s      %s%s\n' "$BOLD" "$NAME_W" "PACKAGE" "$OLD_W" "OLD" "NEW" "$RESET"
}

list_bucket() {
    local -n bucket="$1"
    local source="$2"
    for name in "${!bucket[@]}"; do
        idx=$((idx + 1))
        IDX_NAME[$idx]="$name"
        IDX_SOURCE[$idx]="$source"
        parse_line "${bucket[$name]}"
        printf '  %s%3d)%s %-*s  %*s  ->  %s\n' "$YELLOW" "$idx" "$RESET" "$NAME_W" "$P_NAME" "$OLD_W" "$P_OLD" "$P_NEW"
    done
}

print_section "Core" "${#CORE_L[@]}"
list_bucket CORE_L repo
print_section "Extra" "${#EXTRA_L[@]}"
list_bucket EXTRA_L repo
print_section "Multilib" "${#MULTILIB_L[@]}"
list_bucket MULTILIB_L repo
print_section "Other repos" "${#OTHER_L[@]}"
list_bucket OTHER_L repo

print_section "AUR" "${#AUR_LINES[@]}"
for line in "${AUR_LINES[@]}"; do
    parse_line "$line"
    idx=$((idx + 1))
    IDX_NAME[$idx]="$P_NAME"
    IDX_SOURCE[$idx]="aur"
    printf '  %s%3d)%s %-*s  %*s  ->  %s\n' "$YELLOW" "$idx" "$RESET" "$NAME_W" "$P_NAME" "$OLD_W" "$P_OLD" "$P_NEW"
done

if (( ${#FLAT_IDS[@]} > 0 )); then
    printf '\n%s%sFlatpak%s (%d)\n' "$BOLD" "$CYAN" "$RESET" "${#FLAT_IDS[@]}"
    for i in "${!FLAT_IDS[@]}"; do
        idx=$((idx + 1))
        IDX_NAME[$idx]="${FLAT_IDS[$i]}"
        IDX_SOURCE[$idx]="flatpak"
        printf '  %s%3d)%s %-*s  %s\n' "$YELLOW" "$idx" "$RESET" "$NAME_W" "${FLAT_NAMES[$i]}" "${FLAT_IDS[$i]}"
    done
fi

printf '\n%sTotal: %d package(s) to update.%s\n' "$BOLD" "$TOTAL" "$RESET"
printf 'Type the numbers of any packages to %sexclude%s (space separated), or press Enter to update everything:\n> ' "$RED" "$RESET"
read -r exclude_input

declare -A EXCLUDED
for n in $exclude_input; do
    [[ -n "${IDX_NAME[$n]:-}" ]] && EXCLUDED[$n]=1
done

repo_exclude=()
aur_exclude=()
flat_exclude=()
for i in "${!IDX_NAME[@]}"; do
    [[ -n "${EXCLUDED[$i]:-}" ]] || continue
    case "${IDX_SOURCE[$i]}" in
        repo) repo_exclude+=("${IDX_NAME[$i]}") ;;
        aur) aur_exclude+=("${IDX_NAME[$i]}") ;;
        flatpak) flat_exclude+=("${IDX_NAME[$i]}") ;;
    esac
done

skipped=${#EXCLUDED[@]}
printf '\n%s==>%s Updating %d package(s)' "$CYAN" "$RESET" $(( TOTAL - skipped ))
(( skipped > 0 )) && printf ', skipping %d' "$skipped"
printf '.\n'

repo_total=$(( ${#CORE_L[@]} + ${#EXTRA_L[@]} + ${#MULTILIB_L[@]} + ${#OTHER_L[@]} ))
if (( repo_total > 0 )); then
    printf '\n%s==>%s Repo packages...\n' "$CYAN" "$RESET"
    if (( ${#repo_exclude[@]} > 0 )); then
        ignore=$(IFS=,; echo "${repo_exclude[*]}")
        sudo pacman -Su --ignore="$ignore" --noconfirm
    else
        sudo pacman -Su --noconfirm
    fi
fi

if (( ${#AUR_LINES[@]} > 0 )); then
    printf '\n%s==>%s AUR packages...\n' "$CYAN" "$RESET"
    if (( ${#aur_exclude[@]} > 0 )); then
        ignore=$(IFS=,; echo "${aur_exclude[*]}")
        yay -Sua --ignore="$ignore" --noconfirm
    else
        yay -Sua --noconfirm
    fi
fi

if $HAVE_FLATPAK && (( ${#FLAT_IDS[@]} > 0 )); then
    printf '\n%s==>%s Flatpak packages...\n' "$CYAN" "$RESET"
    if (( ${#flat_exclude[@]} > 0 )); then
        update_ids=()
        for id in "${FLAT_IDS[@]}"; do
            skip=false
            for ex in "${flat_exclude[@]}"; do
                [[ "$id" == "$ex" ]] && skip=true && break
            done
            $skip || update_ids+=("$id")
        done
        (( ${#update_ids[@]} > 0 )) && flatpak update -y "${update_ids[@]}"
    else
        flatpak update -y
    fi
fi

printf '\n%s==>%s Done.\n' "$GREEN" "$RESET"
