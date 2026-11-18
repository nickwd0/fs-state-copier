#!/usr/bin/env bash
#
# fs-state-copier.sh - Script to collect metadata of files in a specified source directory,
# copy the files to a specified destination directory and verify whether the transfer completed successfully.
#
# Repository: 
#
# License: [TBD]
#
# shellcheck enable=all






# Modes: inventory, copy, verify and all (which executes all three modes)


# SET COMMANDS
set -o errexit
set -o errtrace
set -o noclobber
set -o nounset
set -o pipefail

umask 077

#==============================================================================#
#region   1. GLOBAL CONFIGURATION                                               #
#==============================================================================#

# ------------------------------------------------------------ #
# region  1.1. Environment configuration                       #
# ------------------------------------------------------------ #

# These names are intentionally uppercase because they are part of the
# script’s external environment/configuration interface.
TRACE="${TRACE:-false}"
DEBUG="${DEBUG:-false}"
FORCE="${FORCE:-false}"
PREFIX="${PREFIX:-}"
BASH_LOGGER_FILE="${BASH_LOGGER_FILE:-${PREFIX}/lib/bash-logger/logging.sh}"

# Locale determinism
export LC_ALL=C

# Enable xtrace as early as possible if requested
if [[ "${TRACE}" == 'true' ]]; then
	set -o xtrace
fi

# ------------------------------------------------------------ #
# endregion                                                    #
# region  1.2. Script identity                                 #
# ------------------------------------------------------------ #

FSC_SCRIPT_NAME_EXT="$(basename "${0}")"
readonly FSC_SCRIPT_NAME_EXT

readonly FSC_SCRIPT_NAME="${FSC_SCRIPT_NAME_EXT%.sh}"
SCRIPT_NAME="${FSC_SCRIPT_NAME_EXT}"

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   2. USER CONFIGURATION                                                 #
#==============================================================================#

# ------------------------------------------------------------ #
# region  2.1. General CLI configuration                       #
# ------------------------------------------------------------ #

mode=''
dry_run='false'
sign='false'
allow_empty='false'
# Additional arguments remaining after getopt processing
remaining_args=()

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.2. Enabled-mode flags                              #
# ------------------------------------------------------------ #

inventory_mode_enabled='false'
copy_mode_enabled='false'
verify_mode_enabled='false'
verify_signatures='auto'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.3. Paths                                           #
# ------------------------------------------------------------ #

source_dir=''
destination_dir=''
output_dir=''
inventory_run_dir=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.4. Link policies                                   #
# ------------------------------------------------------------ #

symlink_mode='preserve'
hardlink_mode='preserve'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.5. Inventory filters                               #
# ------------------------------------------------------------ #

inventory_find_args=(. -mindepth 1)
readonly inventory_find_args_base_count="${#inventory_find_args[@]}"

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.6. Inventory implementation defaults               #
# ------------------------------------------------------------ #

base_ls_cmd=(
	ls
	--almost-all		# -A
	--author
	--classify
	--full-time
	--hyperlink=never
	--inode				# -i
	--size				# -s
	--context			# -Z
)

base_eza_cmd=(
	eza
	--color=never
	--icons=never
	--hyperlink=never
	--long # -l
	--classify=always
	--all                 # -a
	--inode               # -i
	--octal-permissions   # -o
	--links               # -H
	--bytes               # -B
	--total-size          #
	--blocksize           # -S
	--group               # -g
	--flags               # -O
	--modified            # -m
	--changed             #
	--created             # -U
	--accessed            # -u
	--time-style=full-iso # '+%Y-%m-%dT%H:%M:%S%:z'
	--context             # -Z
	--extended            # -@
)

readonly inventory_config_schema_version='1'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.7. Signing configuration                           #
# ------------------------------------------------------------ #

signer_command=''
signer_command_version=''

# Sequoia/sq
sq_signer=''
sq_signer_email=''
sq_signer_file=''
sq_signer_userid=''

# GnuPG/gpg
gpg_local_user=''
gpg_verification_fingerprint=''

# ssh-keygen
ssh_keygen_signing_key_file=''
ssh_keygen_allowed_signers_file=''
ssh_keygen_signer_identity=''

# minisign
minisign_secret_key_file=''
minisign_public_key_file=''
minisign_public_key=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.8. Copy object policy                              #
# ------------------------------------------------------------ #

copy_special_objects_policy='false'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  2.9. CLI override flags                              #
# ------------------------------------------------------------ #

declare -A cli_overrides=(
	[symlink_mode]='false'
	[hardlink_mode]='false'
	[special_objects_mode]='false'
)

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   3. RUNTIME CAPABILITIES                                              #
#==============================================================================#

# ------------------------------------------------------------ #
# region  3.1. Optional-command capabilities                   #
# ------------------------------------------------------------ #

declare -A capability=(
	[jq]='unknown'
	[getfattr]='unknown'
	[eza]='unknown'
	[rsync]='unknown'

	[sq]='unknown'
	[gpg]='unknown'
	[ssh-keygen]='unknown'
	[minisign]='unknown'
)

# ------------------------------------------------------------ #
# endregion                                                    #
# region  3.2. rsync capability state                          #
# ------------------------------------------------------------ #

rsync_version_output=''
rsync_version=''
declare -A rsync_capabilities=(
	[socketpairs]='unknown'
	[symlinks]='unknown'
	[symtimes]='unknown'
	[hardlinks]='unknown'
	[hardlink_specials]='unknown'
	[hardlink_symlinks]='unknown'
	[ipv6]='unknown'
	[atimes]='unknown'
	[batchfiles]='unknown'
	[inplace]='unknown'
	[append]='unknown'
	[acls]='unknown'
	[xattrs]='unknown'
	[secluded_args]='unknown'
	[iconv]='unknown'
	[prealloc]='unknown'
	[stop_at]='unknown'
	[crtimes]='unknown'
)

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   4. LOGGING, RUN, LOCK AND PHASE STATE                                #
#==============================================================================#

# ------------------------------------------------------------ #
# region  4.1. Logging paths and state                         #
# ------------------------------------------------------------ #

bootstrap_log=''
final_log=''
bootstrap_timings_log=''
final_timings_log=''
bash_logger_ready='false'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  4.2. Run paths                                       #
# ------------------------------------------------------------ #

run_root=''
run_id=''
run_dir=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  4.3. Lock state                                      #
# ------------------------------------------------------------ #

lock_file=''
lock_fd=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  4.4. Phase state                                     #
# ------------------------------------------------------------ #

active_phase=''
active_phase_start_ns='0'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  4.5. Overall timing state                            #
# ------------------------------------------------------------ #

start_epoch_ns='0'
end_epoch_ns='0'
elapsed_ns='0'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  4.6. Exit state                                      #
# ------------------------------------------------------------ #

exit_status='0'
exit_phase=''
exit_reason=''
fatal_exit_in_progress='false'

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   5. ARTIFACT AND MANIFEST STATE                                       #
#==============================================================================#

# ------------------------------------------------------------ #
# region  5.1. Canonical manifest paths                        #
# ------------------------------------------------------------ #

objects_manifest_file=''
objects_manifest_sha256_file=''
objects_manifest_sha512_file=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  5.2. Temporary manifest record                       #
# ------------------------------------------------------------ #

manifest_record=''

# ------------------------------------------------------------ #
# endregion                                                    #
# region  5.3. Artifact registry                               #
# ------------------------------------------------------------ #

artifact_registry_path=''
artifact_event_sequence=0
artifact_registry_initialised='false'
declare -A artifact_initial_states=()
declare -A artifact_last_events=()
declare -A artifact_last_states=()
artifact_last_error=''

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   6. COMPLETION, COUNTER AND COPY STATE                                #
#==============================================================================#

# ------------------------------------------------------------ #
# region  6.1. Phase completion                                #
# ------------------------------------------------------------ #

inventory_completed='false'
copy_completed='false'
verify_completed='false'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  6.2. Warning and error counters                      #
# ------------------------------------------------------------ #

warn_count=0
error_count=0

# ------------------------------------------------------------ #
# endregion                                                    #
# region  6.3. Inventory counters                              #
# ------------------------------------------------------------ #

inventory_object_count=0
inventory_file_count=0
inventory_directory_count=0
inventory_symlink_count=0

# ------------------------------------------------------------ #
# endregion                                                    #
# region  6.4. Copy hard-link state                            #
# ------------------------------------------------------------ #

declare -A first_hardlink_destination=()

# ------------------------------------------------------------ #
# endregion                                                    #
# region  6.5. Verification/signature state                    #
# ------------------------------------------------------------ #

inventory_signatures_detected='false'

# ------------------------------------------------------------ #
# endregion                                                    #
# region  6.6. Loaded inventory configuration                  #
# ------------------------------------------------------------ #

inventory_symlink_mode=''
inventory_hardlink_mode=''
inventory_allow_empty='false'
inventory_copy_special_objects='false'

declare -a inventory_recorded_find_args=()
declare -a inventory_recorded_hash_algorithms=()

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   7. EXIT CODE DEFINITIONS                                             #
#==============================================================================#

# ------------------------------------------------------------ #
# region  7.1. General                                         #
# ------------------------------------------------------------ #

readonly EX_OK=0
readonly EX_FAIL=1              		# generic fallback only
readonly EX_USAGE=2             		# bad CLI usage / invalid arguments
readonly EX_CONFIG=3            		# invalid config / incompatible options
readonly EX_DEP_MISSING=4       		# required command missing
readonly EX_ENV=5               		# filesystem/permission/environment failure
readonly EX_INTERNAL=6          		# invariant/logic failure

# ------------------------------------------------------------ #
# endregion                                                    #
# region  7.2. Inventory                                       #
# ------------------------------------------------------------ #

readonly EX_INV_FAIL=10					# Inventory failed (high-level phase failure)
readonly EX_INV_LIST=11					# Source scan/list generation failed (find/sort pipeline)
readonly EX_INV_METADATA=12				# Metadata collection failed (ls/stat/du/eza/getfattr)
readonly EX_INV_HASH=13					# Source hashing failed (sha256sum/sha512sum)
readonly EX_INV_MANIFEST=14				# Artifact manifest generation failed

# ------------------------------------------------------------ #
# endregion                                                    #
# region  7.3. Signing                                       #
# ------------------------------------------------------------ #

readonly EX_SIGN_UNAVAILABLE=20			# Signing requested but signer unavailable/unsupported
readonly EX_SIGN_FAILED=21				# Signing operation failed
readonly EX_SIG_VERIFY_FAILED=22		# Signature verification failed (crypto check failed)
readonly EX_SIG_MISSING=23				# Signature artifact missing when required
readonly EX_SIGN_IDENTITY_INVALID=24	# Key/identity/allowed-signers invalid

# ------------------------------------------------------------ #
# endregion                                                    #
# region  7.4. Copy                                            #
# ------------------------------------------------------------ #

readonly EX_COPY_FAIL=30				# Copy phase failed (high-level)
readonly EX_COPY_PREP=31				# Directory creation/prep at destination failed
readonly EX_COPY_FILES=32				# File copy failed
readonly EX_COPY_SYMLINKS=33			# Symlink recreation failed
readonly EX_COPY_POST=34				# Post-copy metadata capture failed (e.g., df after)

# ------------------------------------------------------------ #
# endregion                                                    #
# region  7.5. Verification                                    #
# ------------------------------------------------------------ #

readonly EX_VERIFY_FAIL=40				# Verify phase failed (high-level)
readonly EX_VERIFY_INPUT_MISSING=41		# Verification input missing (required inventory artifacts absent)
readonly EX_VERIFY_PATH_MISMATCH=42		# Path mismatch only (missing/extra)
readonly EX_VERIFY_HASH_MISMATCH=43		# Hash mismatch only
readonly EX_VERIFY_BOTH_MISMATCH=44		# Path + hash mismatch
readonly EX_VERIFY_METADATA_MISMATCH=45	# Metadata mismatch only (if you add metadata checks)
readonly EX_VERIFY_UNAVAILABLE=46		# Verify could not complete (tooling/read errors during verify)

# ------------------------------------------------------------ #
# endregion                                                    #
# region  7.6. Locking and user interaction                    #
# ------------------------------------------------------------ #

readonly EX_USER_ABORT=50				# User declined confirmation prompt
readonly EX_FORCE_REQUIRED=51			# Refused overwrite without --force
readonly EX_LOCKED=52					# Lock contention / concurrent run detected

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   8. GENERAL UTILITY HELPERS                                           #
#==============================================================================#

# ------------------------------------------------------------ #
# region  8.1. Exit-code naming                                #
# ------------------------------------------------------------ #

# Globals:
#   EX_* (r)
# Arguments:
#   An integer between 0 and 52 inclusive
get_exit_code_name() {
	case "${1}" in
		("${EX_OK}") printf '%s\n' 'EX_OK' ;;
		("${EX_FAIL}") printf '%s\n' 'EX_FAIL' ;;
		("${EX_USAGE}") printf '%s\n' 'EX_USAGE' ;;
		("${EX_CONFIG}") printf '%s\n' 'EX_CONFIG' ;;
		("${EX_DEP_MISSING}") printf '%s\n' 'EX_DEP_MISSING' ;;
		("${EX_ENV}") printf '%s\n' 'EX_ENV' ;;
		("${EX_INTERNAL}") printf '%s\n' 'EX_INTERNAL' ;;

		("${EX_INV_FAIL}") printf '%s\n' 'EX_INV_FAIL' ;;
		("${EX_INV_LIST}") printf '%s\n' 'EX_INV_LIST' ;;
		("${EX_INV_METADATA}") printf '%s\n' 'EX_INV_METADATA' ;;
		("${EX_INV_HASH}") printf '%s\n' 'EX_INV_HASH' ;;
		("${EX_INV_MANIFEST}") printf '%s\n' 'EX_INV_MANIFEST' ;;

		("${EX_SIGN_UNAVAILABLE}") printf '%s\n' 'EX_SIGN_UNAVAILABLE' ;;
		("${EX_SIGN_FAILED}") printf '%s\n' 'EX_SIGN_FAILED' ;;
		("${EX_SIG_VERIFY_FAILED}") printf '%s\n' 'EX_SIG_VERIFY_FAILED' ;;
		("${EX_SIG_MISSING}") printf '%s\n' 'EX_SIG_MISSING' ;;
		("${EX_SIGN_IDENTITY_INVALID}") printf '%s\n' 'EX_SIGN_IDENTITY_INVALID' ;;

		("${EX_COPY_FAIL}") printf '%s\n' 'EX_COPY_FAIL' ;;
		("${EX_COPY_PREP}") printf '%s\n' 'EX_COPY_PREP' ;;
		("${EX_COPY_FILES}") printf '%s\n' 'EX_COPY_FILES' ;;
		("${EX_COPY_SYMLINKS}") printf '%s\n' 'EX_COPY_SYMLINKS' ;;
		("${EX_COPY_POST}") printf '%s\n' 'EX_COPY_POST' ;;

		("${EX_VERIFY_FAIL}") printf '%s\n' 'EX_VERIFY_FAIL' ;;
		("${EX_VERIFY_INPUT_MISSING}") printf '%s\n' 'EX_VERIFY_INPUT_MISSING' ;;
		("${EX_VERIFY_PATH_MISMATCH}") printf '%s\n' 'EX_VERIFY_PATH_MISMATCH' ;;
		("${EX_VERIFY_HASH_MISMATCH}") printf '%s\n' 'EX_VERIFY_HASH_MISMATCH' ;;
		("${EX_VERIFY_BOTH_MISMATCH}") printf '%s\n' 'EX_VERIFY_BOTH_MISMATCH' ;;
		("${EX_VERIFY_METADATA_MISMATCH}") printf '%s\n' 'EX_VERIFY_METADATA_MISMATCH' ;;
		("${EX_VERIFY_UNAVAILABLE}") printf '%s\n' 'EX_VERIFY_UNAVAILABLE' ;;

		("${EX_USER_ABORT}") printf '%s\n' 'EX_USER_ABORT' ;;
		("${EX_FORCE_REQUIRED}") printf '%s\n' 'EX_FORCE_REQUIRED' ;;
		("${EX_LOCKED}") printf '%s\n' 'EX_LOCKED' ;;

		(*) printf '%s\n' 'EX_UNKNOWN' ;;
	esac
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  8.2. Date and time formatting                        #
# ------------------------------------------------------------ #

# Usage: get_current_timestamp
# 
# Returns the date and time in ISO 8601 format, with nanoseconds
#
# Used by:
#   log_bootstrap_message
#   acquire_run_lock
#   log_artifact_event
#   inventory_write_config
#   inventory_write_completion_marker
#   write_signing_metadata
#   sign_hash_manifest_with_gpg
#   sign_hash_manifest_with_minisign
#
# External dependencies:
#   date
get_current_timestamp() {
	date '+%Y-%m-%dT%H:%M:%S.%9N%:z'
}

# Usage: get_current_filename_timestamp
#
# Date and time in ISO 8601-inspired format, with nanoseconds, modified to be suitable to be used as filenames on Windows.
# Instead of the timezone offset, the resulting string contains a short timezone name.
#
# Used by:
#   <none>
#
# External dependencies:
#   date
get_current_filename_timestamp() {
	date '+%Y-%m-%dT%H_%M_%S_%9N_%Z'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  8.3. Safe directory navigation                       #
# ------------------------------------------------------------ #

# Usage: cd_or_die <path> <exit_code> <message>
#
# Tries to cd into a given directory and ‘dies’ the script if cd failed.
#
# Local variables:
#   path
#   exit_code
#   message
#
# Used by:
#   write_run_artifact_manifests (inside subshell)
#   execute_inventory_phase
#   execute_copy_phase
#
# Internal dependencies:
#   fatal_exit
#
# External dependencies:
#   cd
cd_or_die() {
	if [[ "${#}" -ne '3' ]]; then
		return "${EX_USAGE}"
	fi

	local path="${1}"
	local exit_code="${2}"
	local message="${3}"

	if ! cd "${path}"; then fatal_exit "${exit_code}" "${message}"; fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  8.4. JSON encoding                                   #
# ------------------------------------------------------------ #

# Usage: json_escape <value>
#
# Escapes a string to be usable in a JSON value context.
# Currently handles backslashes, quotes, newlines, carriage returns, tabs, formfeeds and backspaces.
#
# Local variables:
#   value
#
# Used by:
#   json_string_or_null
#   load_inventory_metadata
#   record_artifact_event
#   json_string_array
#   inventory_write_config
#
# Bash built-ins used:
#   printf
json_escape() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local value="${1}"

	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\n'/\\n}"
	value="${value//$'\r'/\\r}"
	value="${value//$'\t'/\\t}"
	value="${value//$'\f'/\\f}"
	value="${value//$'\b'/\\b}"

	printf '%s' "${value}"
}

# Usage: json_bool <bool>
#
# Local variables:
#   bool
#
# Used by:
#   inventory_write_config
#   write_run_statistics
#
# Bash built-ins used:
#   printf
json_bool() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local bool="${1}"

	case "${bool}" in
		('true' | 'false')
			printf '%s' "${1}"
			;;
		(*)
			printf 'false'
			;;
	esac
}

# Usage: json_string_or_null <value>
#
# Local variables:
#   value
#
# Used by:
#   write_run_statistics
#
# Internal dependencies:
#   json_escape
#
# Bash built-ins used:
#   printf
json_string_or_null() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local value="${1}"

	if [[ -n "${value}" ]]; then
		printf '"%s"' "$(json_escape "${value}")"
	else
		printf 'null'
	fi
}

# Usage: json_number_or_null <value>
#
# Local variables:
#   value
#
# Used by:
#   <none yet>
#
# Bash built-ins used:
#   printf
json_number_or_null() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local value="${1}"

	if [[ "${value}" =~ ^[0-9]+$ ]]; then
		printf '%s' "${value}"
	else
		printf 'null'
	fi
}

json_string_array() {
	local -n values="${1}"
	local value
	local first='true'

	for value in "${values[@]}"; do
		if [[ "${first}" == 'true' ]]; then
			first='false'
		else
			printf ', '
		fi
		printf '"%s"' "$(json_escape "${value}")"
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  8.5. Generic record helpers                          #
# ------------------------------------------------------------ #

# Usage: count_nul_records <file>
#
# Local variables:
#   file
#
# Used by:
#   inventory_write_object_lists
#   inventory_validate_list_counts
#
# Bash built-ins used:
#   printf
#
# External dependencies:
#   tr
#   wc
count_nul_records() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local file="${1}"

	tr -cd '\0' < "${file}" | wc -c
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region   9. ERROR HANDLING, LOGGING AND USER INTERACTION                      #
#==============================================================================#

# ------------------------------------------------------------ #
# region  9.1. Temporary logging                               #
# ------------------------------------------------------------ #

# Usage: log_bootstrap_message <level> <message>
#
# Temporary logging function, using a temporary bootstrapped log location, accepting two parameters (level and message).
# Replaced by bash-logger once that is initialised.
#
# Local variables:
#   level
#   message
#
# Used by:
#   log_warning
#   log_err
#   start_phase_at
#   finish_phase
#   create_bootstrap_logs
#   create_bootstrap_timings_log
#   initialise_bash_logger
#   finalise_log_location
#
# Internal dependencies:
#   get_current_timestamp
#
# Bash built-ins used:
#   printf
#   exit
#
# External dependencies:
#   tee
log_bootstrap_message() {
	if [[ "${#}" -ne '2' ]]; then
		return "${EX_USAGE}"
	fi

	if [[ -z "${bootstrap_log}" ]]; then
		printf '%s [%s] [CRITICAL] Bootstrap logging failed\n' "$(get_current_timestamp)" "${FSC_SCRIPT_NAME_EXT}" >&2
		exit "${EX_ENV}"
	fi

	local level="${1}"
	local message="${2}"

	printf '%s [%s] [%s] %s\n' "$(get_current_timestamp)" "${FSC_SCRIPT_NAME_EXT}" "${level}" "${message}" | tee -a -- "${bootstrap_log}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  9.2. Warning and error reporting                     #
# ------------------------------------------------------------ #

# Usage: log_warning <error_message>
#
# Increments warn_count and warns with either the bootstrap logger or bash-logger
#
# Local variables:
#   error_message
#
# Used by:
#   
#
# Bash built-ins used:
#   
log_warning() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local error_message="${1}"

	warn_count="$((warn_count + 1))"

	if [[ "${bash_logger_ready}" == 'true' ]]; then
		log_warn "${error_message}"
	else
		log_bootstrap_message 'WARN' "${error_message}"
	fi
}

# Usage: log_err <error_message>
#
# Increments error_count
#
# Local variables:
#   error_message
#
# Used by:
#   
#
# Bash built-ins used:
#   
log_err() {
	if [[ "${#}" -ne '1' ]]; then
		return "${EX_USAGE}"
	fi

	local error_message="${1}"

	error_count="$((error_count + 1))"

	if [[ "${bash_logger_ready}" == 'true' ]]; then
		log_error "${error_message}"
	else
		log_bootstrap_message 'ERROR' "${error_message}" >&2
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  9.3. Fatal termination                               #
# ------------------------------------------------------------ #

# Usage: fatal_exit <exit_code> [error_message...]
fatal_exit() {
	local exit_code="${1}"
	shift
	local error_message="${*:-fatal error}"

	exit_status="${exit_code}"
	exit_reason="${error_message}"

	log_err "${error_message}"
	fatal_exit_in_progress='true'
	exit "${exit_code}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region  9.4. User interaction                                #
# ------------------------------------------------------------ #

ask_for_user_confirmation() {
	local message="${1}"
	local strictreply
	local relaxedreply

	printf '%s\n' "${message}"
	select strictreply in "Yes" "No"; do
		relaxedreply="${strictreply:-${REPLY}}"
		case "${relaxedreply}" in
			('Yes' | 'yes' | 'y')
				return 0
				;;
			('No' | 'no' | 'n')
				return 1
				;;
			(*)
				;;
		esac
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  10. PHASE AND TIMING MANAGEMENT                                       #
#==============================================================================#

# ------------------------------------------------------------ #
# region 10.1. Phase lifecycle                                 #
# ------------------------------------------------------------ #

set_current_phase() {
	exit_phase="${1}"
}

start_phase_at() {
	local phase="${1}"
	local phase_start_ns="${2}"

	active_phase="${phase}"
	active_phase_start_ns="${phase_start_ns}"
	set_current_phase "${active_phase}"

	if [[ "${bash_logger_ready}" == 'true' ]]; then
		log_notice "Starting phase ${active_phase}"
	else
		log_bootstrap_message 'NOTICE' "Starting phase ${active_phase}"
	fi
}

start_phase() {
	local phase="${1}"
	local phase_start_ns

	phase_start_ns="$(date '+%s%9N')"
	start_phase_at "${phase}" "${phase_start_ns}"
}

finish_phase() {
	local phase_t1_ns
	phase_t1_ns="$(date '+%s%9N')"
	local elapsed_ns="$((phase_t1_ns - active_phase_start_ns))"

	if [[ "${bash_logger_ready}" == 'true' ]]; then
		log_debug "Phase ${active_phase} completed in $((elapsed_ns / 1000000000)) seconds"
	elif [[ "${DEBUG}" == 'true' ]]; then
		log_bootstrap_message 'DEBUG' "Phase ${active_phase} completed in $((elapsed_ns / 1000000000)) seconds"
	fi

	printf '%s\t%s\t%s\t%s\n' "${active_phase}" "${active_phase_start_ns}" "${phase_t1_ns}" "$((elapsed_ns / 1000000000))" >> "${final_timings_log:-${bootstrap_timings_log}}"
}

transition_phase() {
	if [[ -n "${active_phase}" ]]; then finish_phase; fi
	start_phase "${1}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  11. BOOTSTRAP AND LOGGER LIFECYCLE                                    #
#==============================================================================#

# ------------------------------------------------------------ #
# region 11.1. Bootstrap logging                               #
# ------------------------------------------------------------ #

create_bootstrap_logs() {
	local created_log
	local type
	local type_space

	for type in 'log' 'timings_log'; do
		type_space="${type/_/ }"
		if ! created_log="$(mktemp -t "${FSC_SCRIPT_NAME}_bootstrap_${type}_XXXXXXXX")"; then
			printf '%s\n' "Could not create bootstrap ${type_space}" >&2
			exit "${EX_ENV}"
		fi

		if [[ "${type}" == 'log' ]]; then
			bootstrap_log="${created_log}"
		else
			bootstrap_timings_log="${created_log}"
		fi

		if [[ "${DEBUG}" == 'true' ]]; then
			log_bootstrap_message 'DEBUG' "Initialised bootstrap ${type_space}ging"
			log_bootstrap_message 'DEBUG' "Bootstrap ${type_space} location: ${created_log}"
		fi
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 11.2. Bootstrap timing logging                        #
# ------------------------------------------------------------ #

create_bootstrap_timings_log() {
	bootstrap_timings_log="$(mktemp -t "${FSC_SCRIPT_NAME}_timings_log_XXXXXXXX")"
	printf '%s\t%s\t%s\t%s\n' 'phase' 'start_epoch_ns' 'end_epoch_ns' 'duration_sec' >| "${bootstrap_timings_log}"
	if [[ "${DEBUG}" == 'true' ]]; then
		log_bootstrap_message 'DEBUG' 'Initialised bootstrap timings logging'
		log_bootstrap_message 'DEBUG' "Bootstrap timings log location: ${bootstrap_timings_log}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 11.3. External logger initialisation                  #
# ------------------------------------------------------------ #

initialise_bash_logger() {
	# Explicitly unset any pre-existing bash-logger variables to ensure clean state
	if [[ "${DEBUG}" == 'true' ]]; then
		log_bootstrap_message 'DEBUG' 'Initialising bash-logger'
		log_bootstrap_message 'DEBUG' "BASH_LOGGER_FILE currently set to ${BASH_LOGGER_FILE}"
	fi
	unset LOG_FILE USE_COLORS LOG_FORMAT CURRENT_LOG_LEVEL LOG_STDERR_LEVEL USE_JOURNAL

	if [[ ! -r "${BASH_LOGGER_FILE}" ]]; then
		fatal_exit "${EX_DEP_MISSING}" "Missing logger: ${BASH_LOGGER_FILE}"
	fi

	# Verify checksum of bash-logger before sourcing"${PREFIX}/lib/bash-logger/logging.sh"
	local expected_checksum="671444EBDC1E16E9BC7B3078AD7DAE795842F0D60FCB81950C818F842CD4F91C"
	local actual_checksum
	actual_checksum="$(sha256sum "${BASH_LOGGER_FILE}" | awk '{print $1}' | tr a-z A-Z | tr -dc A-Z0-9)"

	if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
		log_bootstrap_message 'CRITICAL' 'logging.sh checksum mismatch!' >&2
		exit "${EX_INTERNAL}"
	fi
	if [[ "${DEBUG}" == 'true' ]]; then log_bootstrap_message 'DEBUG' 'logging.sh checksum matched'; fi

	# shellcheck source=C:\Users\Nick\Git\nidunc\bash-logger\logging.sh
	source "${BASH_LOGGER_FILE}"
	if ! init_logger --format "%i [%s] [%l] %m" --logfile "${bootstrap_log}" --level INFO; then
		fatal_exit "${EX_INTERNAL}" 'Failed to initialise bash-logger'
	fi

	bash_logger_ready='true'

	if [[ "${DEBUG}" == 'true' ]]; then
		set_log_level DEBUG
		log_debug 'Debug mode enabled'
	fi

	log_debug 'bash-logger initialised successfully'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 11.4. Final log hand-off                              #
# ------------------------------------------------------------ #

finalise_log_location() {
	final_log="${run_dir}/logs/${FSC_SCRIPT_NAME}.log"
	mkdir --parents -- "${run_dir}/logs"

	cp -- "${bootstrap_log}" "${final_log}"
	if ! cmp --silent -- "${bootstrap_log}" "${final_log}"; then
		fatal_exit "${EX_ENV}" 'Bootstrap log was not successfully copied to final log location'
	fi

	if ! init_logger --format "%i [%s] [%l] %m" --logfile "${final_log}" --level INFO --no-init-message; then
		log_bootstrap_message 'CRITICAL' 'Failed to initialise logger at final log location'
	fi

	log_debug "Bootstrap log successfully copied to final log location (from ${bootstrap_log} to ${final_log})"

	if [[ "${DEBUG}" == 'true' ]]; then set_log_level DEBUG; fi

	log_notice 'Removing bootstrap log'
	rm -f "${bootstrap_log}"
	unset bootstrap_log
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 11.5. Final timing-log hand-off                       #
# ------------------------------------------------------------ #

finalise_timings_log_location() {
	final_timings_log="${run_dir}/logs/${FSC_SCRIPT_NAME}.timings.tsv"
	mkdir --parents -- "${run_dir}/logs"

	cp -- "${bootstrap_timings_log}" "${final_timings_log}"
	if ! cmp --silent -- "${bootstrap_timings_log}" "${final_timings_log}"; then
		fatal_exit "${EX_ENV}" 'Bootstrap timings log was not successfully copied to final timings log location'
	fi

	log_debug "Bootstrap timings log successfully copied to final timings log location (from ${bootstrap_timings_log} to ${final_timings_log})"

	log_notice 'Removing bootstrap timings log'
	rm -f "${bootstrap_timings_log}"
	unset bootstrap_timings_log
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  12. DEPENDENCY AND CAPABILITY DETECTION                               #
#==============================================================================#

# ------------------------------------------------------------ #
# region 12.1. Required dependencies                           #
# ------------------------------------------------------------ #

check_required_dependencies() {
	local cmd
	local -a missing_cmds_arr=()

	for cmd in \
		'awk' \
		'basename' \
		'cat' \
		'cmp' \
		'cp' \
		'date' \
		'diff' \
		'dirname' \
		'df' \
		'du' \
		'find' \
		'flock' \
		'getopt' \
		'grep' \
		'head' \
		'hostname' \
		'ln' \
		'ls' \
		'mkdir' \
		'mktemp' \
		'mv' \
		'readlink' \
		'rm' \
		'sed' \
		'sha256sum' \
		'sha512sum' \
		'sort' \
		'stat' \
		'tee' \
		'tr' \
		'wc'; do
		if ! command -v "${cmd}" > /dev/null 2>&1; then
			missing_cmds_arr+=("${cmd}")
		fi
	done

	if [[ "${#missing_cmds_arr[@]}" -gt '0' ]]; then
		local sep=', '
		local missing_cmds

		missing_cmds="$(printf "${sep//\%/%%}%s" "${missing_cmds_arr[@]}")"
		missing_cmds="${missing_cmds:${#sep}}"
		fatal_exit "${EX_DEP_MISSING}" "Missing required commands: ${missing_cmds}"
	fi
}

require_gnu_getopt() {
	log_debug 'Checking getopt version'

	local code

	if getopt -T; then
		code='0'
	else
		code="${?}"
	fi

	if [[ "${code}" != '4' ]]; then
		fatal_exit "${EX_DEP_MISSING}" 'Incorrect getopt version detected'
	fi

	log_debug 'Correct getopt version detected'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 12.2. Optional capabilities                           #
# ------------------------------------------------------------ #

detect_optional_capabilities() {
	local binary

	for binary in "${!capability[@]}"; do
		if command -v "${binary}" > /dev/null 2>&1; then
			capability["${binary}"]='true'
		else
			capability["${binary}"]='false'
		fi
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 12.3. rsync detection                                 #
# ------------------------------------------------------------ #

detect_rsync_information() {
	local rc

	if [[ "${capability[rsync]}" != 'true' ]]; then
		return 0
	fi

	rsync_version='unknown'

	if rsync_version_output="$(rsync --version 2>/dev/null)"; then
		:
	else
		rc="${?}"
		log_warning "rsync is installed but could not execute (error ${rc}); falling back to the non-rsync copy backend"
		capability[rsync]='false'
		rsync_version_output=''
		return 0
	fi

	if [[ -z "${rsync_version_output}" ]]; then
		log_warning 'rsync returned empty version output; falling back to the non-rsync copy backend'
		capability[rsync]='false'
		return 0
	fi

	if [[ "${rsync_version_output}" != *'version '* ]]; then
		log_warning 'Could not parse rsync version; disabling rsync backend'
		capability[rsync]='false'
		return 0
	fi

	rsync_version="${rsync_version_output#*version }"
	rsync_version="${rsync_version%%$'\n'*}"
	rsync_version="${rsync_version/  / (})"
}

parse_rsync_capabilities() {
	local caps
	local cap
	local key
	local state
	local -a capabilities

	if [[ "${capability[rsync]}" != 'true' ]]; then
		return 0
	fi

	if [[ -z "${rsync_version_output}" ]]; then
		artifact_last_error='rsync capability output is unavailable'
		return "${EX_INTERNAL}"
	fi

	caps="${rsync_version_output#*$'\nCapabilities:'}"
	caps="${caps%%$'\nOptimizations:'*}"
	caps="${caps//$'\n'/ }"

	IFS=, read -r -a capabilities <<< "${caps}"

	for cap in "${capabilities[@]}"; do
		cap="${cap#"${cap%%[![:space:]]*}"}"
		cap="${cap%"${cap##*[![:space:]]}"}"

		if [[ -z "${cap}" ]]; then continue; fi

		state='true'
		cap="${cap,,}"
	
		if [[ "${cap}" == 'no '* ]]; then
			state='false'
			cap="${cap#no }"
		fi

		cap="${cap#optional }"
		key="${cap//-/_}"

		if [[ -v "rsync_capabilities[${key}]" ]]; then
			rsync_capabilities["${key}"]="${state}"
		fi
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  13. COMMAND-LINE PARSING AND CONFIGURATION VALIDATION                 #
#==============================================================================#

# ------------------------------------------------------------ #
# region 13.1. Help and usage                                  #
# ------------------------------------------------------------ #

show_help() {
	cat << EOF
Usage:
  ${FSC_SCRIPT_NAME_EXT} --mode MODE --source DIR [OPTIONS]

Modes:
  inventory       Inventory and hash the source directory.
  copy            Copy the source directory to the destination.
  verify          Verify a destination against an inventory run.
  all             Inventory, copy, and verify in one run.

Required options:
  -m, --mode MODE
  -s, --source DIR

Mode-specific options:
  -d, --destination DIR
      Required for copy, verify, and all.
	  Required for inventory, if --output-dir not present

  --output-dir DIR
      Directory in which run artifacts are stored.
	  Required for inventory, if --destination not present

  --inventory-run-dir DIR
      Existing inventory run used by verify mode.

Inventory options:
  --newer-than-date DATE
  --newer-than-file FILE
  --allow-empty

Copy and safety options:
  --dry-run
  -f, --force

Link options:
  --symlink-mode MODE
      preserve, dereference, or reject.
      Default: preserve.

  --hardlink-mode MODE
      preserve, duplicate, or reject.
      Default: preserve.

Signing options:
  General:
    --sign
    --signing-command COMMAND

  Sequoia (sq):
    --sq-signer VALUE
    --sq-signer-email EMAIL
    --sq-signer-file FILE
    --sq-signer-userid USERID

  GnuPG (GPG):
    --gpg-local-user USERID
    --gpg-verification-fingerprint FINGERPRINT

  ssh-keygen:
    --ssh-keygen-key-file FILE
    --ssh-keygen-allowed-signers-file FILE
    --ssh-keygen-signer-identity IDENTITY

  minisign
    --minisign-seckey-file FILE
    --minisign-pubkey-file FILE
    --minisign-pubkey KEY

Environment:
  TRACE=true
  DEBUG=true
  FORCE=true
  PREFIX=/installation/prefix

Exit status:
  0   Success
  2   Invalid usage
  3   Invalid configuration
  4   Missing dependency
  10+ Inventory failure
  20+ Signing failure
  30+ Copy failure
  40+ Verification failure
  50+ Lock/user-abort failure
EOF
	exit "${EX_OK}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 13.2. Path validation and canonicalisation            #
# ------------------------------------------------------------ #

resolve_existing_directory() {
	local parameter="${1}"
	local path="${2/#\~/${HOME}}"
	local canonical_path

	if [[ "${path}" != /* ]]; then
		fatal_exit "${EX_ENV}" \
			"The path specified for ${parameter} is not absolute"
	fi

	if [[ ! -d "${path}" ]]; then
		fatal_exit "${EX_ENV}" \
			"The path specified for ${parameter} is not an existing directory"
	fi

	if ! canonical_path="$(cd -L -- "${path}" && pwd -L)"; then
		fatal_exit "${EX_ENV}" \
			"The path specified for ${parameter} is not accessible"
	fi

	printf '%s\n' "${canonical_path}"
}

resolve_existing_or_createable_directory() {
	local parameter="${1}"
	local path="${2/#\~/${HOME}}"
	local parent_dir
	local canonical_parent

	if [[ "${path}" != /* ]]; then
		fatal_exit "${EX_ENV}" \
			"The path specified for ${parameter} is not absolute"
	fi

	if [[ -d "${path}" ]]; then
		resolve_existing_directory "${parameter}" "${path}"
		return
	fi

	parent_dir="$(dirname -- "${path}")"

	if [[ ! -d "${parent_dir}" ]]; then
		fatal_exit "${EX_ENV}" \
			"The parent directory for ${parameter} does not exist: ${parent_dir}"
	fi

	if ! canonical_parent="$(cd -L -- "${parent_dir}" && pwd -L)"; then
		fatal_exit "${EX_ENV}" \
			"The parent directory for ${parameter} is not accessible"
	fi

	printf '%s/%s\n' \
		"${canonical_parent}" \
		"$(basename -- "${path}")"
}

resolve_readable_file() {
	local parameter="${1}"
	local path="${2/#\~/${HOME}}"

	if [[ ! "${path}" =~ ^/ ]]; then fatal_exit "${EX_ENV}" "The path provided for ${parameter} is not absolute"; fi
	if [[ ! -r "${path}" ]]; then fatal_exit "${EX_ENV}" "The path provided for ${parameter} is not readable"; fi
	if [[ ! -f "${path}" ]]; then fatal_exit "${EX_ENV}" "The path provided for ${parameter} is not a file"; fi

	printf '%s\n' "${path}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 13.3. Command-line parsing                            #
# ------------------------------------------------------------ #

# parse_mode_option() {

# }

# parse_path_option() {

# }

# parse_inventory_filter_option() {

# }

# parse_link_policy_option() {
	
# }

# parse_signing_option() {
	
# }

parse_command_line() {
	transition_phase 'parse_args'
	log_debug 'Processing script arguments'

	local ARGS
	# Exit if arg parsing fails
	ARGS=$(getopt --options 'hvfm:s:d:' \
		--longoptions 'help,verbose,dry-run,force,allow-empty' \
		--longoptions 'mode:,source:,destination:' \
		--longoptions 'output-dir:,inventory-run-dir:,newer-than-date:,newer-than-file:' \
		--longoptions 'symlink-mode:,hardlink-mode:,copy-special-objects,sign,signing-command:' \
		--longoptions 'sq-signer:,sq-signer-email:,sq-signer-file:,sq-signer-userid:' \
		--longoptions 'gpg-local-user:,gpg-verification-fingerprint:' \
		--longoptions 'ssh-keygen-key-file:,ssh-keygen-allowed-signers-file:,ssh-keygen-signer-identity:' \
		--longoptions 'minisign-seckey-file:,minisign-pubkey-file:,minisign-pubkey:' \
		--longoptions 'verify-signatures,no-verify-signatures' \
		-- "${@}") || exit "${EX_USAGE}"

	eval set -- "${ARGS}"
	unset ARGS

	while true; do
		case "${1}" in
			('-h' | '--help')
				show_help
				;;
			('-v' | '--verbose')
				if [[ "${DEBUG}" == 'true' ]]; then
					log_debug "Debug mode was already enabled through DEBUG; ignoring ${1}"
				else
					DEBUG='true'
					set_log_level DEBUG
					log_debug 'Debug mode enabled'
				fi

				shift
				;;
			('--dry-run')
				dry_run='true'
				log_debug 'Dry-run mode enabled'
				shift
				;;
			('-f' | '--force')
				if [[ "${FORCE}" == 'true' ]]; then
					log_debug "Force mode was already enabled through FORCE; ignoring ${1}"
				else
					FORCE='true'
					log_debug 'Force mode enabled'
				fi

				shift
				;;
			('--allow-empty')
				allow_empty='true'
				log_debug 'Allowing empty source directory'
				shift
				;;
			('-m' | '--mode')
				log_debug "Processing required argument ${1}"
				log_debug "Value provided for argument ${1}: '${2}'"

				case "${2}" in
					('all' | 'inventory' | 'copy' | 'verify')
						mode="${2}"
						log_debug "${1} was successfully set to '${2}'"
						;;
					(*)
						fatal_exit "${EX_USAGE}" "Invalid mode: ${2}"
						;;
				esac

				shift 2
				;;
			('-s' | '--source')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					source_dir="$(resolve_existing_directory "${1}" "${2}")"
					log_debug "${1} was successfully set to '${source_dir}'"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('-d' | '--destination')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					destination_dir="$(resolve_existing_or_createable_directory "${1}" "${2}")"
					log_debug "${1} was successfully set to '${destination_dir}'"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--output-dir')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					output_dir="$(resolve_existing_or_createable_directory "${1}" "${2}")"
					log_debug "${1} was successfully set to '${output_dir}'"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--inventory-run-dir')
				# TODO: Validate it contains source.objects.tsv file (among others)
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					inventory_run_dir="$(resolve_existing_directory "${1}" "${2}")"
					log_debug "${1} was successfully set to '${inventory_run_dir}'"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--newer-than-date')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					log_debug "Value provided for ${1}: '${2}'"
					if [[ "${#inventory_find_args[@]}" -gt "${inventory_find_args_base_count}" ]]; then
						fatal_exit "${EX_USAGE}" "${1} can not be used together with --newer-than-file"
					fi
					if (find . -maxdepth 0 -newermt "${2}" > /dev/null); then
						inventory_find_args+=(-newermt "${2}")
						log_debug "${1} was successfully set to '${2}'"
					else
						fatal_exit "${EX_USAGE}" "The value provided for ${2} is invalid"
					fi
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--newer-than-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					log_debug "Value provided for ${1}: '${2}'"

					if [[ "${#inventory_find_args[@]}" -gt "${inventory_find_args_base_count}" ]]; then
						fatal_exit "${EX_USAGE}" "${1} can not be used together with --newer-than-date"
					fi

					local path
					path="$(resolve_readable_file "${1}" "${2}")"

					inventory_find_args+=(-newermm "${path}")
					log_debug "${1} was successfully set to '${path}'"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--symlink-mode')
				case "${2}" in
					('preserve' | 'dereference' | 'reject')
						symlink_mode="${2}"
						cli_overrides['symlink_mode']='true'
						;;
					(*)
						fatal_exit "${EX_USAGE}" \
							"Invalid symlink mode: ${2}; expected preserve, dereference, or reject"
						;;
				esac

				shift 2
				;;

			('--hardlink-mode')
				case "${2}" in
					('preserve' | 'duplicate' | 'reject')
						hardlink_mode="${2}"
						cli_overrides['hardlink_mode']='true'
						;;
					(*)
						fatal_exit "${EX_USAGE}" \
							"Invalid hard-link mode: ${2}; expected preserve, duplicate, or reject"
						;;
				esac

				shift 2
				;;
			('--copy-special-objects')
				copy_special_objects_policy='true'
				cli_overrides['special_objects_mode']='true'
				log_debug 'Copying special objects enabled'
				shift
				;;
			('--sign')
				sign='true'
				log_debug 'Signing enabled'
				shift
				;;
			('--signing-command')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					if ! command -v "${2}" > /dev/null 2>&1; then fatal_exit "${EX_USAGE}" "${2} is not a valid command"; fi

					signer_command="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--sq-signer')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					sq_signer="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--sq-signer-email')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					sq_signer_email="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--sq-signer-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					sq_signer_file="$(resolve_readable_file "${1}" "${2}")"
					log_debug "${1} set to ${sq_signer_file}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--sq-signer-userid')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					sq_signer_userid="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--gpg-local-user')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					gpg_local_user="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--gpg-verification-fingerprint')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					gpg_verification_fingerprint="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--ssh-keygen-key-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					ssh_keygen_signing_key_file="$(resolve_readable_file "${1}" "${2}")"
					log_debug "${1} set to ${ssh_keygen_signing_key_file}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--ssh-keygen-allowed-signers-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					ssh_keygen_allowed_signers_file="$(resolve_readable_file "${1}" "${2}")"
					log_debug "${1} set to ${ssh_keygen_allowed_signers_file}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--ssh-keygen-signer-identity')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					ssh_keygen_signer_identity="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--minisign-seckey-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					minisign_secret_key_file="$(resolve_readable_file "${1}" "${2}")"
					log_debug "${1} set to ${minisign_secret_key_file}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--minisign-pubkey-file')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					minisign_public_key_file="$(resolve_readable_file "${1}" "${2}")"
					log_debug "${1} set to ${minisign_public_key_file}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--minisign-pubkey')
				log_debug "Processing argument ${1}"

				if [[ -n "${2:-}" ]]; then
					minisign_public_key="${2}"
					log_debug "${1} set to ${2}"
				else
					log_debug "No value was provided for ${1}"
				fi

				shift 2
				;;
			('--verify-signatures')
				verify_signatures='true'
				shift
				;;
			('--no-verify-signatures')
				verify_signatures='false'
				shift
				;;
			('--')
				shift
				break
				;;
			(*)
				fatal_exit "${EX_USAGE}" 'getopt internal error' # error
				;;
		esac
	done

	remaining_args=("${@}")

	if [[ "${#remaining_args[@]}" -gt 0 ]]; then
		fatal_exit "${EX_USAGE}" \
			"Unexpected positional arguments: ${remaining_args[*]}"
	fi

	log_debug 'Script arguments processed successfully'

	log_notice "Run config: source=${source_dir}; destination=${destination_dir}; output=${output_dir:-<default>}; dry-run=${dry_run}; sign=${sign}; signer=${signer_command:-<auto>}; force=${FORCE}"
	log_notice "Find filters: ${inventory_find_args[*]}"
	log_notice "Remaining arguments (currently unused): ${remaining_args[*]}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 13.4. Signer detection and validation                 #
# ------------------------------------------------------------ #

detect_default_signer() {
	if [[ "${capability[sq]}" == 'true' ]]; then
		printf '%s\n' 'sq'
		return 0
	fi
	if [[ "${capability[gpg]}" == 'true' ]]; then
		printf '%s\n' 'gpg'
		return 0
	fi
	if [[ "${capability[ssh-keygen]}" == 'true' ]]; then
		printf '%s\n' 'ssh-keygen'
		return 0
	fi
	if [[ "${capability[minisign]}" == 'true' ]]; then
		printf '%s\n' 'minisign'
		return 0
	fi

	return 1
}

validate_signing_configuration() {
	if [[ "${sign}" == 'false' ]]; then
		return "${EX_OK}"
	fi

	if [[ -z "${signer_command}" ]]; then
		if ! signer_command="$(detect_default_signer)"; then
			fatal_exit "${EX_SIGN_UNAVAILABLE}" 'Signing requested but no supported signer found (sq, gpg, ssh-keygen, minisign)'
		fi

		log_notice "Auto-selected signer: ${signer_command}"
	fi

	case "${signer_command}" in
		('sq')
			if [[ "${capability[sq]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if ! signer_command_version="$(sq version | head -n 3)"; then
				fatal_exit "${EX_SIGN_FAILED}" "Failed to get ${signer_command} version"
			fi
			signer_command_version="${signer_command_version//$'\n'/; }"

			if [[ -z "${sq_signer}" && -z "${sq_signer_email}" && -z "${sq_signer_file}" && -z "${sq_signer_userid}" ]]; then
				log_notice 'No signer was specified for sq; will use the default identity (--signer-self) when signing'
			fi
			;;
		('gpg')
			if [[ "${capability[gpg]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if ! signer_command_version="$(gpg --version | head -n 2)"; then
				fatal_exit "${EX_SIGN_FAILED}" "Failed to get ${signer_command} version"
			fi
			signer_command_version="${signer_command_version//$'\n'/; }"

			if [[ -z "${gpg_local_user}" ]]; then
				log_notice 'No user ID was specified for gpg; will use the default identity when signing'
			fi
			;;
		('ssh-keygen')
			if [[ "${capability[ssh-keygen]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if ! signer_command_version="$(ssh -V)"; then
				fatal_exit "${EX_SIGN_FAILED}" "Failed to get ${signer_command} version"
			fi

			if [[ -z "${ssh_keygen_signing_key_file}" ]]; then
				fatal_exit "${EX_SIGN_IDENTITY_INVALID}" 'Signing with ssh-keygen requires --ssh-keygen-key-file <key_file>'
			fi
			;;
		('minisign')
			if [[ "${capability[minisign]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if ! signer_command_version="$(minisign -v)"; then
				fatal_exit "${EX_SIGN_FAILED}" "Failed to get ${signer_command} version"
			fi

			if [[ -z "${minisign_secret_key_file}" ]]; then
				log_notice 'No secret key file was specified for minisign; will use the default secret key when signing'
			fi
			;;
		(*)
			fatal_exit "${EX_CONFIG}" "Unsupported signer: ${signer_command} (supported: sq, gpg, ssh-keygen, minisign)"
			;;
	esac
}

validate_signature_verification_selection() {
	if [[ "${sign}" == 'false' ]]; then
		return 0
	fi

	case "${signer_command}" in
		('sq')
			if [[ "${capability[sq]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if [[ -z "${sq_signer}" && -z "${sq_signer_email}" && -z "${sq_signer_file}" && -z "${sq_signer_userid}" ]]; then
				log_notice 'No signer was specified for sq; will use the default identity (--signer-self) when verifying'
			fi
			;;
		('gpg')
			if [[ "${capability[gpg]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if [[ -z "${gpg_verification_fingerprint}" ]]; then
				log_notice 'No fingerprint was specified for gpg; will only check whether signatures are valid'
			fi
			;;
		('ssh-keygen')
			if [[ "${capability[ssh-keygen]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if [[ -z "${ssh_keygen_allowed_signers_file}" ]]; then
				fatal_exit "${EX_SIGN_IDENTITY_INVALID}" 'Verification with ssh-keygen requires --ssh-keygen-allowed-signers-file <allowed_signers_file>'
			fi
			if [[ -z "${ssh_keygen_signer_identity}" ]]; then
				fatal_exit "${EX_SIGN_IDENTITY_INVALID}" 'Verification with ssh-keygen requires --ssh-keygen-signer-identity <signer_identity>'
			fi
			;;
		('minisign')
			if [[ "${capability[minisign]}" != 'true' ]]; then
				fatal_exit "${EX_SIGN_UNAVAILABLE}" "Signer ${signer_command} requested but ${signer_command} is not installed"
			fi

			if [[ -z "${minisign_public_key_file}" && -z "${minisign_public_key}" ]]; then
				fatal_exit "${EX_SIGN_IDENTITY_INVALID}" 'No public key (file) was specified for minisign; specify one with either --minisign-pubkey-file <pubkey_file> or --minisign-pubkey <pubkey>'
			fi
			;;
		(*)
			fatal_exit "${EX_CONFIG}" "Unsupported signer: ${signer_command} (supported: sq, gpg, ssh-keygen, minisign)"
			;;
	esac
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 13.5. Source/destination validation                   #
# ------------------------------------------------------------ #

validate_source_destination_relationship() {
	local src="${1}"
	local dest="${2}"
	local what="${3}"

	log_debug 'Double-checking whether a source directory was provided'
	if [[ -z "${src}" ]]; then fatal_exit "${EX_USAGE}" 'A source directory is required'; fi

	log_debug "Double-checking whether a(n) ${what} directory was provided"
	if [[ -z "${dest}" ]]; then
		fatal_exit "${EX_USAGE}" "A(n) ${what} directory is required"
	fi

	log_debug "Checking whether the source and ${what} directories are the same"
	if [[ "${src}" == "${dest}" ]]; then
		log_critical "The source and ${what} directories must not be the same"
		exit "${EX_CONFIG}"
	fi

	log_debug "Checking whether the ${what} directory is inside the source directory"
	case "${dest}" in
		("${src}"/*)
			log_critical 'The destination directory must not be inside of the source directory'
			exit "${EX_CONFIG}"
			;;
		(*)
			log_debug 'The destination directory is not inside the source directory'
			;;
	esac
}

validate_inventory_artifact_set() {
	local inventory_dir="${1}"
	local missing_code="${2:-${EX_VERIFY_INPUT_MISSING}}"
	local required_file
	local recorded_source

	if [[ ! -d "${inventory_dir}" ]]; then
		fatal_exit "${missing_code}" \
			"Inventory run directory does not exist: ${inventory_dir}"
	fi

	if [[ ! -r "${inventory_dir}/inventory.complete" ]]; then
		fatal_exit "${missing_code}" \
			"Inventory run is incomplete: ${inventory_dir}"
	fi

	for required_file in \
		inventory.source.path.null \
		source.all.null \
		source.files.null \
		source.directories.null \
		source.symlinks.null \
		source.objects.tsv; do
		if [[ ! -r "${inventory_dir}/${required_file}" ]]; then
			fatal_exit "${missing_code}" \
				"Missing inventory artifact: ${inventory_dir}/${required_file}"
		fi
	done

	
	if IFS= read -r -d '' recorded_source \
		< "${inventory_dir}/inventory.source.path.null"; then
		:
	else
		fatal_exit "${missing_code}" \
			'Inventory source identity is invalid'
	fi

	if [[ "${recorded_source}" != "${source_dir}" ]]; then
		fatal_exit "${EX_CONFIG}" \
			"Inventory source does not match requested source: ${recorded_source}"
	fi
}

apply_inventory_link_policy() {
	if [[ "${#}" -ne 2 ]]; then
		fatal_exit "${EX_USAGE}" \
			'apply_inventory_link_policy requires symlink and hard-link policies'
	fi

	local configured_symlink_mode="${1}"
	local configured_hardlink_mode="${2}"

	if [[ "${configured_symlink_mode}" != 'preserve' &&
		"${configured_symlink_mode}" != 'dereference' &&
		"${configured_symlink_mode}" != 'reject' ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Invalid inventory symlink policy: ${configured_symlink_mode}"
	fi

	if [[ "${configured_hardlink_mode}" != 'preserve' &&
		"${configured_hardlink_mode}" != 'duplicate' &&
		"${configured_hardlink_mode}" != 'reject' ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Invalid inventory hard-link policy: ${configured_hardlink_mode}"
	fi

	if [[ "${cli_overrides['symlink_mode']}" != 'true' ]]; then
		symlink_mode="${configured_symlink_mode}"
	fi

	if [[ "${cli_overrides['hardlink_mode']}" != 'true' ]]; then
		hardlink_mode="${configured_hardlink_mode}"
	fi
}

load_inventory_metadata() {
	local metadata_file="${inventory_run_dir}/inventory.config.json"
	local source_identity_file="${inventory_run_dir}/inventory.source.path.null"
	local recorded_source
	local config_source
	local config_schema
	local config_symlink_mode
	local config_hardlink_mode
	local config_allow_empty
	local config_special_objects
	local value

	if [[ ! -r "${metadata_file}" ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Missing inventory configuration: ${metadata_file}"
	fi

	if [[ ! -r "${source_identity_file}" ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Missing inventory source identity: ${source_identity_file}"
	fi

	if ! IFS= read -r -d '' recorded_source < "${source_identity_file}"; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Invalid inventory source identity: ${source_identity_file}"
	fi

	if [[ "${capability[jq]}" == 'true' ]]; then
		if ! jq -e \
			--arg source "${source_dir}" \
			'
			type == "object" and
			.schema_version == 1 and
			.source_dir == $source and
			(.symlink_mode | type == "string") and
			(.symlink_mode == "preserve" or
			 .symlink_mode == "dereference" or
			 .symlink_mode == "reject") and
			(.hardlink_mode | type == "string") and
			(.hardlink_mode == "preserve" or
			 .hardlink_mode == "duplicate" or
			 .hardlink_mode == "reject") and
			(.allow_empty | type == "boolean") and
			(.copy_special_objects_policy | type == "boolean") and
			(.inventory_find_args | type == "array" and
			 all(.[]; type == "string")) and
			(.hash_algorithms | type == "array" and
			 all(.[]; . == "sha256" or . == "sha512"))
			' "${metadata_file}" > /dev/null; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid inventory configuration: ${metadata_file}"
		fi

		if ! config_source="$(jq -er '.source_dir' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Missing source_dir in inventory configuration: ${metadata_file}"
		fi

		if [[ "${config_source}" != "${recorded_source}" &&
			"${config_source}" != "${source_dir}" ]]; then
			fatal_exit "${EX_CONFIG}" \
				'Requested source does not match the inventory source'
		fi

		if ! config_schema="$(jq -er '.schema_version' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Could not read schema_version: ${metadata_file}"
		fi
		if ! config_symlink_mode="$(jq -er '.symlink_mode' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Could not read symlink_mode: ${metadata_file}"
		fi
		if ! config_hardlink_mode="$(jq -er '.hardlink_mode' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Could not read hardlink_mode: ${metadata_file}"
		fi
		if ! config_allow_empty="$(jq -r '.allow_empty' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Could not read allow_empty: ${metadata_file}"
		fi
		if ! config_special_objects="$(jq -r '.copy_special_objects_policy' "${metadata_file}")"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Could not read copy_special_objects_policy: ${metadata_file}"
		fi

		inventory_recorded_find_args=()
		while IFS= read -r value; do
			inventory_recorded_find_args+=("${value}")
		done < <(jq -er '.inventory_find_args[]' "${metadata_file}")

		inventory_recorded_hash_algorithms=()
		while IFS= read -r value; do
			inventory_recorded_hash_algorithms+=("${value}")
		done < <(jq -er '.hash_algorithms[]' "${metadata_file}")
	else
		# The fallback is intentionally schema-specific: it parses only the
		# exact JSON representation emitted by inventory_write_config.
		if ! grep -Fq '  "schema_version": 1,' "${metadata_file}" ||
			! grep -Fq '"symlink_mode": "' "${metadata_file}" ||
			! grep -Fq '"hardlink_mode": "' "${metadata_file}" ||
			! grep -Fq '"allow_empty": ' "${metadata_file}" ||
			! grep -Fq '"copy_special_objects_policy": ' "${metadata_file}" ||
			! grep -Fq '"inventory_find_args": [' "${metadata_file}" ||
			! grep -Fq '"hash_algorithms": ["sha256", "sha512"]' "${metadata_file}"; then
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid inventory configuration: ${metadata_file}"
		fi

		if ! grep -Fq \
			"\"source_dir\": \"$(json_escape "${recorded_source}")\"" \
			"${metadata_file}"; then
			fatal_exit "${EX_CONFIG}" \
				'Inventory configuration does not match inventory source identity'
		fi

		if grep -Fq '"symlink_mode": "preserve"' "${metadata_file}"; then
			config_symlink_mode='preserve'
		elif grep -Fq '"symlink_mode": "dereference"' "${metadata_file}"; then
			config_symlink_mode='dereference'
		elif grep -Fq '"symlink_mode": "reject"' "${metadata_file}"; then
			config_symlink_mode='reject'
		else
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid symlink policy: ${metadata_file}"
		fi

		if grep -Fq '"hardlink_mode": "preserve"' "${metadata_file}"; then
			config_hardlink_mode='preserve'
		elif grep -Fq '"hardlink_mode": "duplicate"' "${metadata_file}"; then
			config_hardlink_mode='duplicate'
		elif grep -Fq '"hardlink_mode": "reject"' "${metadata_file}"; then
			config_hardlink_mode='reject'
		else
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid hard-link policy: ${metadata_file}"
		fi

		if grep -Fq '"allow_empty": true' "${metadata_file}"; then
			config_allow_empty='true'
		elif grep -Fq '"allow_empty": false' "${metadata_file}"; then
			config_allow_empty='false'
		else
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid allow_empty value: ${metadata_file}"
		fi

		if grep -Fq '"copy_special_objects_policy": true' "${metadata_file}"; then
			config_special_objects='true'
		elif grep -Fq '"copy_special_objects_policy": false' "${metadata_file}"; then
			config_special_objects='false'
		else
			fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
				"Invalid copy_special_objects_policy value: ${metadata_file}"
		fi

		inventory_recorded_find_args=("${inventory_find_args[@]}")
		inventory_recorded_hash_algorithms=('sha256' 'sha512')
		config_schema='1'
	fi

	if [[ "${config_schema}" != '1' ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Unsupported inventory configuration schema: ${config_schema}"
	fi

	inventory_symlink_mode="${config_symlink_mode}"
	inventory_hardlink_mode="${config_hardlink_mode}"
	inventory_allow_empty="${config_allow_empty}"
	inventory_copy_special_objects="${config_special_objects}"

	if [[ "${mode}" == 'verify' ]]; then
		if [[ "${cli_overrides['symlink_mode']}" == 'true' ||
			"${cli_overrides['hardlink_mode']}" == 'true' ]]; then
			fatal_exit "${EX_CONFIG}" \
				'Link-policy overrides are not allowed in verify mode'
		fi

		symlink_mode="${inventory_symlink_mode}"
		hardlink_mode="${inventory_hardlink_mode}"
		allow_empty="${config_allow_empty}"

		if [[ "${cli_overrides['special_objects_mode']}" == 'true' ]]; then
			fatal_exit "${EX_CONFIG}" \
				'Copy special objects policy override is not allowed in verify mode'
		fi
	elif [[ "${mode}" == 'copy' ]]; then
		apply_inventory_link_policy \
			"${inventory_symlink_mode}" \
			"${inventory_hardlink_mode}"

		if [[ "${cli_overrides['special_objects_mode']}" != "true" ]]; then
			copy_special_objects_policy="${inventory_copy_special_objects}"
		fi
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 13.6. Overall configuration validation                #
# ------------------------------------------------------------ #

validate_configuration() {
	transition_phase 'validate_args'

	if [[ -z "${mode}" ]]; then
		fatal_exit "${EX_USAGE}" 'A mode is required: inventory, copy, verify or all'
	fi

	if [[ "${mode}" == 'inventory' || "${mode}" == 'all' ]]; then
		if [[ -z "${output_dir}" && -z "${destination_dir}" ]]; then
			fatal_exit "${EX_USAGE}" 'Inventory requires --output-dir, or --destination in all mode'
		fi

		validate_source_destination_relationship "${source_dir}" "${output_dir:-${destination_dir}}" 'output/destination'
		validate_signing_configuration

		inventory_mode_enabled='true'
	else
		log_notice 'Inventory mode disabled; skipping'
	fi

	if [[ "${mode}" == 'copy' || "${mode}" == 'all' ]]; then
		# verify whether inventory mode was run at some point before (if copy mode is on its own)
		validate_source_destination_relationship "${source_dir}" "${destination_dir}" 'destination'

		if [[ "${mode}" == 'copy' && -z "${inventory_run_dir}" ]]; then
			fatal_exit "${EX_USAGE}" \
				'Copy mode requires --inventory-run-dir'
		fi

		copy_mode_enabled='true'
	else
		log_notice 'Copy mode disabled; skipping'
	fi

	if [[ "${mode}" == 'verify' || "${mode}" == 'all' ]]; then
		# destination directory should be specified (and optionally output directory),
		# as well as various signing-related variables.
		if [[ -z "${destination_dir}" ]]; then
			fatal_exit "${EX_USAGE}" 'A destination directory is required for verification'
		fi

		if [[ -z "${inventory_run_dir}" && "${mode}" == 'verify' ]]; then
			fatal_exit "${EX_USAGE}" 'An inventory run directory is required for verification'
		fi

		verify_mode_enabled='true'
	else
		log_notice 'Verification mode disabled; skipping'
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  14. RUN SETUP AND CONCURRENCY                                         #
#==============================================================================#

# ------------------------------------------------------------ #
# region 14.1. Run-path setup                                  #
# ------------------------------------------------------------ #

inventory_output_root() {
	if [[ -n "${output_dir}" ]]; then
		printf '%s\n' "${output_dir}"
		return 0
	fi

	if [[ "${mode}" == 'inventory' ]]; then
		fatal_exit "${EX_USAGE}" \
			'Inventory mode requires --output-dir'
	fi

	printf '%s\n' "${destination_dir}/.${FSC_SCRIPT_NAME}"
}

create_run_directory() {
	run_root="$(inventory_output_root)"
	run_id="$(date '+%s%9N')"
	run_dir="${run_root}/runs/${run_id}-${mode}"

	if ! mkdir --parents -- "${run_dir}"; then
		fatal_exit "${EX_ENV}" "Could not create run directory: ${run_dir}"
	fi

	log_debug "Run directory created: ${run_dir}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 14.2. Lock acquisition                                #
# ------------------------------------------------------------ #

acquire_run_lock() {
	lock_file="${run_root}/.${FSC_SCRIPT_NAME}.lock"
	mkdir --parents -- "${run_root}"

	if ! exec {lock_fd}> "${lock_file}"; then
		fatal_exit "${EX_LOCKED}" "Failed to open lock file: ${lock_file}"
	fi

	if ! flock -n "${lock_fd}"; then
		fatal_exit "${EX_LOCKED}" "Another ${FSC_SCRIPT_NAME} run is active (lock: ${lock_file})"
	fi

	printf '%s\t%s\t%s\n' "$$" "$(hostname)" "$(get_current_timestamp)" 1>&"${lock_fd}"
	log_debug "Acquired lock: ${lock_file} (fd=${lock_fd})"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 14.3. Lock release                                    #
# ------------------------------------------------------------ #

release_run_lock() {
	if [[ -n "${lock_fd}" ]]; then
		flock -u "${lock_fd}" || true
		eval "exec ${lock_fd}>&-"
		lock_fd=''
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  15. ARTIFACT REGISTRY                                                 #
#==============================================================================#

# ------------------------------------------------------------ #
# region 15.1. Registry initialisation                         #
# ------------------------------------------------------------ #

# Globals:
#   run_dir (r)
#   artifact_error (w)
# Arguments:
#   None
# Files:
#   ${run_dir}/.artifacts/registry.jsonl (w)
initialise_artifact_registry() {
	local registry_dir="${run_dir}/.artifacts"
	local error_code

	if mkdir --parents -- "${registry_dir}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact registry directory: ${registry_dir}"
		return "${error_code}"
	fi

	artifact_registry_path="${registry_dir}/registry.jsonl"

	if printf '%s' '' > "${artifact_registry_path}"; then
		return 0
	else
		error_code="${?}"
		artifact_last_error="Failed to initialise artifact registry file: ${artifact_registry_path}"
		return "${error_code}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.2. Artifact path conversion and validation         #
# ------------------------------------------------------------ #

# Usage: artifact_get_relative_path <result_variable> <scope> <absolute_path>
artifact_get_relative_path() {
	if [[ "${#}" -ne '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local -n result_variable="${1}"
	local scope="${2}"
	local absolute_path="${3}"
	local root=''

	result_variable=''
	artifact_last_error=''

	case "${scope}" in
		('run')
			root="${run_dir}"
			;;
		('source')
			root="${source_dir}"
			;;
		('destination')
			root="${destination_dir}"
			;;
		('temp' | 'external')
			if [[ "${absolute_path}" != /* ]]; then
				artifact_last_error="${scope} artifact path must be absolute: ${absolute_path}"
				return "${EX_INTERNAL}"
			fi

			result_variable="${absolute_path}"
			return 0
			;;
		(*)
			artifact_last_error="Unknown artifact scope: ${scope}"
			return "${EX_INTERNAL}"
			;;
	esac

	case "${absolute_path}" in
		("${root}")
			result_variable='.'
			return 0
			;;
		("${root}"/*)
			result_variable="${absolute_path#"${root}/"}"
			return 0
			;;
		(*)
			artifact_last_error="Path is outside ${scope} root: ${absolute_path}"
			return "${EX_INTERNAL}"
			;;
	esac
}

# Usage: artifact_validate_relative_path <scope> <path>
artifact_validate_relative_path() {
	if [[ "${#}" -ne '2' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local scope="${1}"
	local path="${2}"
	local component

	if [[ -z "${path}" ]]; then
		artifact_last_error="Artifact path must not be empty"
		return "${EX_INTERNAL}"
	fi

	if [[ "${path}" == /* ]]; then
		artifact_last_error="${scope} artifact path must be relative: ${path}"
		return "${EX_INTERNAL}"
	fi

	local -a components=()
	IFS='/' read -r -a components <<< "${path}"

	for component in "${components[@]}"; do
		case "${component}" in
			('' | '.' | '..')
				artifact_last_error="${scope} artifact path contains unsafe component: ${path}"
				return "${EX_INTERNAL}"
				;;
			(*)
				;;
		esac
	done
}

# Usage: artifact_resolve_absolute_path <result_variable> <scope> <path>
artifact_resolve_absolute_path() {
	if [[ "${#}" -ne '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local -n result_variable="${1}"
	local scope="${2}"
	local path="${3}"
	local root=''
	local error_code

	result_variable=''
	artifact_last_error=''

	case "${scope}" in
		('run')
			root="${run_dir}"
			;;
		('source')
			root="${source_dir}"
			;;
		('destination')
			root="${destination_dir}"
			;;
		('temp' | 'external')
			if [[ "${path}" != /* ]]; then
				artifact_last_error="${scope} artifact path must be absolute: ${path}"
				return "${EX_INTERNAL}"
			fi

			result_variable="${path}"
			return 0
			;;
		(*)
			artifact_last_error="Unknown artifact scope: ${scope}"
			return "${EX_INTERNAL}"
			;;
	esac

	if artifact_validate_relative_path "${scope}" "${path}"; then
		result_variable="${root}/${path}"
		return 0
	else
		error_code="${?}"
		artifact_last_error="Could not resolve ${scope} artifact path '${path}': ${artifact_last_error}"
		return "${error_code}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.3. Artifact state inspection                       #
# ------------------------------------------------------------ #

# Usage: get_filesystem_object_type <path>
get_filesystem_object_type() {
	if [[ "${#}" -ne '1' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local path="${1}"

	if [[ -L "${path}" ]]; then
		printf '%s\n' 'symlink'
	elif [[ -f "${path}" ]]; then
		printf '%s\n' 'file'
	elif [[ -d "${path}" ]]; then
		printf '%s\n' 'directory'
	elif [[ -p "${path}" ]]; then
		printf '%s\n' 'fifo'
	elif [[ -S "${path}" ]]; then
		printf '%s\n' 'socket'
	elif [[ -b "${path}" ]]; then
		printf '%s\n' 'block-device'
	elif [[ -c "${path}" ]]; then
		printf '%s\n' 'character-device'
	elif [[ -e "${path}" ]]; then
		printf '%s\n' 'other'
	else
		printf '%s\n' 'absent'
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.4. Artifact event recording                        #
# ------------------------------------------------------------ #

# Usage: record_artifact_event <event> <scope> <producer> <absolute_path> <previous_event> <previous_state> <result> [detail]
record_artifact_event() {
	if [[ "${#}" -lt '7' || "${#}" -gt '8' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local event="${1}"
	local scope="${2}"
	local producer="${3}"
	local absolute_path="${4}"
	local previous_event="${5}"
	local previous_state="${6}"
	local result="${7}"
	local detail="${8:-}"

	local relative_path=''
	local timestamp
	local error_code

	if [[ "${artifact_registry_initialised}" != "true" ]]; then
		artifact_last_error='Artifact registry has not been initialised'
		return "${EX_INTERNAL}"
	fi

	if artifact_get_relative_path 'relative_path' "${scope}" "${absolute_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not get relative path: ${artifact_last_error}"
		return "${error_code}"
	fi

	timestamp="$(get_current_timestamp)"
	artifact_event_sequence="$((artifact_event_sequence + 1))"

	if printf '{%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s}\n' \
		"\"sequence\":${artifact_event_sequence}" \
		"\"timestamp\":\"$(json_escape "${timestamp}")\"" \
		"\"event\":\"$(json_escape "${event}")\"" \
		"\"phase\":\"$(json_escape "${active_phase}")\"" \
		"\"producer\":\"$(json_escape "${producer}")\"" \
		"\"scope\":\"$(json_escape "${scope}")\"" \
		"\"path\":\"$(json_escape "${relative_path}")\"" \
		"\"absolute_path\":\"$(json_escape "${absolute_path}")\"" \
		"\"previous_event\":\"$(json_escape "${previous_event}")\"" \
		"\"previous_state\":\"$(json_escape "${previous_state}")\"" \
		"\"result\":\"$(json_escape "${result}")\"" \
		"\"detail\":\"$(json_escape "${detail}")\"" \
		>> "${artifact_registry_path}"
	then
		artifact_last_events["${absolute_path}"]="${event}"
		artifact_last_states["${absolute_path}"]="$(get_filesystem_object_type "${absolute_path}")"
		return 0
	else
		error_code="${?}"
		artifact_last_error="Failed to append artifact event: ${artifact_registry_path}"
		return "${error_code}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.5. Artifact lifecycle events                       #
# ------------------------------------------------------------ #

# Usage: artifact_plan <scope> <relative_path> [producer]
artifact_plan() {
	if [[ "${#}" -lt '2' || "${#}" -gt '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local scope="${1}"
	local relative_path="${2}"
	local producer="${3:-${FUNCNAME[1]:-main}}"

	local absolute_path=''
	local previous_event=''
	local previous_state
	local error_code

	if artifact_resolve_absolute_path 'absolute_path' "${scope}" "${relative_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not resolve artifact path: ${artifact_last_error}"
		return "${error_code}"
	fi

	previous_event="${artifact_last_events["${absolute_path}"]:-none}"

	previous_state="$(get_filesystem_object_type "${absolute_path}")"

	if [[ -z "${artifact_initial_states["${absolute_path}"]+set}" ]]; then
		artifact_initial_states["${absolute_path}"]="${previous_state}"
	fi

	if record_artifact_event \
		'planned' \
		"${scope}" \
		"${producer}" \
		"${absolute_path}" \
		"${previous_event}" \
		"${previous_state}" \
		'pending' \
		''; then
		return 0
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact event: ${artifact_last_error}"
		return "${error_code}"
	fi
}

# Usage: artifact_mark_created <scope> <relative_path> [producer]
artifact_mark_created() {
	if [[ "${#}" -lt '2' || "${#}" -gt '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local scope="${1}"
	local relative_path="${2}"
	local producer="${3:-${FUNCNAME[1]:-main}}"

	local absolute_path=''
	local previous_event=''
	local previous_state=''
	local event='created'
	local error_code

	if artifact_resolve_absolute_path 'absolute_path' "${scope}" "${relative_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not resolve artifact path: ${artifact_last_error}"
		return "${error_code}"
	fi

	previous_event="${artifact_last_events["${absolute_path}"]:-none}"
	previous_state="${artifact_last_states["${absolute_path}"]:-${artifact_initial_states["${absolute_path}"]:-absent}}"

	if [[ "${previous_state}" != 'absent' ]]; then
		event='overwritten'
	fi

	if record_artifact_event \
		"${event}" \
		"${scope}" \
		"${producer}" \
		"${absolute_path}" \
		"${previous_event}" \
		"${previous_state}" \
		'success' \
		''; then
		return 0
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact event: ${artifact_last_error}"
		return "${error_code}"
	fi
}

# Usage: artifact_mark_failed <scope> <relative_path> <detail> [producer]
artifact_mark_failed() {
	if [[ "${#}" -lt '3' || "${#}" -gt '4' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local scope="${1}"
	local relative_path="${2}"
	local detail="${3}"
	local producer="${4:-${FUNCNAME[1]:-main}}"

	local absolute_path=''
	local previous_event=''
	local previous_state=''
	local error_code

	if artifact_resolve_absolute_path 'absolute_path' "${scope}" "${relative_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not resolve artifact path: ${artifact_last_error}"
		return "${error_code}"
	fi

	previous_event="${artifact_last_events["${absolute_path}"]:-none}"
	previous_state="${artifact_last_states["${absolute_path}"]:-${artifact_initial_states["${absolute_path}"]:-absent}}"

	if record_artifact_event \
		'failed' \
		"${scope}" \
		"${producer}" \
		"${absolute_path}" \
		"${previous_event}" \
		"${previous_state}" \
		'failure' \
		"${detail}"; then
		return 0
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact event: ${artifact_last_error}"
		return "${error_code}"
	fi
}

# Usage: artifact_mark_deleted <scope> <relative_path> [producer]
artifact_mark_deleted() {
	if [[ "${#}" -lt '2' || "${#}" -gt '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local scope="${1}"
	local relative_path="${2}"
	local producer="${3:-${FUNCNAME[1]:-main}}"

	local absolute_path=''
	local previous_event=''
	local previous_state=''
	local error_code

	if artifact_resolve_absolute_path 'absolute_path' "${scope}" "${relative_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not resolve artifact path: ${artifact_last_error}"
		return "${error_code}"
	fi

	previous_event="${artifact_last_events["${absolute_path}"]:-none}"
	previous_state="${artifact_last_states["${absolute_path}"]:-${artifact_initial_states["${absolute_path}"]:-unknown}}"

	if record_artifact_event \
		'deleted' \
		"${scope}" \
		"${producer}" \
		"${absolute_path}" \
		"${previous_event}" \
		"${previous_state}" \
		'success' \
		''
	then
		return "${EX_OK}"
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact event: ${artifact_last_error}"
		return "${error_code}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.6. Dry-run stuff                                   #
# ------------------------------------------------------------ #

artifact_record_planned_result() {
    local scope="${1}"
    local relative_path="${2}"
    local result="${3}"
    local detail="${4:-}"
    local producer="${5:-dry-run}"
    local absolute_path error_code previous_event previous_state

    if artifact_resolve_absolute_path 'absolute_path' "${scope}" "${relative_path}"; then
		:
	else
		error_code="${?}"
		artifact_last_error="Could not resolve artifact path: ${artifact_last_error}"
		return "${error_code}"
	fi

    previous_event="${artifact_last_events["${absolute_path}"]:-none}"
    previous_state="${artifact_last_states["${absolute_path}"]:-$(get_filesystem_object_type "${absolute_path}")}"

    if record_artifact_event \
        'planned' \
        "${scope}" \
        "${producer}" \
        "${absolute_path}" \
        "${previous_event}" \
        "${previous_state}" \
        "${result}" \
        "${detail}"
	then
		return "${EX_OK}"
	else
		error_code="${?}"
		artifact_last_error="Failed to create artifact event: ${artifact_last_error}"
		return "${error_code}"
	fi
}

artifact_mark_would_create() {
    artifact_record_planned_result \
        "${1}" "${2}" 'would-create' "${3:-dry-run}"
}

artifact_mark_would_overwrite() {
    artifact_record_planned_result \
        "${1}" "${2}" 'would-overwrite' "${3:-dry-run}"
}

artifact_mark_would_fail() {
    artifact_record_planned_result \
        "${1}" "${2}" 'would-fail' "${3}" "${4:-dry-run}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 15.7. Atomic artifact writing                         #
# ------------------------------------------------------------ #

# Usage: artifact_write_atomic <producer> <scope> <output_file> <command> [args...]
write_artifact_atomically() {
	if [[ "${#}" -lt '4' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	artifact_last_error=''

	local producer="${1}"
	local scope="${2}"
	local path="${3}"
	local writer="${4}"

	local output_file=''
	local temporary_file=''
	local error_code=0
	local error_message=''
	local primary_error=''
	local registry_error=''
	local output_parent
	output_parent="$(dirname -- "${output_file}")"

	if [[ -z "${writer}" ]]; then
		artifact_last_error='Artifact writer command must not be empty'
		return "${EX_USAGE}"
	fi

	shift 4

	if artifact_resolve_absolute_path 'output_file' "${scope}" "${path}"; then
		:
	else
		error_code="${?}"
		error_message="Failed to resolve artifact path (${artifact_last_error})"
	fi

	if [[ -z "${error_message}" ]]; then
		if [[ -e "${output_file}" || -L "${output_file}" ]]; then
			if [[ "${FORCE}" != 'true' ]]; then
				artifact_last_error="Refusing to overwrite existing artifact: ${output_file}"
				return "${EX_FORCE_REQUIRED}"
			fi
		fi
	fi

	if [[ -z "${error_message}" ]]; then
		if artifact_plan "${scope}" "${path}" "${producer}"; then
			:
		else
			error_code="${?}"
			error_message="Failed to plan artifact: ${artifact_last_error}"
		fi
	fi

	if [[ -z "${error_message}" ]]; then
		if ! mkdir --parents -- "${output_parent}"; then
			artifact_last_error="Could not create artifact directory: ${output_parent}"
			return "${EX_ENV}"
		fi
	fi

	if [[ -z "${error_message}" ]]; then
		if temporary_file="$(mktemp -- "${output_file}.tmp.XXXXXXXX")"; then
			:
		else
			error_code="${?}"
			error_message='Failed to write temporary artifact file'
		fi
	fi

	if [[ -z "${error_message}" ]]; then
		if "${writer}" "${@}" >| "${temporary_file}"; then
			:
		else
			error_code="${?}"

			if [[ -n "${artifact_last_error}" ]]; then
				error_message="Artifact-producing command (${writer}) failed with error code ${error_code}: ${artifact_last_error}"
			else
				error_message="Artifact-producing command failed with error code ${error_code}: ${writer}"
			fi
		fi
	fi

	if [[ -z "${error_message}" ]]; then
		if mv --no-target-directory -- "${temporary_file}" "${output_file}"; then
			:
		else
			error_code="${?}"
			error_message='Failed to move temporary artifact into place'
		fi
	fi

	if [[ -n "${error_message}" ]]; then
		rm -f -- "${temporary_file}" || true

		primary_error="${error_message}"

		if artifact_mark_failed "${scope}" "${path}" "${primary_error}" "${producer}"; then
			artifact_last_error="${primary_error}"
		else
			registry_error="${artifact_last_error}"
			artifact_last_error="${primary_error}; additionally failed to record artifact failure: ${registry_error}"
		fi

		case "${scope}" in
			('run')
				return "${EX_INV_METADATA}"
				;;
			('destination')
				return "${EX_COPY_FILES}"
				;;
			(*)
				return "${EX_INTERNAL}"
				;;
		esac
	fi

	if artifact_mark_created "${scope}" "${path}" "${producer}"; then
		return "${EX_OK}"
	else
		return "${?}"
	fi
}

# Usage: write_artifact_or_exit <exit_code> <error_context> <scope> <output_file> <command> [args...]
write_artifact_or_exit() {
	if [[ "${#}" -lt '5' ]]; then
		fatal_exit "${EX_USAGE}" "Usage: write_artifact_or_exit <exit_code> <error_context> <scope> <output_file> <command> [args...]"
	fi

	local exit_code="${1}"
	local error_context="${2}"
	local producer="${FUNCNAME[1]:-main}"

	shift 2

	if write_artifact_atomically "${producer}" "${@}"; then
		return 0
	fi

	fatal_exit "${exit_code}" "${error_context}: ${artifact_last_error}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  16. INVENTORY STAGE                                                   #
#==============================================================================#

# ------------------------------------------------------------ #
# region 16.1. Source object-list generation                   #
# ------------------------------------------------------------ #

# TO-DO: Make user confirm the directories are correct (unless a --force flag, or similar, is specified)

inventory_write_file_list_nul() {
	find "${inventory_find_args[@]}" -type f -print0 | sort -z
}

inventory_write_file_list_text() {
	local path

	while IFS= read -r -d '' path; do
		printf '%s\n' "$(json_escape "${path}")"
	done < "${run_dir}/source.files.null"
}

inventory_write_directory_list_nul() {
	find "${inventory_find_args[@]}" -type d -print0 | sort -z
}

inventory_write_directory_list_text() {
	local path

	while IFS= read -r -d '' path; do
		printf '%s\n' "$(json_escape "${path}")"
	done < "${run_dir}/source.directories.null"
}

inventory_write_symlink_list_nul() {
	find "${inventory_find_args[@]}" -type l -print0 | sort -z
}

inventory_write_symlink_list_text() {
	local path

	while IFS= read -r -d '' path; do
		printf '%s\n' "$(json_escape "${path}")"
	done < "${run_dir}/source.symlinks.null"
}

inventory_write_object_list_nul() {
	find "${inventory_find_args[@]}" -print0 | sort -z
}

inventory_write_object_list_nul_for_root() {
	local root="${1}"

	(
		if ! cd -- "${root}"; then return "${EX_ENV}"; fi
		find . -mindepth 1 -print0 | sort -z
	)
}

inventory_write_object_list_text() {
	local path

	while IFS= read -r -d '' path; do
		printf '%s\n' "$(json_escape "${path}")"
	done < "${run_dir}/source.all.null"
}

inventory_write_object_lists() {
	log_debug 'Generating file lists'

	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate source file list' \
		'run' 'source.files.null' 'inventory_write_file_list_nul'
	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate textual source file list' \
		'run' 'source.files.txt' 'inventory_write_file_list_text'
	inventory_file_count="$(count_nul_records "${run_dir}/source.files.null")"

	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate source directory list' \
		'run' 'source.directories.null' 'inventory_write_directory_list_nul'
	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate textual source directory list' \
		'run' 'source.directories.txt' 'inventory_write_directory_list_text'
	inventory_directory_count="$(count_nul_records "${run_dir}/source.directories.null")"

	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate source symlink list' \
		'run' 'source.symlinks.null' 'inventory_write_symlink_list_nul'
	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate textual source symlink list' \
		'run' 'source.symlinks.txt' 'inventory_write_symlink_list_text'
	inventory_symlink_count="$(count_nul_records "${run_dir}/source.symlinks.null")"

	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate complete source list' \
		'run' 'source.all.null' 'inventory_write_object_list_nul'
	write_artifact_or_exit "${EX_INV_LIST}" 'Failed to generate complete textual source list' \
		'run' 'source.all.txt' 'inventory_write_object_list_text'
	inventory_object_count="$(count_nul_records "${run_dir}/source.all.null")"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.2. Inventory policy validation                     #
# ------------------------------------------------------------ #

inventory_require_non_empty_source() {
	if [[ "${inventory_object_count}" -eq 0 ]]; then
		if [[ "${allow_empty}" == 'true' ]]; then
			log_warning 'Inventory is empty; continuing because --allow-empty is enabled'
		else
			fatal_exit "${EX_INV_LIST}" 'Inventory is empty; aborting'
		fi
	fi
}

inventory_validate_list_counts() {
	local expected
	local actual

	expected="${inventory_file_count}"
	actual="$(count_nul_records "${run_dir}/source.files.null")"

	if [[ "${expected}" -ne "${actual}" ]]; then
		fatal_exit "${EX_INV_LIST}" \
			'File-list count changed after generation'
	fi

	expected="${inventory_object_count}"
	actual="$(count_nul_records "${run_dir}/source.all.null")"
	if [[ "${expected}" -ne "${actual}" ]]; then
		fatal_exit "${EX_INV_LIST}" \
			'Object-list count changed after generation'
	fi
}

inventory_validate_object_types() {
	local inventory_dir="${1}"
	local relative_path
	local absolute_path
	local type

	while IFS= read -r -d '' relative_path; do
		absolute_path="${source_dir}/${relative_path#./}"
		type="$(get_filesystem_object_type "${absolute_path}")"

		case "${type}" in
			('file' | 'directory' | 'symlink')
				;;
			(*)
				fatal_exit "${EX_CONFIG}" \
					"Unsupported filesystem object: ${absolute_path} (${type})"
				;;
		esac
	done < "${inventory_dir}/source.all.null"
}

inventory_validate_symlink_policy() {
	local symlink_count

	symlink_count="${inventory_symlink_count}"

	if [[ "${symlink_mode}" == 'reject' &&
		"${symlink_count}" -gt 0 ]]; then
		fatal_exit "${EX_CONFIG}" \
			"Source contains ${symlink_count} symbolic link(s), but symlink mode is reject"
	fi

	if [[ "${symlink_mode}" == 'dereference' ]]; then
		local symlink
		while IFS= read -r -d '' symlink; do
			if [[ ! -e "${source_dir}/${symlink#./}" ]]; then
				fatal_exit "${EX_CONFIG}" \
					"Cannot dereference dangling symbolic link: ${symlink}"
			fi
		done < "${run_dir}/source.symlinks.null"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.3. Canonical manifest encoding                     #
# ------------------------------------------------------------ #

# Globals:
#   LC_ALL=C
#
# Arguments:
#   string
#
# Outputs:
#   Uppercase hexadecimal representation of the string bytes
encode_hex() {
	if [[ "${#}" -ne '1' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local string="${1}"
	local output=''
	local character=''
	local byte_value=''
	local index

	for ((index = 0; index < ${#string}; index++)); do
		character="${string:index:1}"

		if printf -v byte_value '%d' "'${character}"; then
			:
		else
			artifact_last_error="Failed to encode character at byte offset ${index}"
			return "${EX_INTERNAL}"
		fi

		printf -v output '%s%02X' "${output}" "${byte_value}"
	done

	printf '%s\n' "${output}"
}

get_hardlink_metadata() {
	if [[ "${#}" -ne '1' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local path="${1}"

	if stat --format='%d %i %h' -- "${path}"; then
		return 0
	else
		local rc="${?}"
		artifact_last_error="Failed to collect hard-link metadata: ${path}"
		return "${rc}"
	fi
}

get_manifest_stat_values() {
	if [[ "${#}" -ne '1' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local path="${1}"
	local stat_output=''

	# GNU stat:
	# %a = numeric mode
	# %u = numeric UID
	# %g = numeric GID
	# %s = size
	# %Y = modification time in epoch seconds
	if stat_output="$(stat --format='%a %u %g %s %Y' -- "${path}")"; then
		printf '%s\n' "${stat_output}"
		return 0
	else
		local rc="${?}"
		artifact_last_error="Failed to stat path: ${path}"
		return "${rc}"
	fi
}

hash_file_sha256() {
	if [[ "${#}" -ne '1' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local path="${1}"
	local hash_output=''

	if IFS=' ' read -r -d '' hash_output _ < <(
		sha256sum --zero -- "${path}"
	); then
		printf '%s\n' "${hash_output}"
		return 0
	fi

	local rc="${?}"
	artifact_last_error="Failed to hash file: ${path}"
	return "${rc}"
}

# Usage:
#   read_symlink_target_nul <result_variable> <symlink_path>
#
# Reads a symlink target without command substitution, preserving embedded
# and trailing newline characters. The result variable receives the target
# without its terminating NUL byte.
#
# Requires GNU readlink with --zero support.
read_symlink_target_nul() {
	if [[ "${#}" -ne '2' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local -n result_variable="${1}"
	local symlink_path="${2}"
	local rc

	result_variable=''
	artifact_last_error=''

	if [[ ! -L "${symlink_path}" ]]; then
		artifact_last_error="Path is not a symbolic link: ${symlink_path}"
		return "${EX_CONFIG}"
	fi

	# readlink --zero emits the target followed by NUL. Bash read with
	# -d '' reads through the NUL and preserves all preceding newlines.
	#
	# Process substitution avoids command substitution, whose newline
	# trimming would corrupt a target ending in one or more newlines.
	if IFS= read -r -d '' \
		 'result_variable' < <(readlink --zero -- "${symlink_path}"); then
		return 0
	else
		rc="${?}"
		artifact_last_error="Failed to read symbolic-link target: ${symlink_path}"
		return "${rc}"
	fi
}

# Usage:
#   build_object_manifest_record <result_variable> <source_root> <absolute_path>
#
# The result variable receives one canonical tab-separated metadata record.
# No files are created and nothing is written to stdout.
#
# Record format:
#   type<TAB>encoded-relative-path<TAB>mode<TAB>uid<TAB>gid<TAB>size<TAB>mtime<TAB>sha256<TAB>encoded-target<TAB>hardlink-id
build_object_manifest_record() {
	if [[ "${#}" -ne '3' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local -n result_variable="${1}"
	local source_root="${2}"
	local absolute_path="${3}"

	local type=''
	local relative_path=''
	local encoded_path=''
	local mode=''
	local uid=''
	local gid=''
	local size=''
	local mtime=''
	local sha256='-'
	local encoded_target='-'
	local target=''
	local stat_output=''
	local device=''
	local inode=''
	local link_count=''
	local hardlink_id=''

	local rc

	result_variable=''
	artifact_last_error=''

	if [[ ! -d "${source_root}" ]]; then
		artifact_last_error="Source root is not a directory: ${source_root}"
		return "${EX_ENV}"
	fi

	if [[ ! "${source_root}" =~ ^/ ]]; then
		artifact_last_error="Source root is not absolute: ${source_root}"
		return "${EX_INTERNAL}"
	fi

	if [[ ! "${absolute_path}" =~ ^/ ]]; then
		artifact_last_error="Manifest path is not absolute: ${absolute_path}"
		return "${EX_INTERNAL}"
	fi

	# The source list excludes the source root itself. Rejecting it here
	# prevents an empty relative path from entering the manifest.
	if [[ "${absolute_path}" == "${source_root}" ]]; then
		artifact_last_error="Manifest path is the source root, not a child: ${absolute_path}"
		return "${EX_INTERNAL}"
	fi

	# The trailing slash in the pattern prevents /source2 from being
	# mistaken for a child of /source.
	case "${absolute_path}" in
		("${source_root}"/*)
			relative_path="${absolute_path#"${source_root}"/}"
			;;
		(*)
			artifact_last_error="Path is outside source root: ${absolute_path}"
			return "${EX_INTERNAL}"
			;;
	esac

	if [[ -z "${relative_path}" ]]; then
		artifact_last_error="Relative manifest path is empty: ${absolute_path}"
		return "${EX_INTERNAL}"
	fi

	if encoded_path="$(encode_hex "${relative_path}")"; then
		:
	else
		rc="${?}"
		artifact_last_error="Failed to encode relative path: ${relative_path}"
		return "${rc}"
	fi

	if type="$(get_filesystem_object_type "${absolute_path}")"; then
		:
	else
		rc="${?}"
		artifact_last_error="Failed to determine object type for ${absolute_path}: ${artifact_last_error}"
		return "${rc}"
	fi

	if [[ "${type}" == 'other' ]]; then
		artifact_last_error="Unsupported filesystem object type: ${absolute_path}"
		return "${EX_INV_METADATA}"
	fi

	if stat_output="$(get_manifest_stat_values "${absolute_path}")"; then
		:
	else
		rc="${?}"
		artifact_last_error="Failed to collect stat metadata for ${absolute_path}: ${artifact_last_error}"
		return "${rc}"
	fi

	if read -r mode uid gid size mtime <<< "${stat_output}"; then
		:
	else
		artifact_last_error="Could not parse stat metadata for: ${absolute_path}"
		return "${EX_INTERNAL}"
	fi

	case "${type}" in
		('file')
			if sha256="$(hash_file_sha256 "${absolute_path}")"; then
				:
			else
				rc="${?}"
				artifact_last_error="Failed to hash regular file ${absolute_path}: ${artifact_last_error}"
				return "${rc}"
			fi

			if [[ "${type}" == 'file' ]]; then
				if read -r device inode link_count < <(
					get_hardlink_metadata "${absolute_path}"
				); then
					:
				else
					rc="${?}"
					artifact_last_error="Failed to collect hard-link identity: ${absolute_path}"
					return "${rc}"
				fi

				if [[ "${link_count}" -gt 1 ]]; then
					hardlink_id="${device}:${inode}"
				fi
			fi
			;;

		('symlink')
			# This records the link itself rather than the object to which
			# it points. readlink does not dereference the symlink.
			if read_symlink_target_nul 'target' "${absolute_path}"; then
				:
			else
				rc="${?}"
				artifact_last_error="Failed to read symlink target ${absolute_path}"
				return "${rc}"
			fi

			if encoded_target="$(encode_hex "${target}")"; then
				:
			else
				rc="${?}"
				artifact_last_error="Failed to encode symlink target ${absolute_path}"
				return "${rc}"
			fi
			;;

		('directory' | 'fifo' | 'socket' | 'block-device' | 'character-device')
			# These object types have no content hash or symlink target.
			;;

		(*)
			artifact_last_error="Unhandled filesystem object type '${type}' for ${absolute_path}"
			return "${EX_INTERNAL}"
			;;
	esac

	result_variable="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"${type}" \
		"${encoded_path}" \
		"${mode}" \
		"${uid}" \
		"${gid}" \
		"${size}" \
		"${mtime}" \
		"${sha256}" \
		"${encoded_target}" \
		"${hardlink_id}")"

	return 0
}

# Usage:
#   build_object_manifest <source_root> <null_path_list>
#
# Writes the canonical metadata manifest to stdout.
# Does not create files.
build_object_manifest() {
	if [[ "${#}" -ne '2' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local source_root="${1}"
	local null_path_list="${2}"

	local relative_path=''
	local absolute_path=''
	local record=''
	local rc
	local sort_rc
	local printf_rc
	local -a records=()

	artifact_last_error=''

	if [[ ! -d "${source_root}" ]]; then
		artifact_last_error="Source root is not a directory: ${source_root}"
		return "${EX_ENV}"
	fi

	if [[ ! -r "${null_path_list}" ]]; then
		artifact_last_error="Source path list is not readable: ${null_path_list}"
		return "${EX_INV_LIST}"
	fi

	# The null list contains paths relative to the source directory,
	# normally beginning with "./".
	while IFS= read -r -d '' relative_path; do
		absolute_path="${source_root}/${relative_path#./}"

		if build_object_manifest_record \
			'record' \
			"${source_root}" \
			"${absolute_path}"; then
			records+=("${record}")
		else
			rc="${?}"
			artifact_last_error="Failed to collect metadata for ${absolute_path}: ${artifact_last_error}"
			return "${rc}"
		fi
	done < "${null_path_list}"

	# An empty source directory produces an empty manifest.
	if [[ "${#records[@]}" -eq 0 ]]; then
		return 0
	fi

	local -a pipeline_status=()

	printf '%s\n' "${records[@]}" |
		LC_ALL=C sort --field-separator=$'\t' --key=2,2
	pipeline_status=("${PIPESTATUS[@]}")

	if [[ "${pipeline_status[0]}" -ne 0 ]]; then
		artifact_last_error='Failed to write metadata records to sort'
		return "${pipeline_status[0]}"
	fi

	if [[ "${pipeline_status[1]}" -ne 0 ]]; then
		artifact_last_error='Failed to sort canonical metadata records'
		return "${pipeline_status[1]}"
	fi

	return 0
}

inventory_write_source_object_manifest() {
	local output_path='source.objects.tsv'
	local null_path_list="${run_dir}/source.all.null"

	write_artifact_or_exit \
		"${EX_INV_METADATA}" \
		'Failed to generate canonical source metadata manifest' \
		'run' \
		"${output_path}" \
		'build_object_manifest' \
		"${source_dir}" \
		"${null_path_list}"

	objects_manifest_file="${run_dir}/${output_path}"
	log_info "Canonical source metadata manifest written: ${objects_manifest_file}"
	return 0
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.4. Source filesystem diagnostics                   #
# ------------------------------------------------------------ #

write_filesystem_usage_metadata() {
	df -- "${source_dir}" "${destination_dir}"
	df -h -- "${source_dir}" "${destination_dir}"
}

collect_pre_transfer_disk_usage() {
	log_info "Getting current disk usage of both directories’ volumes..."
	write_artifact_or_exit "${EX_INV_METADATA}" 'Failed to collect pre-copy filesystem usage' \
		'run' 'df.before.txt' 'write_filesystem_usage_metadata'
	log_info 'Disk usage collected'
}

inventory_write_source_identity() {
	printf '%s\0' "${source_dir}"
}

inventory_write_config() {
	# shellcheck disable=SC2312
	cat <<EOF
{
  "schema_version": ${inventory_config_schema_version},
  "source_dir": $(json_string_or_null "${source_dir}"),
  "symlink_mode": $(json_string_or_null "${symlink_mode}"),
  "hardlink_mode": $(json_string_or_null "${hardlink_mode}"),
  "allow_empty": $(json_bool "${allow_empty}"),
  "copy_special_objects_policy": $(json_bool "${copy_special_objects_policy}"),
  "inventory_find_args": [$(json_string_array inventory_find_args)],
  "hash_algorithms": ["sha256", "sha512"],
  "created_at": $(json_string_or_null "$(get_current_timestamp)")
}
EOF
}

inventory_write_source_metadata() {
	write_artifact_or_exit \
		"${EX_INV_METADATA}" \
		'Failed to record inventory source path' \
		'run' \
		'inventory.source.path.null' \
		'inventory_write_source_identity'

	write_artifact_or_exit \
		"${EX_INV_METADATA}" \
		'Failed to save inventory configuration' \
		'run' \
		'inventory.config.json' \
		'inventory_write_config'

	write_artifact_or_exit \
		"${EX_INV_METADATA}" \
		'Failed to collect source-root stat metadata' \
		'run' \
		'source.root.stat.txt' \
		'stat' '--' "${source_dir}"
}

# inventory_collect_source_parent_metadata() {
# 	(
# 		local option

# 		log_debug 'Changing directory to parent directory in subshell'
# 		cd_or_die .. "${EX_ENV}" 'Failed to enter parent directory'
# 		log_info 'Collecting information for all files and folders in parent directory...'
# 		for option in u "" c; do
# 			ls -AisZ"${option}" --full-time --author --classify=always . > "${run_dir}/source.parent.ls.${option:-m}time.txt"
# 			ls -AisZ"${option}"n --full-time --author --classify=always . > "${run_dir}/source.parent.ls.${option:-m}time_n.txt"
# 		done
# 		du -a -d 1 > "${run_dir}/source.du.txt"
# 		if [[ "${capability_eza}" == 'true' ]]; then
# 			eza -lahgHiBSoO --classify=always --time-style=full-iso --total-size . > "${run_dir}/source.parent.eza.txt"
# 		else
# 			log_warning 'eza not found; skipping eza output'
# 		fi
# 		log_info 'Parent directory information collected'
# 	)
# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.5. ls diagnostics                                  #
# ------------------------------------------------------------ #

# base_ls_cmd=(
# 	ls
# 	--almost-all		# -A
# 	--author
# 	--classify=always
# 	--full-time
# 	--hyperlink=never
# 	--inode				# -i
# 	--size				# -s
# 	--context			# -Z
# )
#
#

inventory_write_ls_metadata() {
	if [[ "${#}" -lt '3' || "${#}" -gt '5' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local numeric="${1}"
	local time_option="${2}"
	local restricted="${3}"
	local directory="${4:-"${source_dir}"}"
	local null_source_file="${5:-"${run_dir}/source.all.null"}"

	local file
	local -a ls_cmd=()

	case "${numeric}" in
		('true' | 'false')
			;;
		(*)
			artifact_last_error="Invalid numeric flag: ${numeric}"
			return "${EX_USAGE}"
			;;
	esac

	case "${time_option}" in
		('' | 'u' | 'c')
			;;
		(*)
			artifact_last_error="Invalid ls time option: ${time_option}"
			return "${EX_USAGE}"
			;;
	esac

	case "${restricted}" in
		('true' | 'false')
			;;
		(*)
			artifact_last_error="Invalid restricted flag: ${restricted}"
			return "${EX_USAGE}"
			;;
	esac

	ls_cmd=("${base_ls_cmd[@]}")

	if [[ "${numeric}" == 'true' ]]; then
		ls_cmd+=('--numeric-uid-gid')
	fi

	if [[ -n "${time_option}" ]]; then
		ls_cmd+=("-${time_option}")
	fi

	if [[ "${restricted}" == "true" ]]; then
		if [[ ! -r "${null_source_file}" ]]; then
			artifact_last_error="Could not read source inventory: ${null_source_file}"
			return "${EX_INV_METADATA}"
		fi

		ls_cmd+=('--directory')

		while IFS= read -r -d '' file; do
			if "${ls_cmd[@]}" -- "${file}"; then
				:
			else
				return "${?}"
			fi
		done < "${null_source_file}"

		return 0
	fi

	ls_cmd+=('--recursive')

	(
		if cd -- "${directory}"; then :; else return "${?}"; fi
		"${ls_cmd[@]}" -- .
	)
}

inventory_collect_ls_metadata() {
	local numeric
	local time_option
	local time_name
	local numeric_suffix
	local output_path
	local restricted='false'

	if [[ "${#inventory_find_args[@]}" -gt "${inventory_find_args_base_count}" ]]; then
		restricted='true'
	fi

	log_info 'Collecting ls information for files and folders in the source directory'

	for numeric in 'false' 'true'; do
		numeric_suffix=''

		if [[ "${numeric}" == "true" ]]; then
			numeric_suffix='.numeric'
		fi

		for time_option in 'u' '' 'c'; do
			time_name="${time_option:-m}time"

			output_path="source.metadata.ls.${time_name}${numeric_suffix}.txt"

			write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect ls metadata: ${output_path}" \
				'run' "${output_path}" \
				'inventory_write_ls_metadata' "${numeric}" "${time_option}" "${restricted}"
		done
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.6. eza diagnostics                                 #
# ------------------------------------------------------------ #

# base_eza_cmd=(
# 	eza
# 	--color=never
# 	--icons=never
# 	--hyperlink=never
# 	--long # -l
# 	--classify=always
# 	--all                 # -a
# 	--inode               # -i
# 	--octal-permissions   # -o
# 	--links               # -H
# 	--bytes               # -B
# 	--total-size          #
# 	--blocksize           # -S
# 	--group               # -g
# 	--flags               # -O
# 	--modified            # -m
# 	--changed             #
# 	--created             # -U
# 	--accessed            # -u
# 	--time-style=full-iso # '+%Y-%m-%dT%H:%M:%S%:z'
# 	--context             # -Z
# 	--extended            # -@
# )

inventory_write_eza_metadata() {
	if [[ "${#}" -lt '2' || "${#}" -gt '4' ]]; then
		artifact_last_error="Invalid arguments for ${FUNCNAME[0]}"
		return "${EX_USAGE}"
	fi

	local numeric="${1}"
	local restricted="${2}"
	local directory="${3:-"${source_dir}"}"
	local null_source_file="${4:-"${run_dir}/source.all.null"}"

	local file
	local first='true'
	local -a eza_cmd=()
	local -a current_eza_cmd=()

	case "${numeric}" in
		('true' | 'false')
			;;
		(*)
			artifact_last_error="Invalid numeric flag: ${numeric}"
			return "${EX_USAGE}"
			;;
	esac

	case "${restricted}" in
		('true' | 'false')
			;;
		(*)
			artifact_last_error="Invalid restricted flag: ${restricted}"
			return "${EX_USAGE}"
			;;
	esac

	eza_cmd=("${base_eza_cmd[@]}")

	if [[ "${numeric}" == 'true' ]]; then
		eza_cmd+=('--numeric')
	fi

	if [[ "${restricted}" == "true" ]]; then
		if [[ ! -r "${null_source_file}" ]]; then
			artifact_last_error="Could not read source inventory: ${null_source_file}"
			return "${EX_INV_METADATA}"
		fi

		eza_cmd+=('--treat-dirs-as-files')

		while IFS= read -r -d '' file; do
			current_eza_cmd=("${eza_cmd[@]}")

			if [[ "${first}" == "true" ]]; then
				current_eza_cmd+=('--header')
				first='false'
			fi

			if "${current_eza_cmd[@]}" -- "${file}"; then
				:
			else
				return "${?}"
			fi
		done < "${null_source_file}"

		return 0
	fi

	current_eza_cmd=("${eza_cmd[@]}" '--header' '--tree')

	(
		if cd -- "${directory}"; then :; else return "${?}"; fi
		"${current_eza_cmd[@]}" -- .
	)
}

inventory_collect_eza_metadata() {
	if [[ "${capability[eza]}" == 'false' ]]; then
		log_warning 'eza not found; skipping eza output'
		return 0
	fi

	local numeric
	local numeric_suffix
	local output_path
	local restricted='false'

	if [[ "${#inventory_find_args[@]}" -gt "${inventory_find_args_base_count}" ]]; then
		restricted='true'
	fi

	log_info 'Collecting eza information for files and folders in the source directory'

	for numeric in 'false' 'true'; do
		numeric_suffix=''

		if [[ "${numeric}" == 'true' ]]; then
			numeric_suffix='.numeric'
		fi

		output_path="source.metadata.eza${numeric_suffix}.txt"

		write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect eza metadata: ${output_path}" \
			'run' "${output_path}" \
			'inventory_write_eza_metadata' "${numeric}" "${restricted}"
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.7. Extended attributes and symlink diagnostics     #
# ------------------------------------------------------------ #

inventory_write_extended_attributes() {
	local file

	while IFS= read -r -d '' file; do
		getfattr -d --absolute-names "${file}" 2> /dev/null
	done < "${run_dir}/source.all.null"
}

inventory_collect_extended_attributes() {
	if [[ "${capability[getfattr]}" == 'false' ]]; then
		log_warning 'getfattr not found; skipping extended attributes collection'
		return 0
	fi

	write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect extended attributes metadata" \
		'run' 'source.metadata.getfattr.txt' 'inventory_write_extended_attributes'

	log_info 'Extended attributes collection completed'
}

inventory_write_symlink_metadata() {
	local symlink

	while IFS= read -r -d '' symlink; do
		ls -l "${symlink}"
		readlink -v "${symlink}" 2> /dev/null
	done < "${run_dir}/source.symlinks.null"
}

inventory_collect_symlink_metadata() {
	write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect symlink metadata" \
		'run' 'source.metadata.readlink.txt' 'inventory_write_symlink_metadata'
	
	log_info 'Symlink info collection completed'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.8. stat and du diagnostics                         #
# ------------------------------------------------------------ #

inventory_write_stat_metadata() {
	while IFS= read -r -d '' file; do
		stat "${file}"
	done < "${run_dir}/source.all.null"
}

inventory_collect_stat_metadata() {
	write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect stat metadata" \
		'run' 'source.metadata.stat.txt' 'inventory_write_stat_metadata'
}

inventory_write_disk_usage_metadata() {
	(
		if ! cd -- "${source_dir}"; then
			return "${EX_ENV}"
		fi

		du -a -- .
	)
}

inventory_collect_disk_usage_metadata() {
	write_artifact_or_exit "${EX_INV_METADATA}" "Failed to collect du metadata" \
		'run' 'source.metadata.du.txt' 'inventory_write_disk_usage_metadata'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.9. Inventory metadata orchestration                #
# ------------------------------------------------------------ #

inventory_collect_metadata() {
	inventory_collect_ls_metadata
	inventory_collect_eza_metadata
	inventory_collect_extended_attributes
	inventory_collect_symlink_metadata
	inventory_collect_stat_metadata
	inventory_collect_disk_usage_metadata

	log_info 'File information collection completed'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 16.10. Inventory completion                           #
# ------------------------------------------------------------ #

inventory_write_completion_marker() {
	printf '%s\n' \
		"completed_at=$(get_current_timestamp)" \
		"source=${source_dir}" \
		"objects=${inventory_object_count}" \
		"files=${inventory_file_count}" \
		"directories=${inventory_directory_count}" \
		"symlinks=${inventory_symlink_count}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  17. HASHING AND RUN-MANIFEST GENERATION                               #
#==============================================================================#

# ------------------------------------------------------------ #
# region 17.1. Source-file hashing                             #
# ------------------------------------------------------------ #

hash_file() {
	local alg="${1}"
	local file="${2}"

	case "${alg}" in
		(sha256)
			sha256sum --zero -- "${file}"
			;;
		(sha512)
			sha512sum --zero -- "${file}"
			;;
		(*)
			fatal_exit "${EX_INV_HASH}" "Unsupported hash algorithm: ${alg}"
			;;
	esac
}

inventory_write_source_hashes() {
	local alg="${1}"
	local file

	while IFS= read -r -d '' file; do
		hash_file "${alg}" "${file}"
	done < "${run_dir}/source.files.null"
}

inventory_hash_source_files() {
	local alg

	for alg in 'sha256' 'sha512'; do
		log_info "Generating ${alg} checksums for all files..."

		write_artifact_or_exit "${EX_INV_HASH}" "Failed to generate ${alg} hashes" \
			'run' "source.files.${alg}" 'inventory_write_source_hashes' "${alg}"

		log_info "${alg} checksums generation completed"
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 17.2. Run-artifact hashing                            #
# ------------------------------------------------------------ #

run_artifact_input_files() {
	(
		if ! cd -- "${run_dir}"; then return "${EX_ENV}"; fi

		find . \
			-mindepth 1 \
			-maxdepth 1 \
			-type f \
			! -name '*.tmp.*' \
			! -name 'MANIFEST.sha256' \
			! -name 'MANIFEST.sha512' \
			! -name 'MANIFEST.sha256.*' \
			! -name 'MANIFEST.sha512.*' \
			! -name 'artifacts.stat.txt' \
			! -name 'artifacts.files.null' \
			-print0 |
			sort -z
		)
}

write_run_artifact_stat_manifest() {
	local input_list="${1}"
	local file

	(
		if ! cd -- "${run_dir}"; then
			return "${EX_ENV}";
		fi

		while IFS= read -r -d '' file; do
			if ! stat -- "${file}"; then
				return "${EX_INV_MANIFEST}";
			fi
		done < "${input_list}"
	)
}

write_run_artifact_hash_manifest() {
	local alg="${1}"
	local input_list="${2}"
	local file

	case "${alg}" in
		('sha256' | 'sha512')
			;;
		(*)
			return "${EX_USAGE}"
			;;
	esac

	(
		if ! cd -- "${run_dir}"; then
			return "${EX_ENV}";
		fi

		while IFS= read -r -d '' file; do
			if ! "${alg}sum" --zero -- "${file}"; then
				return "${EX_INV_MANIFEST}";
			fi
		done < "${input_list}"
	)
}

write_run_artifact_manifests() {
	local input_list="${run_dir}/artifacts.files.null"

	write_artifact_or_exit \
		"${EX_INV_MANIFEST}" \
		'Failed to enumerate run artifacts' \
		'run' \
		'artifacts.files.null' \
		'run_artifact_input_files'

	write_artifact_or_exit \
		"${EX_INV_MANIFEST}" \
		'Failed to write artifact stat manifest' \
		'run' \
		'artifacts.stat.txt' \
		'write_run_artifact_stat_manifest' \
		"${input_list}"

	for alg in sha256 sha512; do
		write_artifact_or_exit \
			"${EX_INV_MANIFEST}" \
			"Failed to write ${alg} artifact manifest" \
			'run' \
			"MANIFEST.${alg}" \
			'write_run_artifact_hash_manifest' \
			"${alg}" \
			"${input_list}"
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  18. SIGNING                                                           #
#==============================================================================#

# ------------------------------------------------------------ #
# region 18.1. Signing identity and metadata                   #
# ------------------------------------------------------------ #

get_signing_identity_label() {
	case "${signer_command}" in
		(sq)
			if [[ -n "${sq_signer}" ]]; then
				printf '%s\n' "${sq_signer}"
			elif [[ -n "${sq_signer_email}" ]]; then
				printf '%s\n' "${sq_signer_email}"
			elif [[ -n "${sq_signer_file}" ]]; then
				printf '%s\n' "${sq_signer_file}"
			elif [[ -n "${sq_signer_userid}" ]]; then
				printf '%s\n' "${sq_signer_userid}"
			else
				printf '%s\n' 'default'
			fi
			;;
		(gpg)
			printf '%s\n' "${gpg_local_user:-default}"
			;;
		(ssh-keygen)
			printf '%s\n' "${ssh_keygen_signing_key_file}"
			;;
		(minisign)
			printf '%s\n' "${minisign_secret_key_file:-default}"
			;;
		(*)
			printf '%s\n' 'unknown'
			;;
	esac
}

write_signing_metadata() {
	printf '%s\n' "signer=${signer_command}"
	printf '%s\n' "version=${signer_command_version}"
	printf '%s\n' "identity=$(get_signing_identity_label)"
	printf '%s\n' "namespace=${FSC_SCRIPT_NAME}"
	printf '%s\n' "timestamp=$(get_current_timestamp)"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 18.2. Sequoia signing                                 #
# ------------------------------------------------------------ #

sign_hash_manifest_with_sq() {
	local manifest_file="${1}"
	local manifest_signed="${manifest_file}.sig"
	local -a sq_sign_cmd=()

	sq_sign_cmd=(sq sign)
	if [[ -n "${sq_signer}" ]]; then
		sq_sign_cmd+=(--signer "${sq_signer}")
	elif [[ -n "${sq_signer_email}" ]]; then
		sq_sign_cmd+=(--signer-email "${sq_signer_email}")
	elif [[ -n "${sq_signer_file}" ]]; then
		sq_sign_cmd+=(--signer-file "${sq_signer_file}")
	elif [[ -n "${sq_signer_userid}" ]]; then
		sq_sign_cmd+=(--signer-userid "${sq_signer_userid}")
	else
		sq_sign_cmd+=(--signer-self)
	fi

	sq_sign_cmd+=(--signature-file "${manifest_signed}" -- "${manifest_file}")

	log_debug "Attempting to sign ${manifest_file} with command: ${sq_sign_cmd[*]}"
	"${sq_sign_cmd[@]}"
	log_notice "Signed manifest artifact with sq: ${manifest_signed}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 18.3. GnuPG signing                                   #
# ------------------------------------------------------------ #

sign_hash_manifest_with_gpg() {
	local manifest_file="${1}"
	local manifest_signed="${manifest_file}.asc"
	local -a gpg_sign_cmd=()

	gpg_sign_cmd=(gpg --batch --yes --armor --detach-sign
		--comment "Signature for $(basename "${manifest_file}") created by ${FSC_SCRIPT_NAME} on $(get_current_timestamp)"
		--output "${manifest_signed}")

	if [[ -n "${gpg_local_user}" ]]; then
		gpg_sign_cmd+=(--local-user "${gpg_local_user}")
	fi

	gpg_sign_cmd+=(-- "${manifest_file}")

	log_debug "Attempting to sign ${manifest_file} with command: ${gpg_sign_cmd[*]}"
	"${gpg_sign_cmd[@]}"
	log_notice "Signed manifest artifact with gpg: ${manifest_signed}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 18.4. ssh-keygen signing                              #
# ------------------------------------------------------------ #

write_ssh_signature() {
	local manifest_file="${1}"
	shift 1

	"${@}" < "${manifest_file}"
}

sign_hash_manifest_with_ssh_keygen() {
	local manifest_file="${1}"
	local manifest_signed="${manifest_file}.sig"
	local -a ssh_keygen_sign_cmd=()

	# ssh-keygen -Y sign -f key_file -n namespace file [-O option] ...
	ssh_keygen_sign_cmd=(ssh-keygen -Y sign -f "${ssh_keygen_signing_key_file}" -n "${FSC_SCRIPT_NAME}")

	log_debug "Attempting to sign ${manifest_file} with command: ${ssh_keygen_sign_cmd[*]}"
	write_artifact_or_exit "${EX_SIGN_FAILED}" "Signing with ssh-keygen failed" 'run' \
		"${manifest_signed}" 'write_ssh_signature' "${manifest_file}" "${ssh_keygen_sign_cmd[@]}"
	log_notice "Signed manifest artifact with ssh-keygen: ${manifest_signed}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 18.5. minisign signing                                #
# ------------------------------------------------------------ #

sign_hash_manifest_with_minisign() {
	local manifest_file="${1}"
	local manifest_signed="${manifest_file}.minisig"
	local -a minisign_sign_cmd=()

	# minisign -S [-l] [-x sig_file] [-s seckey_file] [-c untrusted_comment]
	#             [-t trusted_comment] -m file [file ...]
	minisign_sign_cmd=(minisign -S -x "${manifest_signed}")
	if [[ -n "${minisign_secret_key_file}" ]]; then minisign_sign_cmd+=(-s "${minisign_secret_key_file}"); fi
	minisign_sign_cmd+=(
		-t "Signature for $(basename "${manifest_file}") created by ${FSC_SCRIPT_NAME} on $(get_current_timestamp)"
		-m "${manifest_file}"
	)

	log_debug "Attempting to sign ${manifest_file} with command: ${minisign_sign_cmd[*]}"
	"${minisign_sign_cmd[@]}"
	log_notice "Signed manifest artifact with minisign: ${manifest_signed}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 18.6. Signing orchestration                           #
# ------------------------------------------------------------ #

inventory_sign_hash_manifests() {
	if [[ "${sign}" != 'true' ]]; then
		log_debug 'Signing not requested; skipping'
		return 0
	fi

	transition_phase 'inventory_sign'
	log_debug 'Signing manifest artifacts'

	local manifest_file

	for manifest_file in "${run_dir}/MANIFEST.sha256" "${run_dir}/MANIFEST.sha512"; do
        if [[ ! -f "${manifest_file}" ]]; then
            fatal_exit "${EX_SIGN_FAILED}" \
                "Manifest to sign is missing: ${manifest_file}"
        fi

		case "${signer_command}" in
			('sq' | 'gpg' | 'ssh-keygen' | 'minisign')
				"sign_hash_manifest_with_${signer_command/-/_}" "${manifest_file}"
				;;
			(*)
				fatal_exit "${EX_CONFIG}" "Unsupported signer: ${signer_command} (supported: sq, gpg, ssh-keygen, minisign)"
				;;
		esac
	done

	write_artifact_or_exit "${EX_INTERNAL}" 'Failed to save signing metadata' \
		'run' 'signing.meta.txt' 'write_signing_metadata'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  19. COPY STAGE                                                        #
#==============================================================================#

# ------------------------------------------------------------ #
# region 19.1. Copy preparation                                #
# ------------------------------------------------------------ #

get_copy_inventory_dir() {
	if [[ "${inventory_completed}" == 'true' ]]; then
		printf '%s\n' "${run_dir}"
	else
		printf '%s\n' "${inventory_run_dir}"
	fi
}

copy_plan_destination_artifacts() {
	local inventory_dir="${1}"
	local relative_path
	local artifact_path
	local rc

	while IFS= read -r -d '' relative_path; do
		artifact_path="${relative_path#./}"

		if artifact_plan 'destination' "${artifact_path}" 'copy_transfer_objects'; then
			:
		else
			rc="${?}"
			fatal_exit "${EX_COPY_PREP}" \
				"Could not plan destination artifact '${artifact_path}': ${artifact_last_error}"
		fi
	done < "${inventory_dir}/source.all.null"
}

copy_mark_destination_created() {
	local relative_path="${1}"
	local artifact_path="${relative_path#./}"

	if artifact_mark_created \
		'destination' \
		"${artifact_path}" \
		'copy_transfer_objects'; then
		return 0
	fi

	fatal_exit "${EX_COPY_FILES}" \
		"Could not record copied artifact '${artifact_path}': ${artifact_last_error}"
}

copy_mark_destination_failed() {
	local relative_path="${1}"
	local detail="${2}"
	local artifact_path="${relative_path#./}"

	if artifact_mark_failed \
		'destination' \
		"${artifact_path}" \
		"${detail}" \
		'copy_transfer_objects'; then
		return 0
	fi

	fatal_exit "${EX_INTERNAL}" \
		"Could not record failed artifact '${artifact_path}': ${artifact_last_error}"
}

assert_no_symlinked_destination_parent() {
    local path="${1}"
    local parent
    local current="${destination_dir}"
    local component
    local -a components=()

    parent="$(dirname -- "${relative_path}")"

    # A top-level path has no parent beneath destination_dir.
    [[ "${parent}" == '.' ]] && return 0

    IFS='/' read -r -a components <<< "${parent}"

    for component in "${components[@]}"; do
        [[ -n "${component}" ]] || continue
        current="${current}/${component}"

        if [[ -L "${current}" ]]; then
            fatal_exit "${EX_COPY_PREP}" \
                "Refusing to copy through destination symlink: ${current}"
        fi
    done
}

remove_existing_destination() {
    local destination_path="${1}"
    local expected_type="${2}"
    local actual_type

    if ! [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
		return 0
	fi

    if [[ "${FORCE}" != 'true' ]]; then
        fatal_exit "${EX_FORCE_REQUIRED}" \
            "Destination path already exists: ${destination_path}"
    fi

    actual_type="$(get_filesystem_object_type "${destination_path}")"

    if [[ "${actual_type}" != "${expected_type}" ]]; then
        fatal_exit "${EX_COPY_PREP}" \
            "Refusing destination type conflict at ${destination_path}: expected ${expected_type}, found ${actual_type}"
    fi

    case "${actual_type}" in
        ('file' | 'symlink')
            rm -- "${destination_path}"
            ;;
        ('directory')
            # Do not recursively remove a destination directory.
            fatal_exit "${EX_COPY_PREP}" \
                "Refusing to replace destination directory: ${destination_path}"
            ;;
        (*)
            fatal_exit "${EX_COPY_PREP}" \
                "Refusing to replace destination object: ${destination_path} (${actual_type})"
            ;;
    esac
}

# copy_prepare_source_lists() {

# }

# copy_validate_source_objects() {

# }

# copy_prepare_destination() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.2. Regular-file copying                            #
# ------------------------------------------------------------ #

copy_regular_file() {
	local source_path="${1}"
	local relative_path="${source_path#./}"
	local destination_path="${destination_dir}/${relative_path}"
	local device inode link_count identity first_destination

	remove_existing_destination "${destination_path}" 'file'

	if read -r device inode link_count < <(
		stat --format='%d %i %h' -- "${source_path}"
	); then
		:
	else
		fatal_exit "${EX_COPY_FILES}" \
			"Could not inspect regular file: ${source_path}"
	fi

	identity="${device}:${inode}"

	assert_no_symlinked_destination_parent "${relative_path}"
	mkdir --parents -- "$(dirname -- "${destination_path}")"

	if [[ "${hardlink_mode}" == 'reject' &&
		"${link_count}" -gt 1 ]]; then
		fatal_exit "${EX_COPY_FILES}" \
			"Hard-linked file encountered while hard-link mode is reject: ${source_path}"
	fi

	if [[ "${hardlink_mode}" == 'preserve' &&
		"${link_count}" -gt 1 &&
		-n "${first_hardlink_destination["${identity}"]:-}" ]]; then

		first_destination="${first_hardlink_destination["${identity}"]}"

		if [[ -e "${destination_path}" || -L "${destination_path}" ]]; then
			if [[ "${FORCE}" != 'true' ]]; then
				fatal_exit "${EX_FORCE_REQUIRED}" \
					"Destination path already exists: ${destination_path}"
			fi

			rm -rf -- "${destination_path}"
		fi

		if ! ln -- "${first_destination}" "${destination_path}"; then
			fatal_exit "${EX_COPY_FILES}" \
				"Could not recreate hard link: ${destination_path}"
		fi

		return
	fi

	if ! cp --preserve=all -- "${source_path}" "${destination_path}"; then
		fatal_exit "${EX_COPY_FILES}" \
			"Could not copy regular file: ${source_path}"
	fi

	if [[ "${hardlink_mode}" == 'preserve' &&
		"${link_count}" -gt 1 ]]; then
		first_hardlink_destination["${identity}"]="${destination_path}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.3. Symbolic-link copying                           #
# ------------------------------------------------------------ #

copy_symbolic_link() {
	local source_path="${1}"
	local relative_path="${source_path#./}"
	local destination_path="${destination_dir}/${relative_path}"
	local target

	assert_no_symlinked_destination_parent "${relative_path}"
	mkdir --parents -- "$(dirname -- "${destination_path}")"

	if [[ "${symlink_mode}" == reject ]]; then
		fatal_exit "${EX_COPY_SYMLINKS}" \
			"Symbolic link encountered while symlink mode is reject: ${source_path}"
	fi

	remove_existing_destination "${destination_path}" 'symlink'

	case "${symlink_mode}" in
		('preserve')
			if ! read_symlink_target_nul 'target' "${source_path}"; then
				fatal_exit "${EX_COPY_SYMLINKS}" \
					"Could not read symbolic-link target: ${source_path}"
			fi

			if ! ln --symbolic -- "${target}" "${destination_path}"; then
				fatal_exit "${EX_COPY_SYMLINKS}" \
					"Could not recreate symbolic link: ${destination_path}"
			fi
			;;
		('dereference')
			if [[ ! -e "${source_path}" ]]; then
				fatal_exit "${EX_COPY_SYMLINKS}" \
					"Cannot dereference dangling symbolic link: ${source_path}"
			fi

			if ! cp --archive --dereference -- \
				"${source_path}" "${destination_path}"; then
				fatal_exit \
					"${EX_COPY_SYMLINKS}" \
					"Could not dereference symbolic link: ${source_path}"
			fi
			;;
		(*)
			fatal_exit "${EX_CONFIG}" "Unsupported symlink mode: ${symlink_mode}"
			;;
	esac
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.4. Directory copying                               #
# ------------------------------------------------------------ #

copy_create_directories() {
    local inventory_dir="${1}"
    local path relative_path destination_path

    while IFS= read -r -d '' path; do
        relative_path="${path#./}"
        destination_path="${destination_dir}/${relative_path}"

        assert_no_symlinked_destination_parent "${relative_path}"
        if mkdir --parents -- "${destination_path}"; then
			copy_mark_destination_created "${path}"
		else
			copy_mark_destination_failed "${path}"
		fi
    done < "${inventory_dir}/source.directories.null"
}

copy_restore_directory_metadata() {
    local inventory_dir="${1}"
    local path relative_path destination_path

    mapfile -d '' -t dirs < "${inventory_dir}/source.directories.null"

    for ((i=${#dirs[@]} - 1; i >= 0; i--)); do
        path="${dirs[i]}"
        relative_path="${path#./}"
        destination_path="${destination_dir}/${relative_path}"

        cp --archive --attributes-only --no-preserve=links \
            -- "${source_dir}/${relative_path}" "${destination_path}"
    done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.5. Special filesystem objects                      #
# ------------------------------------------------------------ #

# copy_special_object() {

# }

# reject_unsupported_special_object() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.6. rsync backend                                   #
# ------------------------------------------------------------ #

rsync_add_supported_option() {
	local -n command_ref="${1}"
	local capability_name="${2}"
	local option="${3}"

	if [[ "${rsync_capabilities["${capability_name}"]:-unknown}" == 'true' ]]; then
		command_ref+=("${option}")
	fi
}

# rsync --archive is equivalent to rsync --recursive --links --perms --times --group --owner --devices --specials
# not --acls --xattrs --atimes --ctimes --hard-links

build_rsync_command() {
	local -n result="${1}"

	result=(
		'rsync'
		'--files-from=-'
		'--from0'
		'--perms'
		'--times'
		'--group'
		'--owner'
	)

	case "${symlink_mode}" in
		('preserve')
			rsync_add_supported_option 'result' 'symlinks' '--links'
			# rsync_add_supported_option 'result' 'symtimes' '--omit-link-times'
			;;
		('dereference')
			result+=('--copy-links')
			;;
		('reject')
			;;
		(*)
			;;
	esac

	case "${hardlink_mode}" in
		('preserve')
			rsync_add_supported_option 'result' 'hardlinks' '--hard-links'
			;;
		('duplicate' | 'reject')
			;;
		(*)
			;;
	esac

	rsync_add_supported_option 'result' 'acls' '--acls'
	rsync_add_supported_option 'result' 'xattrs' '--xattrs'
	rsync_add_supported_option 'result' 'atimes' '--atimes'
	rsync_add_supported_option 'result' 'crtimes' '--crtimes'
	rsync_add_supported_option 'result' 'devices' '--devices'
	rsync_add_supported_option 'result' 'specials' '--specials'
}

copy_with_rsync() {
	local inventory_dir="${1}"
	local -a rsync_cmd
	local rc

	build_rsync_command rsync_cmd

	if "${rsync_cmd[@]}" \
		-- . "${destination_dir}" \
		< "${inventory_dir}/source.all.null"; then
		:
	else
		rc="${?}"
		fatal_exit "${EX_COPY_FILES}" "rsync transfer failed (error ${rc})"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.7. Special-object policy                           #
# ------------------------------------------------------------ #

copy_validate_special_object_policy() {
	if [[ "${copy_special_objects_policy}" != 'true' ]]; then
		return 0
	fi

	if [[ "${capability[rsync]}" == 'true' &&
		"${rsync_capabilities[hardlink_specials]:-false}" != 'true' ]]; then
		log_warning 'rsync lacks hardlink-special support; special-object handling may be limited'
	fi

	if ! command -v mkfifo >/dev/null 2>&1; then
		fatal_exit "${EX_DEP_MISSING}" \
			'mkfifo is required when special-object copying is enabled'
	fi

	if ! command -v mknod >/dev/null 2>&1; then
		log_warning 'mknod is unavailable; device-node copying will be unsupported'
	fi

	if [[ "${EUID}" -ne 0 ]]; then
		log_warning 'Special-object copying is enabled without root privileges; device nodes may fail'
	fi
}

copy_validate_inventory_object_types() {
	local inventory_dir="${1}"
	local relative_path absolute_path type

	while IFS= read -r -d '' relative_path; do
		absolute_path="${source_dir}/${relative_path#./}"
		type="$(get_filesystem_object_type "${absolute_path}")"

		case "${type}" in
			('file' | 'directory' | 'symlink')
				;;

			('fifo')
				if [[ "${copy_special_objects_policy}" != 'true' ]]; then
					fatal_exit "${EX_COPY_FILES}" \
						"FIFO encountered but special-object copying is disabled: ${relative_path}"
				fi
				;;

			('socket')
				fatal_exit "${EX_COPY_FILES}" \
					"Socket objects cannot be copied: ${relative_path}"
				;;
			('block-device' | 'character-device')
				if [[ "${copy_special_objects_policy}" != 'true' ]]; then
					fatal_exit "${EX_COPY_FILES}" \
						"Device node encountered but special-object copying is disabled: ${relative_path}"
				fi
				;;

			(*)
				fatal_exit "${EX_COPY_FILES}" \
					"Unsupported filesystem object: ${relative_path} (${type})"
				;;
		esac
	done < "${inventory_dir}/source.all.null"
}

copy_validate_backend_object_types() {
    local inventory_dir="${1}"
    local path type

    if [[ "${capability[rsync]}" == 'true' ]]; then
		return 0
	fi

    while IFS= read -r -d '' path; do
        type="$(get_filesystem_object_type "${source_dir}/${path#./}")"

        case "${type}" in
            ('file' | 'directory' | 'symlink')
                ;;
            (*)
                fatal_exit "${EX_COPY_FILES}" \
                    "Fallback copy backend does not support ${type}: ${path}"
                ;;
        esac
    done < "${inventory_dir}/source.all.null"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.8. Non-rsync backend                               #
# ------------------------------------------------------------ #

copy_without_rsync() {
	local inventory_dir="${1}"
	local path

	copy_create_directories "${inventory_dir}"

	while IFS= read -r -d '' path; do
		if copy_regular_file "${path}"; then
			copy_mark_destination_created "${path}"
		else
			local rc="${?}"
			copy_mark_destination_failed "${path}" \
				"Regular-file copy failed with exit ${rc}"
			return "${rc}"
		fi
	done < "${inventory_dir}/source.files.null"

	while IFS= read -r -d '' path; do
		if copy_symbolic_link "${path}"; then
			copy_mark_destination_created "${path}"
		else
			local rc="${?}"
			copy_mark_destination_failed "${path}" \
				"Symbolic-link copy failed with exit ${rc}"
			return "${rc}"
		fi
	done < "${inventory_dir}/source.symlinks.null"

	copy_restore_directory_metadata "${inventory_dir}"

	# while IFS= read -r -d '' path; do
	# 	if cp --archive --attributes-only --parents \
	# 		-- "${path}" "${destination_dir}"; then
	# 		copy_mark_destination_created "${path}"
	# 	else
	# 		local rc="${?}"
	# 		copy_mark_destination_failed "${path}" \
	# 			"Directory copy failed with exit ${rc}"
	# 		return "${rc}"
	# 	fi
	# done < "${inventory_dir}/source.directories.null"
}

# copy_regular_files() {

# }

# copy_symbolic_links() {

# }

# copy_directories() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.9. Post-copy orchestration                         #
# ------------------------------------------------------------ #

copy_transfer_objects() {
	local inventory_dir
	inventory_dir="$(get_copy_inventory_dir)"

	if [[ "${dry_run}" == 'true' ]]; then
		log_notice "Dry-run enabled; skipping copy. Source='${source_dir}'; destination='${destination_dir}'"
		return 0
	fi

	# TO-DO: Confirm user wants to copy files
	if [[ "${capability[rsync]}" == 'true' ]]; then
		copy_with_rsync "${inventory_dir}"
	else
		copy_without_rsync "${inventory_dir}"
	fi
	# TO-DO: Verify files transferred successfully
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.10. Post-copy diagnostics                           #
# ------------------------------------------------------------ #

copy_collect_post_transfer_disk_usage() {
	log_info "Getting current disk usage of both directories’ volumes..."
	write_artifact_or_exit "${EX_COPY_POST}" 'Failed to collect post-copy filesystem usage' \
		'run' 'df.after.txt' 'write_filesystem_usage_metadata'
	log_info 'Disk usage collected'
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 19.11. Post-copy validation                           #
# ------------------------------------------------------------ #

# copy_verify_result() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  20. VERIFICATION STAGE                                                #
#==============================================================================#

# ------------------------------------------------------------ #
# region 20.1. Verification input validation                   #
# ------------------------------------------------------------ #

load_inventory_signing_metadata() {
	local metadata_file="${inventory_run_dir}/signing.meta.txt"
	local key value
	local metadata_signer=''
	local metadata_version=''
	local metadata_identity=''
	local metadata_namespace=''
	local metadata_timestamp=''
	local line_number=0

	inventory_signatures_detected='false'

	if [[ ! -e "${metadata_file}" ]]; then
		return 0
	fi

	if [[ ! -r "${metadata_file}" ]]; then
		fatal_exit "${EX_SIG_MISSING}" \
			"Signing metadata is not readable: ${metadata_file}"
	fi

	while IFS='=' read -r key value || [[ -n "${key}${value}" ]]; do
		line_number="$((line_number + 1))"

		case "${key}" in
			('signer')
				[[ -z "${metadata_signer}" ]] || fatal_exit "${EX_CONFIG}" \
					"Duplicate signer entry at line ${line_number}: ${metadata_file}"
				metadata_signer="${value}"
				;;
			('version')
				[[ -z "${metadata_version}" ]] || fatal_exit "${EX_CONFIG}" \
					"Duplicate version entry: ${metadata_file}"
				metadata_version="${value}"
				;;
			('identity')
				[[ -z "${metadata_identity}" ]] || fatal_exit "${EX_CONFIG}" \
					"Duplicate identity entry: ${metadata_file}"
				metadata_identity="${value}"
				;;
			('namespace')
				[[ -z "${metadata_namespace}" ]] || fatal_exit "${EX_CONFIG}" \
					"Duplicate namespace entry: ${metadata_file}"
				metadata_namespace="${value}"
				;;
			('timestamp')
				[[ -z "${metadata_timestamp}" ]] || fatal_exit "${EX_CONFIG}" \
					"Duplicate timestamp entry: ${metadata_file}"
				metadata_timestamp="${value}"
				;;
			('' | \#*)
				;;
			(*)
				fatal_exit "${EX_CONFIG}" \
					"Unknown signing metadata key '${key}': ${metadata_file}"
				;;
		esac
	done < "${metadata_file}"

	case "${metadata_signer}" in
		('sq' | 'gpg' | 'ssh-keygen' | 'minisign')
			;;
		(*)
			fatal_exit "${EX_CONFIG}" \
				"Invalid or missing signer in ${metadata_file}"
			;;
	esac

	if [[ -z "${metadata_version}" ||
		-z "${metadata_identity}" ||
		-z "${metadata_namespace}" ||
		-z "${metadata_timestamp}" ]]; then
		fatal_exit "${EX_CONFIG}" \
			"Incomplete signing metadata: ${metadata_file}"
	fi

	if [[ "${metadata_namespace}" != "${FSC_SCRIPT_NAME}" ]]; then
		fatal_exit "${EX_CONFIG}" \
			"Signing metadata namespace does not match this script"
	fi

	if [[ -n "${signer_command}" &&
		"${signer_command}" != "${metadata_signer}" ]]; then
		fatal_exit "${EX_CONFIG}" \
			"Requested signer '${signer_command}' does not match inventory signer '${metadata_signer}'"
	fi

	signer_command="${metadata_signer}"
	inventory_signatures_detected='true'
}

inventory_validate_signature_artifacts() {
	local expected_extension
	local manifest
	local signature
	local unexpected_extension

	case "${signer_command}" in
		('sq' | 'ssh-keygen')
			expected_extension='sig'
			;;
		('gpg')
			expected_extension='asc'
			;;
		('minisign')
			expected_extension='minisig'
			;;
		(*)
			fatal_exit "${EX_CONFIG}" "Unsupported signer: ${signer_command}"
			;;
	esac

	for manifest in \
		"${inventory_run_dir}/MANIFEST.sha256" \
		"${inventory_run_dir}/MANIFEST.sha512"; do

		if [[ ! -f "${manifest}" ]]; then
			fatal_exit "${EX_SIG_MISSING}" \
				"Signed manifest is missing: ${manifest}"
		fi

		signature="${manifest}.${expected_extension}"

		if [[ ! -f "${signature}" ]]; then
			fatal_exit "${EX_SIG_MISSING}" \
				"Signature is missing: ${signature}"
		fi

		for unexpected_extension in asc sig minisig; do
			if [[ "${unexpected_extension}" != "${expected_extension}" &&
				-e "${manifest}.${unexpected_extension}" ]]; then
				fatal_exit "${EX_CONFIG}" \
					"Unexpected signature artifact: ${manifest}.${unexpected_extension}"
			fi
		done
	done
}

# verify_validate_inventory_run() {

# }

# verify_require_inventory_manifest() {

# }

# verify_locate_signature_artifacts() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.2. Signature verification                          #
# ------------------------------------------------------------ #

verify_hash_manifest_with_sq() {
	local manifest_signed="${1}"
	local manifest_file="${manifest_signed%.sig}"
	local -a sq_verify_cmd=()

	sq_verify_cmd=(sq verify)
	if [[ -n "${sq_signer}" ]]; then
		sq_verify_cmd+=(--signer "${sq_signer}")
	elif [[ -n "${sq_signer_email}" ]]; then
		sq_verify_cmd+=(--signer-email "${sq_signer_email}")
	elif [[ -n "${sq_signer_file}" ]]; then
		sq_verify_cmd+=(--signer-file "${sq_signer_file}")
	elif [[ -n "${sq_signer_userid}" ]]; then
		sq_verify_cmd+=(--signer-userid "${sq_signer_userid}")
	fi
	sq_verify_cmd+=(--signature-file "${manifest_signed}" "${manifest_file}")

	"${sq_verify_cmd[@]}"
	log_notice "Verified manifest artifact with sq: ${manifest_signed}"
}

verify_hash_manifest_with_gpg() {
	local manifest_signed="${1}"
	local manifest_file="${manifest_signed%.asc}"
	local fingerprint
	local status

	# TO-DO: Let user specify a signature to compare against
	# https://superuser.com/a/1510996
	if [[ -n "${gpg_verification_fingerprint}" ]]; then
		fingerprint="$(printf '%s\n' "${gpg_verification_fingerprint}" | tr a-z A-Z | tr -dc A-Z0-9)"
		status="$(gpg --status-fd=4 --trust-model=always --verify "${manifest_signed}" "${manifest_file}" 4>&1 > /dev/null 2>&1)"
		if ! grep "^\\[GNUPG:\\] VALIDSIG ${fingerprint} " <<< "${status}"; then
			fatal_exit "${EX_SIG_VERIFY_FAILED}" "GPG signature fingerprint did not match expected fingerprint: ${fingerprint}"
		fi
	else
		gpg --verify "${manifest_signed}" "${manifest_file}"
	fi

	log_notice "Verified manifest artifact with gpg: ${manifest_signed}"
}

verify_hash_manifest_with_ssh_keygen() {
	local manifest_signed="${1}"
	local manifest_file="${manifest_signed%.sig}"
	local -a ssh_keygen_verify_cmd=()

	# ssh-keygen -Y verify -f allowed_signers_file -I signer_identity
	#            -n namespace -s signature_file [-r krl_file] [-O option]
	ssh_keygen_verify_cmd=(ssh-keygen -Y verify -f "${ssh_keygen_allowed_signers_file}" -I "${ssh_keygen_signer_identity}"
		-n "${FSC_SCRIPT_NAME}" -s "${manifest_signed}")

	"${ssh_keygen_verify_cmd[@]}" < "${manifest_file}"
	log_notice "Verified manifest artifact with ssh-keygen: ${manifest_signed}"
}

verify_hash_manifest_with_minisign() {
	local manifest_signed="${1}"
	local manifest_file="${manifest_signed%.minisig}"
	local -a minisign_verify_cmd=()

	# minisign -V [-H] [-x sig_file] [-p pubkey_file | -P pubkey] [-o] [-q] -m file
	minisign_verify_cmd=(minisign -V -x "${manifest_signed}")
	if [[ -n "${minisign_public_key_file}" ]]; then
		minisign_verify_cmd+=(-p "${minisign_public_key_file}")
	elif [[ -n "${minisign_public_key}" ]]; then
		minisign_verify_cmd+=(-P "${minisign_public_key}")
	fi

	minisign_verify_cmd+=(-m "${manifest_file}")

	"${minisign_verify_cmd[@]}"
	log_notice "Verified manifest artifact with minisign: ${manifest_signed}"
}

verify_inventory_signatures() {
	case "${verify_signatures}" in
		('false')
			log_debug 'Signature verification explicitly disabled; skipping'
			return 0
			;;
		('auto' | 'true')
			;;
		(*)
			fatal_exit "${EX_CONFIG}" \
				"Invalid signature-verification policy: ${verify_signatures}"
			;;
	esac

	if [[ "${inventory_signatures_detected}" != 'true' ]]; then
		if [[ "${verify_signatures}" == 'true' ]]; then
			fatal_exit "${EX_SIG_MISSING}" \
				'Signature verification was requested but the inventory is unsigned'
		fi

		log_debug 'Inventory is unsigned; skipping signature verification'
		return 0
	fi

	log_debug 'Verifying manifest artifacts'
	local signature_root="${inventory_run_dir:-${run_dir}}"
	local extension
	local manifest
	local signature

	case "${signer_command}" in
		('sq' | 'ssh-keygen')
			extension='sig'
			;;
		('gpg')
			extension='asc'
			;;
		('minisign')
			extension='minisig'
			;;
		(*)
			fatal_exit "${EX_CONFIG}" "Unsupported signer: ${signer_command}"
			;;
	esac

	for manifest in \
		"${signature_root}/MANIFEST.sha256" \
		"${signature_root}/MANIFEST.sha512"; do

		signature="${manifest}.${extension}"

		if [[ ! -f "${manifest}" ]]; then
			fatal_exit "${EX_SIG_MISSING}" \
				"Signed manifest is missing: ${manifest}"
		fi

		if [[ ! -f "${signature}" ]]; then
			fatal_exit "${EX_SIG_MISSING}" \
				"Signature is missing: ${signature}"
		fi

		"verify_hash_manifest_with_${signer_command/-/_}" "${signature}"
	done
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.3. Destination-manifest generation and comparison  #
# ------------------------------------------------------------ #

# verify_write_destination_manifest() {

# }

# verify_compare_object_manifests() {

# }

verify_destination_against_inventory() {
	local expected_manifest="${inventory_run_dir}/source.objects.tsv"
	local actual_manifest_path='destination.objects.tsv'
	local actual_manifest="${run_dir}/${actual_manifest_path}"
	local destination_list_path='destination.all.null'
	local report_path='metadata.diff.txt'
	local diff_path="${run_dir}/${report_path}"
	local rc

	if [[ -z "${inventory_run_dir}" ]]; then
		artifact_last_error='No inventory run directory was provided'
		return "${EX_VERIFY_INPUT_MISSING}"
	fi

	if [[ ! -d "${inventory_run_dir}" ]]; then
		artifact_last_error="Inventory run directory does not exist: ${inventory_run_dir}"
		return "${EX_VERIFY_INPUT_MISSING}"
	fi

	if [[ ! -r "${expected_manifest}" ]]; then
		artifact_last_error="Expected metadata manifest is not readable: ${expected_manifest}"
		return "${EX_VERIFY_INPUT_MISSING}"
	fi

	if write_artifact_atomically \
		"${FUNCNAME[0]}" \
		'run' \
		"${destination_list_path}" \
		'inventory_write_object_list_nul_for_root' \
		"${destination_dir}"; then
		:
	else
		artifact_last_error="Failed to generate destination object list: ${artifact_last_error}"
		return "${EX_VERIFY_UNAVAILABLE}"
	fi

	if write_artifact_atomically \
		"${FUNCNAME[0]}" \
		'run' \
		"${actual_manifest_path}" \
		'build_object_manifest' \
		"${destination_dir}" \
		"${run_dir}/${destination_list_path}"; then
		:
	else
		rc="${?}"
		artifact_last_error="Failed to generate destination metadata manifest: ${artifact_last_error}"
		return "${EX_VERIFY_UNAVAILABLE}"
	fi

	# cmp:
	#   0 = identical
	#   1 = different
	#   >1 = error
	if cmp --silent -- "${expected_manifest}" "${actual_manifest}"; then
		log_info 'Destination metadata matches inventory'
		return 0
	else
		rc="${?}"
	fi

	if [[ "${rc}" -gt 1 ]]; then
		artifact_last_error='Failed to compare metadata manifests'
		return "${EX_VERIFY_UNAVAILABLE}"
	fi

	# diff:
	#   0 = identical
	#   1 = differences
	#   >1 = error
	if diff --unified=3 \
		-- "${expected_manifest}" "${actual_manifest}" >| "${diff_path}"; then
		:
	else
		rc="${?}"
	fi

	if [[ "${rc}" -gt 1 ]]; then
		artifact_last_error="Failed to write metadata comparison report: ${diff_path}"
		return "${EX_VERIFY_UNAVAILABLE}"
	fi

	log_err "Destination metadata differs; see ${diff_path}"
	return "${EX_VERIFY_METADATA_MISMATCH}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.4. Path comparison                                 #
# ------------------------------------------------------------ #

# verify_compare_paths() {

# }

# verify_report_missing_paths() {

# }

# verify_report_extra_paths() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.5. Hash comparison                                 #
# ------------------------------------------------------------ #

# verify_compare_file_hashes() {

# }

# verify_report_hash_mismatches() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.6. Metadata comparison                             #
# ------------------------------------------------------------ #

# verify_compare_object_metadata() {

# }

# verify_compare_symlink_targets() {

# }

# verify_compare_hardlink_topology() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.7. Verification reporting                          #
# ------------------------------------------------------------ #

# verify_write_diff_report() {

# }

# verify_classify_result() {

# }

# ------------------------------------------------------------ #
# endregion                                                    #
# region 20.8. Verification orchestration                      #
# ------------------------------------------------------------ #

run_destination_verification() {
	local rc

	if verify_destination_against_inventory; then
		:
	else
		rc="${?}"

		if [[ -n "${artifact_last_error}" ]]; then
			log_err "${artifact_last_error}"
		fi

		return "${rc}"
	fi

	verify_completed='true'
	return 0
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  21. FINALISATION AND TRAPS                                            #
#==============================================================================#

# ------------------------------------------------------------ #
# region 21.1. Run statistics                                  #
# ------------------------------------------------------------ #

write_run_statistics() {
	local rc="${1}"
	local elapsed_ns elapsed_sec
	local manifest_file_sha256 manifest_file_sha512 signature_file_sha256 signature_file_sha512
	local timings_file_j log_file_j

	end_epoch_ns="$(date '+%s%9N')"
	elapsed_ns="$((end_epoch_ns - start_epoch_ns))"
	elapsed_sec="$((elapsed_ns / 1000000000))"

	manifest_file_sha256=''
	manifest_file_sha512=''
	signature_file_sha256=''
	signature_file_sha512=''

	if [[ -f "${run_dir}/MANIFEST.sha256" ]]; then
		manifest_file_sha256='MANIFEST.sha256'
	fi
	if [[ -f "${run_dir}/MANIFEST.sha256.asc" ]]; then
		signature_file_sha256='MANIFEST.sha256.asc'
	elif [[ -f "${run_dir}/MANIFEST.sha256.sig" ]]; then
		signature_file_sha256='MANIFEST.sha256.sig'
	elif [[ -f "${run_dir}/MANIFEST.sha256.minisig" ]]; then
		signature_file_sha256='MANIFEST.sha256.minisig'
	fi

	if [[ -f "${run_dir}/MANIFEST.sha512" ]]; then
		manifest_file_sha512='MANIFEST.sha512'
	fi
	if [[ -f "${run_dir}/MANIFEST.sha512.asc" ]]; then
		signature_file_sha512='MANIFEST.sha512.asc'
	elif [[ -f "${run_dir}/MANIFEST.sha512.sig" ]]; then
		signature_file_sha512='MANIFEST.sha512.sig'
	elif [[ -f "${run_dir}/MANIFEST.sha512.minisig" ]]; then
		signature_file_sha512='MANIFEST.sha512.minisig'
	fi

	# Basename stuff
	timings_file_j="$(basename "${final_timings_log:-${bootstrap_timings_log}}")"
	log_file_j="$(basename "${final_log}")"

	# shellcheck disable=SC2310,SC2312
	cat > "${run_dir}/run.stats.json" << EOF
{
  "run_id": $(json_string_or_null "${run_id}"),
  "script_name": $(json_string_or_null "${FSC_SCRIPT_NAME}"),
  "start_epoch_ns": $(json_number_or_null "${start_epoch_ns}"),
  "end_epoch_ns": $(json_number_or_null "${end_epoch_ns}"),
  "duration_ns": $(json_number_or_null "${elapsed_ns}"),
  "duration_sec": $(json_number_or_null "${elapsed_sec}"),
  "exit_code": $(json_number_or_null "${rc}"),
  "exit_code_name": $(json_string_or_null "$(get_exit_code_name "${rc}")"),
  "source_dir": $(json_string_or_null "${source_dir}"),
  "destination_dir": $(json_string_or_null "${destination_dir}"),
  "output_dir": $(json_string_or_null "${output_dir}"),
  "run_dir": $(json_string_or_null "${run_dir}"),
  "dry_run": $(json_bool "${dry_run}"),
  "force": $(json_bool "${FORCE}"),
  "sign": $(json_bool "${sign}"),
  "signer": $(json_string_or_null "${signer_command}"),
  "inventory_done": $(json_bool "${inventory_completed}"),
  "copy_done": $(json_bool "${copy_completed}"),
  "warning_count": $(json_number_or_null "${warn_count}"),
  "error_count": $(json_number_or_null "${error_count}"),
  "source_files_count": $(json_number_or_null "${inventory_file_count}"),
  "source_directories_count": $(json_number_or_null "${inventory_directory_count}"),
  "source_symlinks_count": $(json_number_or_null "${inventory_symlink_count}"),
  "source_all_count": $(json_number_or_null "${inventory_object_count}"),
  "manifest_file_sha256": $(json_string_or_null "${manifest_file_sha256}"),
  "signature_file_sha256": $(json_string_or_null "${signature_file_sha256}"),
  "manifest_file_sha512": $(json_string_or_null "${manifest_file_sha512}"),
  "signature_file_sha512": $(json_string_or_null "${signature_file_sha512}"),
  "timings_file": $(json_string_or_null "${timings_file_j}"),
  "log_file": $(json_string_or_null "${log_file_j}"),
  "bash_logger_path": $(json_string_or_null "${BASH_LOGGER_FILE}"),
  "fatal_exit_code": $(json_number_or_null "${exit_status}"),
  "exit_phase": $(json_string_or_null "${exit_phase}"),
  "exit_reason": $(json_string_or_null "${exit_reason}")
}
EOF
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 21.2. Unexpected-error handling                       #
# ------------------------------------------------------------ #

handle_unexpected_error() {
	local rc="${1}"
	local command="${2}"
	local source_file="${3}"
	local source_line="${4}"

	if [[ "${fatal_exit_in_progress}" == 'true' ]]; then
		return 0
	fi

	log_err \
		"Unhandled error at ${source_file}:${source_line}; exit=${rc}; command=${command}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 21.3. Exit finalisation                               #
# ------------------------------------------------------------ #

finalise_run() {
	local rc="${1}"
	local final_rc="${rc}"
	local elapsed_ns
	local elapsed_sec

	# Prevent finalisation errors from replacing the original status.
	set +e

	if [[ -n "${active_phase}" ]]; then
		finish_phase || true
		active_phase=''
	fi

	if [[ -n "${run_dir}" && -d "${run_dir}" ]]; then
		write_run_statistics "${rc}" || {
			printf '%s\n' \
				"Failed to write run statistics" >&2
			final_rc="${rc}"
		}
	fi

	release_run_lock || true

	end_epoch_ns="$(date '+%s%9N')" || end_epoch_ns='0'

	if [[ "${start_epoch_ns}" =~ ^[0-9]+$ &&
		"${end_epoch_ns}" =~ ^[0-9]+$ ]]; then
		elapsed_ns="$((end_epoch_ns - start_epoch_ns))"
	else
		elapsed_ns='0'
	fi

	elapsed_sec="$((elapsed_ns / 1000000000))"

	if [[ "${rc}" -eq "${EX_OK}" ]]; then
		log_notice \
			"Script completed successfully in ${elapsed_sec}s" || true
	else
		log_err \
			"Script failed in ${elapsed_sec}s with exit=${rc} ($(get_exit_code_name "${rc}"))" \
			|| true
	fi

	return "${final_rc}"
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 21.4. Trap installation                               #
# ------------------------------------------------------------ #

install_traps() {
	trap 'rc="${?}"; handle_unexpected_error "${rc}" "${BASH_COMMAND}" "${BASH_SOURCE[0]}" "${BASH_LINENO[0]}"' ERR
	trap 'finalise_run "${?}"' EXIT
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  22. PHASE ORCHESTRATION                                               #
#==============================================================================#

run_preflight_checks() {
	transition_phase 'preflight'

	detect_rsync_information
	parse_rsync_capabilities
	
	require_gnu_getopt

	parse_command_line "${@}"
	validate_configuration
}

run_setup() {
	transition_phase 'run_setup'

	create_run_directory

	if ! initialise_artifact_registry; then
		fatal_exit "${EX_INTERNAL}" "${artifact_last_error}"
	fi
	artifact_registry_initialised='true'

	acquire_run_lock

	finalise_log_location
	finalise_timings_log_location
}

# ------------------------------------------------------------ #
# region 22.1. Inventory phase                                 #
# ------------------------------------------------------------ #

execute_inventory_phase() {
	if [[ "${inventory_mode_enabled}" == 'false' ]]; then
		log_notice 'Skipping inventory mode'
		return "${EX_OK}"
	fi

	transition_phase 'inventory_list'
	cd_or_die "${source_dir}" "${EX_ENV}" 'Failed to enter source directory'

	inventory_write_source_metadata
	inventory_write_object_lists
	inventory_validate_list_counts
	inventory_require_non_empty_source
	inventory_validate_symlink_policy

	if [[ "${copy_mode_enabled}" == 'true' ]]; then
		inventory_validate_object_types "${run_dir}"
	fi

	transition_phase 'inventory_metadata'
	inventory_write_source_object_manifest
	# inventory_collect_source_parent_metadata
	inventory_collect_metadata

	transition_phase 'inventory_hash_source'
	inventory_hash_source_files

	transition_phase 'inventory_manifest'
	write_run_artifact_manifests
	inventory_sign_hash_manifests

	write_artifact_or_exit "${EX_INV_MANIFEST}" 'Failed to write inventory completion marker' \
		'run' 'inventory.complete' 'inventory_write_completion_marker'

	inventory_completed='true'

	if [[ "${mode}" == 'all' ]]; then
		inventory_run_dir="${run_dir}"
	fi
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 22.2. Copy phase                                      #
# ------------------------------------------------------------ #

execute_copy_phase() {
	if [[ "${copy_mode_enabled}" == 'false' ]]; then
		log_notice 'Skipping copy mode'
		return "${EX_OK}"
	fi

	transition_phase 'copy_prepare'

	validate_inventory_artifact_set "${inventory_run_dir}" "${EX_COPY_PREP}"

	if [[ "${mode}" != 'all' ]]; then
		load_inventory_metadata
	fi

	copy_validate_special_object_policy
	copy_validate_inventory_object_types "${inventory_run_dir}"

	cd_or_die "${source_dir}" "${EX_ENV}" 'Failed to enter source directory'

	inventory_validate_object_types "${inventory_run_dir}"
	copy_plan_destination_artifacts "${inventory_run_dir}"

	if [[ "${dry_run}" == "true" ]]; then
		log_notice "Dry-run enabled; copy operation will not modify destination"
		copy_transfer_objects
		copy_completed='false'
		return "${EX_OK}"
	fi

	if ! mkdir --parents -- "${destination_dir}"; then
		fatal_exit "${EX_COPY_PREP}" "Could not create destination directory: ${destination_dir}"
	fi

	transition_phase 'copy_transfer'
	copy_transfer_objects
	copy_completed='true'

	transition_phase 'copy_post'
	copy_collect_post_transfer_disk_usage
}

# ------------------------------------------------------------ #
# endregion                                                    #
# region 22.3. Verification phase                              #
# ------------------------------------------------------------ #

execute_verify_phase() {
	if [[ "${verify_mode_enabled}" == 'false' ]]; then
		log_notice 'Skipping verification mode'
		return "${EX_OK}"
	fi

	if [[ "${dry_run}" == "true" ]]; then
		log_notice 'Dry-run enabled; skipping verification'
		return "${EX_OK}"
	fi

	local rc

	transition_phase 'verify_prepare'

	validate_inventory_artifact_set "${inventory_run_dir}" "${EX_VERIFY_INPUT_MISSING}"

	if [[ ! -d "${destination_dir}" ]]; then
		fatal_exit "${EX_VERIFY_INPUT_MISSING}" \
			"Destination directory does not exist: ${destination_dir}"
	fi

	if [[ ! -r "${destination_dir}" || ! -x "${destination_dir}" ]]; then
		fatal_exit "${EX_VERIFY_UNAVAILABLE}" \
			"Destination directory is not accessible: ${destination_dir}"
	fi

	load_inventory_metadata

	load_inventory_signing_metadata

	if [[ "${verify_signatures}" != 'false' &&
		"${inventory_signatures_detected}" == 'true' ]]; then
		inventory_validate_signature_artifacts
		validate_signature_verification_selection
	fi

	transition_phase 'verify_paths'
	# Path verification can be added here later.

	transition_phase 'verify_signatures'
	verify_inventory_signatures

	transition_phase 'verify_hashes'

	transition_phase 'verify_report'

	if run_destination_verification; then
		:
	else
		rc="${?}"
		return "${rc}"
	fi

	return 0
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#region  23. MAIN ENTRY POINT                                                  #
#==============================================================================#

# ------------------------------------------------------------ #
# region 23.1. Main orchestration                              #
# ------------------------------------------------------------ #

main() {
	start_epoch_ns="$(date '+%s%9N')"

	create_bootstrap_logs
	install_traps
	start_phase_at 'bootstrap' "${start_epoch_ns}"

	check_required_dependencies
	detect_optional_capabilities

	transition_phase 'logger_init'
	initialise_bash_logger

	run_preflight_checks "${@}"

	run_setup

	log_notice 'Script starting'

	execute_inventory_phase
	execute_copy_phase
	execute_verify_phase
}

# ------------------------------------------------------------ #
# endregion                                                    #
# ------------------------------------------------------------ #

#==============================================================================#
#endregion                                                                     #
#==============================================================================#

for arg in "${@}"; do
	if [[ "${arg}" == '--help' || "${arg}" == '-h' ]]; then
		show_help
	fi
done

main "${@}"
