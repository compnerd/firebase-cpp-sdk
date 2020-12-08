#!/bin/bash
#
# Script to package desktop SDK
set -e

usage(){
    echo "Usage: $0 -b <built sdk path> -o <output package path> -p <platform> [options]
options:
  -b, built sdk path or tar file            required
  -o, output path                           required
  -p, platform to package	            required, one of: linux windows darwin
  -d, build variant directory to create     default: .
  -m, merge_libraries.py path               default: <script dir>/../../scripts/merge_libraries.py
  -P, python command                        default: python
  -t, packaging tools directory             default: ~/bin
  -v, enable verbose mode
example:
  build_scripts/desktop/package.sh -b firebase-cpp-sdk-linux -p linux -o package_out -v x86"
}

built_sdk_path=
output_package_path=
platform=
python_cmd=python
variant=.
verbose=0
root_dir=$(cd $(dirname $0)/../..; pwd -P)
merge_libraries_script=${root_dir}/scripts/merge_libraries.py
tools_path=~/bin
built_sdk_tarfile=
temp_dir=

. "${root_dir}/build_scripts/packaging.conf"

readonly SUPPORTED_PLATFORMS=(linux windows darwin)

abspath(){
    if [[ -d $1 ]]; then
	echo "$(cd "$1"; pwd -P)"
    else
	echo "$(cd "$(dirname "$1")"; pwd -P)/$(basename "$1")"
    fi
}

while getopts ":b:o:p:d:m:P:t:hv" opt; do
    case $opt in
        b)
            built_sdk_path=$OPTARG
            ;;
        o)
            output_package_path=$OPTARG
            ;;
        p)
            platform=$OPTARG
            if [[ ! " ${SUPPORTED_PLATFORMS[@]} " =~ " ${platform} " || -z "${platform}" ]]; then
                echo "Invalid platform: ${platform}"
                echo "Supported platforms are: ${SUPPORTED_PLATFORMS[@]}"
                exit 2
            fi
            ;;
	v)
	    verbose=1
	    ;;
        d)
            variant=$OPTARG
            ;;
        m)
            merge_libraries_script=$OPTARG
	    if [[ ! -r "${merge_libraries_script}" ]]; then
                echo "Script not found: ${merge_libraries_script}"
                exit 2
	    fi
            ;;
        P)
	    python_cmd=$OPTARG
            ;;
	t)
	    tools_path=$OPTARG
	    ;;
	h)
	    usage
	    exit 0
	    ;;
        *)
	    usage
            exit 2
            ;;
    esac
done

if [[ -z "${built_sdk_path}" ]]; then
    echo "Missing required option: -b <built sdk path>"
    exit 2
fi
if [[ -z "${output_package_path}" ]]; then
    echo "Missing required option: -o <output package path>"
    exit 2
fi
if [[ -z "${platform}" ]]; then
    echo "Missing required option: -p <platform>"
    echo "Supported platforms are: ${SUPPORTED_PLATFORMS[@]}"
    exit 2
fi
# Check the built sdk path to see if we need to untar it.
if [[ ! -d "${built_sdk_path}" && -f "${built_sdk_path}" ]]; then
    # tarball was specified, uncompress it
    temp_dir=$(mktemp -d)
    trap "rm -rf \"\${temp_dir}\"" SIGKILL SIGTERM SIGQUIT EXIT
    echo "Uncompressing tarfile into temporary directory..."
    tar -xf "${built_sdk_path}" -C "${temp_dir}"
    built_sdk_path="${temp_dir}"
fi

if [[ ! -r "${built_sdk_path}/CMakeCache.txt" ]]; then
    echo "Built SDK not found in ${built_sdk_path}."
    exit 2
fi

mkdir -p "${output_package_path}"

# Get absolute paths where needed.
built_sdk_path=$(abspath "${built_sdk_path}")
merge_libraries_script=$(abspath "${merge_libraries_script}")
output_package_path=$(abspath "${output_package_path}")
tools_path=$(abspath "${tools_path}")
if [[ ${python_cmd} == *'/'* ]]; then
    # If a full path to python was given, get the absolute path.
    python_cmd=$(abspath "${python_cmd}")
fi

# Desktop packaging settings.
if [[ "${platform}" == "windows" ]]; then
    if [[ "${variant}" == *'Debug'* ]]; then
	subdir='Debug/'
	suffix='-d'
    else
	subdir='Release/'
	suffix=''
    fi
    prefix=''
    ext='lib'
else
    # No 'Release' or 'Debug' subdirectory in the built files on these platforms.
    suffix=''
    subdir=''
    prefix='lib'
    ext='a'
fi

# Library dependencies to merge. Each should be a whitespace-delimited list of path globs.
readonly deps_firebase_app="
*/${prefix}firebase_instance_id*${suffix}.${ext}
*/${prefix}firebase_rest_lib${suffix}.${ext}
"
readonly deps_hidden_firebase_app="
*/${subdir}${prefix}curl${suffix}.${ext}
*/${subdir}${prefix}flatbuffers${suffix}.${ext}
*/zlib-build/${subdir}${prefix}z.${ext}
*/zlib-build/${subdir}zlibstatic*.${ext}
*/vcpkg-libs/libcrypto.${ext}
*/vcpkg-libs/libssl.${ext}
*/firestore-build/*/leveldb-build*/${prefix}*.${ext}
*/firestore-build/*/nanopb-build*/${prefix}*.${ext}
"
readonly deps_hidden_firebase_database="
*/${subdir}${prefix}uv_a${suffix}.${ext}
*/${subdir}${prefix}libuWS${suffix}.${ext}
"
readonly deps_hidden_firebase_firestore="
*/firestore-build/Firestore/*/${prefix}*.${ext}
*/firestore-build/*/grpc-build*/${prefix}*.${ext}
"

# List of C++ namespaces to be renamed, so as to not conflict with the
# developer's own dependencies.
readonly -a rename_namespaces=(flatbuffers flexbuffers reflection ZLib bssl uWS absl google
base_raw_logging ConnectivityWatcher grpc
grpc_access_token_credentials grpc_alts_credentials
grpc_alts_server_credentials grpc_auth_context
grpc_channel_credentials grpc_channel_security_connector
grpc_chttp2_hpack_compressor grpc_chttp2_stream grpc_chttp2_transport
grpc_client_security_context grpc_composite_call_credentials
grpc_composite_channel_credentials grpc_core grpc_deadline_state
grpc_google_default_channel_credentials grpc_google_iam_credentials
grpc_google_refresh_token_credentials grpc_impl grpc_local_credentials
grpc_local_server_credentials grpc_md_only_test_credentials
grpc_message_compression_algorithm_for_level
grpc_oauth2_token_fetcher_credentials grpc_plugin_credentials
grpc_server_credentials grpc_server_security_connector
grpc_server_security_context
grpc_service_account_jwt_access_credentials grpc_ssl_credentials
grpc_ssl_server_credentials grpc_tls_credential_reload_config
grpc_tls_server_authorization_check_config GrpcUdpListener leveldb
leveldb_filterpolicy_create_bloom leveldb_writebatch_iterate strings
TlsCredentials TlsServerCredentials tsi)

# String to prepend to all hidden symbols.
readonly rename_string=f_b_

readonly demangle_cmds=${tools_path}/c++filt,${tools_path}/demumble
readonly binutils_objcopy=${tools_path}/objcopy
if [[ -x ${tools_path}/nm-new ]] ;; then
    readonly binutils_nm=${tools_path}/nm-new
else
    readonly binutils_nm=${tools_path}/nm
fi
readonly binutils_ar=${tools_path}/ar

cache_file=/tmp/merge_libraries_cache.$$
# Clean up cache file after script is finished.
trap "rm -f \"\${cache_file}\"" SIGKILL SIGTERM SIGQUIT EXIT

declare -a merge_libraries_params
merge_libraries_params=(
    --cache=${cache_file}
    --binutils_nm_cmd=${binutils_nm}
    --binutils_ar_cmd=${binutils_ar}
    --binutils_objcopy_cmd=${binutils_objcopy}
    --demangle_cmds=${demangle_cmds}
    --platform=${platform}
    --hide_cpp_namespaces=$(echo "${rename_namespaces[*]}" | sed 's| |,|g')
)
if [[ ${platform} == "windows" ]]; then
    # Windows has a hard time with strict C++ demangling.
    merge_libraries_params+=(--nostrict_cpp)
fi
if [[ ${verbose} -eq 1 ]]; then
    merge_libraries_params+=(--verbosity=3)
fi

if [[ ! -x "${binutils_objcopy}" || ! -x "${binutils_ar}" || ! -x "${binutils_nm}" ]]; then
    echo "Packaging tools not found at path '${tools_path}'."
    exit 2
fi


run_path=$( pwd -P )
full_output_path="${output_package_path}/libs/${platform}/${variant}"
mkdir -p "${full_output_path}"
echo "Output directory: ${full_output_path}"

cd "${built_sdk_path}"

# Gather a comma-separated list of all library files. This will be
# passed to merge_libraries in the --scan_libs parameter.
declare allfiles
for lib in $(find . -name "*.${ext}"); do
    if [[ ! -z ${allfiles} ]]; then allfiles+=","; fi
    allfiles+="${lib}"
done

# Make sure we only copy the libraries in product_list (specified in packaging.conf)
for product in ${product_list[*]}; do
    libfile_src="${product}/${subdir}${prefix}firebase_${product}.${ext}"
    libfile_out=$(basename "${libfile_src}")
    if [[ ! -r "${libfile_src}" ]]; then
	# Windows names some debug libraries with a "-d.lib" suffix.
	libfile_src="${product}/${subdir}${prefix}firebase_${product}${suffix}.${ext}"
	# Don't change libfile_out though.
	if [[ ! -r "${libfile_src}" ]]; then
	    continue
	fi
    fi

    # Look up the previously-set deps_firebase_* and deps_hidden_firebase_* vars.
    deps_var="deps_firebase_${product}"  # variable name
    deps_hidden_var="deps_hidden_firebase_${product}"  # variable name
    declare -a deps deps_basenames
    deps=() # List of all dependencies, both hidden and visible.
    deps_basenames=()  # Same as above but only filenames, for more readable logging to console.
    for dep in ${!deps_var} ${!deps_hidden_var}; do
	for found in $(find . -path ${dep}); do
	    deps[${#deps[@]}]="${found}"
	    deps_basenames[${#deps_basenames[@]}]=$(basename "${found}")
	done
    done
    deps_hidden='' # comma-separated list of hidden deps only
    for dep in ${!deps_hidden_var}; do
	for found in $(find . -path ${dep}); do
	    if [[ ! -z ${deps_hidden} ]]; then deps_hidden+=","; fi
	    deps_hidden+="${found}"
	done
    done
    echo -n "${libfile_out}"
    if [[ ! -z ${deps_basenames[*]} ]]; then
	echo -n " <- ${deps_basenames[*]}"
    fi
    echo
    outfile="${full_output_path}/${libfile_out}"
    rm -f "${outfile}"
    "${python_cmd}" "${merge_libraries_script}" \
		    ${merge_libraries_params[*]} \
		    --output="${outfile}" \
		    --scan_libs="${allfiles}" \
		    --hide_c_symbols="${deps_hidden}" \
		    ${libfile_src} ${deps[*]}
done
cd "${run_path}"
