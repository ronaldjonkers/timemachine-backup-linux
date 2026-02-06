#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Encryption Library
# ============================================================
# GPG-based encryption for backup archives.
#
# Supports two modes:
#   1. Symmetric (passphrase from TM_ENCRYPT_PASSPHRASE)
#   2. Asymmetric (GPG key ID from TM_ENCRYPT_KEY_ID)
#
# Configure via .env:
#   TM_ENCRYPT_ENABLED=true
#   TM_ENCRYPT_MODE="symmetric"   # or "asymmetric"
#   TM_ENCRYPT_PASSPHRASE="..."   # for symmetric mode
#   TM_ENCRYPT_KEY_ID="..."       # for asymmetric mode
# ============================================================

# Check if encryption is available and configured
tm_encrypt_available() {
    if [[ "${TM_ENCRYPT_ENABLED:-false}" != "true" ]]; then
        return 1
    fi

    if ! command -v gpg &>/dev/null; then
        tm_log "ERROR" "GPG not installed but encryption is enabled"
        return 1
    fi

    local mode="${TM_ENCRYPT_MODE:-symmetric}"
    case "${mode}" in
        symmetric)
            if [[ -z "${TM_ENCRYPT_PASSPHRASE:-}" ]]; then
                tm_log "ERROR" "TM_ENCRYPT_PASSPHRASE required for symmetric encryption"
                return 1
            fi
            ;;
        asymmetric)
            if [[ -z "${TM_ENCRYPT_KEY_ID:-}" ]]; then
                tm_log "ERROR" "TM_ENCRYPT_KEY_ID required for asymmetric encryption"
                return 1
            fi
            # Verify key exists in keyring
            if ! gpg --list-keys "${TM_ENCRYPT_KEY_ID}" &>/dev/null; then
                tm_log "ERROR" "GPG key ${TM_ENCRYPT_KEY_ID} not found in keyring"
                return 1
            fi
            ;;
        *)
            tm_log "ERROR" "Unknown encryption mode: ${mode}"
            return 1
            ;;
    esac

    return 0
}

# Encrypt a file or directory (creates .tar.gpg archive)
# Usage: tm_encrypt <source_path> [output_path]
# Returns: path to encrypted file
tm_encrypt() {
    local source_path="$1"
    local output_path="${2:-${source_path}.tar.gpg}"
    local mode="${TM_ENCRYPT_MODE:-symmetric}"

    if [[ ! -e "${source_path}" ]]; then
        tm_log "ERROR" "Source path does not exist: ${source_path}"
        return 1
    fi

    tm_log "INFO" "Encrypting: ${source_path} -> ${output_path}"

    local tar_cmd="tar -cf -"
    if [[ -d "${source_path}" ]]; then
        tar_cmd+=" -C $(dirname "${source_path}") $(basename "${source_path}")"
    else
        tar_cmd+=" -C $(dirname "${source_path}") $(basename "${source_path}")"
    fi

    case "${mode}" in
        symmetric)
            eval ${tar_cmd} | gpg --batch --yes --symmetric \
                --cipher-algo AES256 \
                --passphrase-fd 3 \
                --output "${output_path}" \
                3<<< "${TM_ENCRYPT_PASSPHRASE}"
            ;;
        asymmetric)
            eval ${tar_cmd} | gpg --batch --yes --encrypt \
                --recipient "${TM_ENCRYPT_KEY_ID}" \
                --trust-model always \
                --output "${output_path}"
            ;;
    esac

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        local size
        size=$(wc -c < "${output_path}" | tr -d ' ')
        tm_log "INFO" "Encryption complete: ${output_path} (${size} bytes)"
    else
        tm_log "ERROR" "Encryption failed for ${source_path}"
        rm -f "${output_path}"
    fi

    return ${rc}
}

# Decrypt a .tar.gpg archive
# Usage: tm_decrypt <encrypted_path> <output_dir>
tm_decrypt() {
    local encrypted_path="$1"
    local output_dir="$2"

    if [[ ! -f "${encrypted_path}" ]]; then
        tm_log "ERROR" "Encrypted file not found: ${encrypted_path}"
        return 1
    fi

    local mode="${TM_ENCRYPT_MODE:-symmetric}"

    tm_log "INFO" "Decrypting: ${encrypted_path} -> ${output_dir}"
    mkdir -p "${output_dir}"

    case "${mode}" in
        symmetric)
            gpg --batch --yes --decrypt \
                --passphrase-fd 3 \
                "${encrypted_path}" \
                3<<< "${TM_ENCRYPT_PASSPHRASE}" | \
                tar -xf - -C "${output_dir}"
            ;;
        asymmetric)
            gpg --batch --yes --decrypt \
                "${encrypted_path}" | \
                tar -xf - -C "${output_dir}"
            ;;
    esac

    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        tm_log "INFO" "Decryption complete: ${output_dir}"
    else
        tm_log "ERROR" "Decryption failed for ${encrypted_path}"
    fi

    return ${rc}
}

# Encrypt a completed backup snapshot
# Usage: tm_encrypt_backup <backup_dir>
# Creates <backup_dir>.tar.gpg and optionally removes the original
tm_encrypt_backup() {
    local backup_dir="$1"
    local remove_original="${2:-false}"

    if ! tm_encrypt_available; then
        tm_log "DEBUG" "Encryption not enabled; skipping"
        return 0
    fi

    local output="${backup_dir}.tar.gpg"

    if ! tm_encrypt "${backup_dir}" "${output}"; then
        return 1
    fi

    if [[ "${remove_original}" == "true" ]]; then
        tm_log "INFO" "Removing unencrypted backup: ${backup_dir}"
        rm -rf "${backup_dir}"
    fi

    return 0
}

# Decrypt a backup for restore
# Usage: tm_decrypt_backup <encrypted_file> <output_dir>
tm_decrypt_backup() {
    local encrypted_file="$1"
    local output_dir="$2"

    if ! tm_encrypt_available; then
        tm_log "ERROR" "Encryption not configured; cannot decrypt"
        return 1
    fi

    tm_decrypt "${encrypted_file}" "${output_dir}"
}
