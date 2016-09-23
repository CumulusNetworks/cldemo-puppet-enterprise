#! /bin/bash
set -u
set -e


PUPPET_BIN_DIR="/opt/puppetlabs/puppet/bin"
export OLD_PUPPET_BIN_DIR="/opt/puppet/bin"

fail() { echo >&2 "$@"; exit 1; }
cmd()  { hash "$1" >&/dev/null; } # portable 'which'

puppet_installed() {
  if [ -x "${PUPPET_BIN_DIR?}/puppet" -o -x "${OLD_PUPPET_BIN_DIR}/puppet" ]; then
    return 0
  else
    return 1
  fi
}

# Echo back either the AIO puppet bin dir path, or PE 3.x pe-agent
# puppet bin dir.
puppet_bin_dir() {
    if [ -e "${PUPPET_BIN_DIR?}" ]; then
        t_puppet_bin_dir="${PUPPET_BIN_DIR?}"
    else
        t_puppet_bin_dir=/opt/puppet/bin
    fi
    echo "${t_puppet_bin_dir?}"
}


### The following variable and function (upgrading_from_38x)
### Need to be declared after the `puppet_bin_dir` function
### due to the way bash handles function parsing
# Are we upgradeing from 3.8.x or 2015.2+ ?
ORIGINAL_PUPPET_BIN_DIR=$(puppet_bin_dir)

upgrading_from_38x() {
    [ "${ORIGINAL_PUPPET_BIN_DIR?}" = "${OLD_PUPPET_BIN_DIR?}" ]
}

mktempfile() {
  if cmd mktemp; then
    if [ "osx" = "${PLATFORM_NAME}" ]; then
      mktemp -t installer
    else
      mktemp
    fi
  else
    echo "/tmp/puppet-enterprise-installer.XXX-${RANDOM}"
  fi
}

custom_puppet_configuration() {
  # Parse optional pre-installation configuration of Puppet settings via
  # command-line arguments. Arguments should be of the form
  # <section>:<setting>=<value>
  regex='(.*):(.*)=(.*)'
  for entry in "$@"; do
    if ! [[ "$entry" =~ $regex ]]; then
      echo "WARNING: unable to interpret argument: ${entry}. Expected <section>:<setting>=<value>"
    else
      section=${BASH_REMATCH[1]}
      setting=${BASH_REMATCH[2]}
      value=${BASH_REMATCH[3]}
      "${PUPPET_BIN_DIR?}/puppet" config set "$setting" "$value" --section "$section"
    fi
  done
}

ensure_link() {
  "${PUPPET_BIN_DIR?}/puppet" resource file "${1?}" ensure=link target="${2?}"
}

ensure_agent_links() {
  target_path="/usr/local/bin"

  if mkdir -p "${target_path}" && [ -w "${target_path}" ]; then
    for bin in facter puppet pe-man hiera; do
      ensure_link "${target_path}/${bin}" "${PUPPET_BIN_DIR?}/${bin}"
    done
  else
    echo "!!! WARNING: ${target_path} is inaccessible; unable to create convenience symlinks for puppet, hiera, facter and pe-man.  These executables may be found in ${pe_path?}." 1>&2
  fi
}

# Detected existing installation? Return y if true, else n
is_upgrade() {
  if puppet_installed; then
    echo "y"
  else
    echo "n"
  fi
}

# Sets server, certname and any custom puppet.conf flags passed in to the script
puppet_config_set() {
  # puppet config set does not create the [main] section if it does not exist
  # and does not use it if it has no settings (PUP-4755); and augeas does not
  # consider puppet.conf parseable with settings floating outside of a section
  puppet_conf="$("${PUPPET_BIN_DIR?}/puppet" config print confdir)/puppet.conf"
  if ! grep '\[main\]' $puppet_conf; then
    t_surgery='yes'
    cat >> $puppet_conf <<EOF
[main]
place=holder
EOF
  fi

  "${PUPPET_BIN_DIR?}/puppet" config set server oob-mgmt-server.lab.local --section main

  if [ "${t_surgery}" = 'yes' ]; then
    t_platform_test="x$(uname -s)"
    if [ $t_platform_test = "xDarwin" ]; then
      sed -i '' '/^place=holder$/ d' $puppet_conf
    elif [ $t_platform_test = "xSunOS" -o $t_platform_test = "xAIX" ]; then
      sed '/^place=holder$/ d' $puppet_conf > "${puppet_conf}.new" && mv "${puppet_conf}.new" $puppet_conf
    else
      sed -i '/^place=holder$/ d' $puppet_conf
    fi
  fi

  "${PUPPET_BIN_DIR?}/puppet" config set certname $("${PUPPET_BIN_DIR?}/facter" fqdn | "${PUPPET_BIN_DIR?}/ruby" -e 'puts STDIN.read.downcase') --section agent
  custom_puppet_configuration "$@"

  # To ensure the new config settings take place and to work around differing OS behaviors on recieving a service start command while running
  # (on nix it triggers a puppet run, on osx it does nothing), restart the service by stopping and starting it again
  restart_puppet_agent
}

restart_puppet_agent() {
  "${PUPPET_BIN_DIR?}/puppet" resource service puppet ensure=stopped
  "${PUPPET_BIN_DIR?}/puppet" resource service puppet ensure=running enable=true
}

start_puppet_agent() {
  "${PUPPET_BIN_DIR?}/puppet" resource service puppet ensure=running enable=true
}

stop_puppet_agent() {
  "$(puppet_bin_dir)/puppet" resource service puppet ensure=stopped
  wait_for_puppet_lock
}

mcollective_service_name() {
  if upgrading_from_38x; then
    t_mco_service_name='pe-mcollective'
  else
    t_mco_service_name='mcollective'
  fi
  echo "${t_mco_service_name}"
}

mcollective_status() {
  output=$("$(puppet_bin_dir)/puppet" resource service "$(mcollective_service_name)" 2> /dev/null)
  case ${output?} in
    *ensure*=\>*running*)
      echo "running";;
    *)
      echo "stopped";;
  esac
}

ensure_service() {
    pkg=${1?}
    state=${2?}
    "$(puppet_bin_dir)/puppet" resource service "${pkg?}" ensure=${state?}
    return $?
}

wait_for_puppet_lock() {
  t_puppet_run_lock=`$(puppet_bin_dir)/puppet config print agent_catalog_run_lockfile`
  while [ -f "${t_puppet_run_lock?}" ]; do
      echo "Waiting for Agent run lock ${t_puppet_run_lock?} to clear..."
      sleep 10
  done
}

# In version 7.10.0 curl introduced the -k flag and performs peer
# certificate validation by default. If peer validation is performed by
# default the -k flag is necessary for this script to work. However, if curl
# is older than 7.10.0 the -k flag does not exist. This function will return
# the correct invocation of curl depending on the version installed.
curl_no_peer_verify() {
  curl_ver_regex='curl ([0-9]+)\.([0-9]+)\.([0-9]+)'
  [[ "$(curl -V 2>/dev/null)" =~ $curl_ver_regex ]]
  curl_majv="${BASH_REMATCH[1]-7}"  # Default to 7  if no match
  curl_minv="${BASH_REMATCH[2]-10}" # Default to 10 if no match
  if [[ "$curl_majv" -eq 7 && "$curl_minv" -le 9 ]] || [[ "$curl_majv" -lt 7 ]]; then
    curl_invocation="curl"
  else
    curl_invocation="curl -k"
  fi

  $curl_invocation "$@"
}

# Uses curl, or if not present, wget to download file from passed http url to a
# temporary location.
#
# Arguments
# 1. The url to download
# 2. The file to save it as
#
# Returns 0 or 1 if download fails.
download_from_url() {
    local t_url="${1?}"
    local t_file="${2?}"

    if cmd curl; then
        # curl on AIX doesn't support -k, but it's the default behavior
        if [ "$PLATFORM_NAME" = "aix" ]; then
          CURL="curl_no_peer_verify"
        else
          CURL="curl -k"
        fi
        t_http_code="$($CURL --tlsv1 -sLo "${t_file?}" "${t_url?}" --write-out %{http_code} || fail "curl failed to get ${t_url?}")"
    elif cmd wget; then
        # wget on AIX doesn't support SSL
        [ "$PLATFORM_NAME" = "aix" ] && fail "Unable to download installation materials without curl"

        # Run wget and use awk to figure out the HTTP status.
        t_http_code="$(wget --secure-protocol=TLSv1 -O "${t_file?}" --no-check-certificate -S "${t_url?}" 2>&1 | awk '/HTTP\/1.1/ { printf $2 }')"
        if [ -z "${t_file?}" ]; then
            fail "wget failed to get ${t_url?}"
        fi
    else
        fail "Unable to download installation materials without curl or wget"
    fi

    if [ "${t_http_code?}" == "200" ]; then
        return 0
    else
        return 1
    fi
}

supported_platform() {
  # Because of differences between how regex works between bash versions this
  # regex MUST be in a variable and passed into the test below UNQUOTED.
  t_supported_platform_regex='(el-(4|5|6|7)-(i386|x86_64|s390x))|(debian-(6|7|8)-(i386|amd64))|(ubuntu-(10\.04|12\.04|14\.04|15\.04|15\.10|16\.04)-(i386|amd64))|(sles-(10|11|12)-(i386|x86_64|s390x))|(fedora-(2[2-4])-(i386|x86_64))|(solaris-(10|11)-(i386|sparc))|(aix-(5\.3|6\.1|7\.1)-power)|(osx-10\.(9|10|11)-x86_64)'
  [[ "${1?}" =~ ${t_supported_platform_regex:?} ]]
}

run_agent_install_from_url() {
    t_agent_install_url="${1?}"

    t_install_file=$(mktempfile)
    if ! download_from_url "${t_agent_install_url?}" "${t_install_file?}"; then
        if supported_platform "${PLATFORM_TAG?}"; then
            fail "The agent packages needed to support ${PLATFORM_TAG} are not present on your master. \
    To add them, apply the pe_repo::platform::$(echo "${PLATFORM_TAG?}" | tr - _ | tr -dc '[:alnum:]_') class to your master node and then run Puppet. \
    The required agent packages should be retrieved when puppet runs on the master, after which you can run the install.bash script again."
        else
            fail "This method of agent installation is not supported for ${PLATFORM_TAG?} in Puppet Enterprise v2016.2.1"
        fi
    fi

    bash "${t_install_file?}" "${@: 2}" || fail "Error running install script ${t_install_file?}"
}

##############################################################################
# We need to know what the PE platform tag is for this node, which requires
# digging through a bunch of data to extract it.  This is currently the best
# mechanism available to do this, which is copied from the PE
# installer itself.
if [ -z "${PLATFORM_NAME:-""}" -o -z "${PLATFORM_RELEASE:-""}" ]; then
    # First try identifying using lsb_release.  This takes care of Ubuntu
    # (lsb-release is part of ubuntu-minimal).
    if type lsb_release > /dev/null 2>&1; then
        t_prepare_platform=`lsb_release -icr 2>&1`

        PLATFORM_NAME="$(printf "${t_prepare_platform?}" | grep -E '^Distributor ID:' | cut -s -d: -f2 | sed 's/[[:space:]]//' | tr '[[:upper:]]' '[[:lower:]]')"

        # Sanitize name for unusual platforms
        case "${PLATFORM_NAME?}" in
            redhatenterpriseserver | redhatenterpriseclient | redhatenterpriseas | redhatenterprisees | enterpriseenterpriseserver | redhatenterpriseworkstation | redhatenterprisecomputenode | oracleserver)
                PLATFORM_NAME=rhel
                ;;
            enterprise* )
                PLATFORM_NAME=centos
                ;;
            scientific | scientifics | scientificsl )
                PLATFORM_NAME=rhel
                ;;
            'suse linux' )
                PLATFORM_NAME=sles
                ;;
            amazonami )
                PLATFORM_NAME=amazon
                ;;
        esac

        # Release
        PLATFORM_RELEASE="$(printf "${t_prepare_platform?}" | grep -E '^Release:' | cut -s -d: -f2 | sed 's/[[:space:]]//g')"

        # Sanitize release for unusual platforms
        case "${PLATFORM_NAME?}" in
            centos | rhel )
                # Platform uses only number before period as the release,
                # e.g. "CentOS 5.5" is release "5"
                PLATFORM_RELEASE="$(printf "${PLATFORM_RELEASE?}" | cut -d. -f1)"
                ;;
            debian )
                # Platform uses only number before period as the release,
                # e.g. "Debian 6.0.1" is release "6"
                PLATFORM_RELEASE="$(printf "${PLATFORM_RELEASE?}" | cut -d. -f1)"
                if [ ${PLATFORM_RELEASE} = "testing" ] ; then
                    PLATFORM_RELEASE=7
                fi
                ;;
            'cumulus linux')
                PLATFORM_NAME="debian"
                PLATFORM_RELEASE="8"
                ;;
        esac
    elif [ "x$(uname -s)" = "xDarwin" ]; then
        PLATFORM_NAME="osx"
        # sw_vers returns something like 10.9.2, but we only want 10.9 so chop off the end
        t_platform_release="$(/usr/bin/sw_vers -productVersion | cut -d'.' -f1,2)"
        PLATFORM_RELEASE="${t_platform_release?}"
    # Test for Solaris.
    elif [ "x$(uname -s)" = "xSunOS" ]; then
        PLATFORM_NAME="solaris"
        t_platform_release="$(uname -r)"
        # JJM We get back 5.10 but we only care about the right side of the decimal.
        PLATFORM_RELEASE="${t_platform_release##*.}"
    elif [ "x$(uname -s)" = "xAIX" ] ; then
        PLATFORM_NAME="aix"
        t_platform_release="$(oslevel | cut -d'.' -f1,2)"
        PLATFORM_RELEASE="${t_platform_release}"

        # Test for RHEL variant. RHEL, CentOS, OEL
    elif [ -f /etc/redhat-release -a -r /etc/redhat-release -a -s /etc/redhat-release ]; then
        # Oracle Enterprise Linux 5.3 and higher identify the same as RHEL
        if grep -qi 'red hat enterprise' /etc/redhat-release; then
            PLATFORM_NAME=rhel
        elif grep -qi 'centos' /etc/redhat-release; then
            PLATFORM_NAME=centos
        elif grep -qi 'scientific' /etc/redhat-release; then
            PLATFORM_NAME=rhel
        elif grep -qi 'fedora' /etc/redhat-release; then
            PLATFORM_NAME='fedora'
        fi
        # Release - take first digits after ' release ' only.
        PLATFORM_RELEASE="$(sed 's/.*\ release\ \([[:digit:]]\+\).*/\1/g;q' /etc/redhat-release)"
        # Test for Cumulus releases
    elif [ -r "/etc/os-release" ] && grep -E "Cumulus Linux" "/etc/os-release" &> /dev/null ; then
        PLATFORM_NAME=cumulus
        PLATFORM_RELEASE=`grep -E "VERSION_ID" "/etc/os-release" | cut -d'=' -f2 | cut -d'.' -f'1,2'`
        # Test for Debian releases
    elif [ -f /etc/debian_version -a -r /etc/debian_version -a -s /etc/debian_version ]; then
        t_prepare_platform__debian_version_file="/etc/debian_version"
        t_prepare_platform__debian_version=`cat /etc/debian_version`

        if cat "${t_prepare_platform__debian_version_file?}" | grep -E '^[[:digit:]]' > /dev/null; then
            PLATFORM_NAME=debian
            PLATFORM_RELEASE="$(printf "${t_prepare_platform__debian_version?}" | sed 's/\..*//')"
        elif cat "${t_prepare_platform__debian_version_file?}" | grep -E '^wheezy' > /dev/null; then
            PLATFORM_NAME=debian
            PLATFORM_RELEASE="7"
        fi
    elif [ -f /etc/SuSE-release -a -r /etc/SuSE-release ]; then
        t_prepare_platform__suse_version=`cat /etc/SuSE-release`

        if printf "${t_prepare_platform__suse_version?}" | grep -E 'Enterprise Server'; then
            PLATFORM_NAME=sles
            t_version=`/bin/cat /etc/SuSE-release | grep VERSION | sed 's/^VERSION = \(\d*\)/\1/' `
            t_patchlevel=`cat /etc/SuSE-release | grep PATCHLEVEL | sed 's/^PATCHLEVEL = \(\d*\)/\1/' `
            PLATFORM_RELEASE="${t_version}"
        fi
    elif [ -f /etc/system-release ]; then
        if grep -qi 'amazon linux' /etc/system-release; then
            PLATFORM_NAME=amazon
            PLATFORM_RELEASE=6
        else
            fail "$(cat /etc/system-release) is not a supported platform for Puppet Enterprise v2016.2.1
                    Please visit http://links.puppetlabs.com/puppet_enterprise_${PE_LINK_VER?}_platform_support to request support for this platform."

        fi
    elif [ -z "${PLATFORM_NAME:-""}" ]; then
        fail "$(uname -s) is not a supported platform for Puppet Enterprise v2016.2.1
            Please visit http://links.puppetlabs.com/puppet_enterprise_${PE_LINK_VER?}_platform_support to request support for this platform."
    fi
fi

if [ -z "${PLATFORM_NAME:-""}" -o -z "${PLATFORM_RELEASE:-""}" ]; then
    fail "Unknown platform"
fi

# Architecture
if [ -z "${PLATFORM_ARCHITECTURE:-""}" ]; then
    case "${PLATFORM_NAME?}" in
        solaris | aix )
            PLATFORM_ARCHITECTURE="$(uname -p)"
            if [ "${PLATFORM_ARCHITECTURE}" = "powerpc" ] ; then
                PLATFORM_ARCHITECTURE='power'
            fi
            ;;
        *)
            PLATFORM_ARCHITECTURE="`uname -m`"
            ;;
    esac

    case "${PLATFORM_ARCHITECTURE?}" in
        x86_64)
            case "${PLATFORM_NAME?}" in
                ubuntu | debian )
                    PLATFORM_ARCHITECTURE=amd64
                    ;;
            esac
            ;;
        i686)
            PLATFORM_ARCHITECTURE=i386
            ;;
        ppc)
            PLATFORM_ARCHITECTURE=powerpc
            ;;
    esac
fi

# Tag
if [ -z "${PLATFORM_TAG:-""}" ]; then
    case "${PLATFORM_NAME?}" in
        # Enterprise linux (centos & rhel) share the same packaging
        # Amazon linux is similar enough for our packages
        rhel | centos | amazon )
            PLATFORM_TAG="el-${PLATFORM_RELEASE?}-${PLATFORM_ARCHITECTURE?}"
            ;;
        *)
            PLATFORM_TAG="${PLATFORM_NAME?}-${PLATFORM_RELEASE?}-${PLATFORM_ARCHITECTURE?}"
            ;;
    esac
fi

# This is the end of the code copied from the upstream installer.
##############################################################################



run_agent_install_from_url "https://oob-mgmt-server.lab.local:8140/packages/2016.2.1/${PLATFORM_TAG}.bash" "$@"
