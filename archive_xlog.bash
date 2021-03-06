#!@BASH@
#
# Copyright 2011-2013 Nicolas Thauvin. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 
#  1. Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#  2. Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHORS ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#

# Message functions
error() {
    echo "ERROR: $1" 1>&2
}

# Script help
usage() {
    echo "usage: `basename $0` [options] XLOGFILE"
    echo "options:"
    echo "    -L             do local archiving"
    echo "    -C conf        configuration file"
    echo "    -u username    username for SSH login"
    echo "    -h hostname    hostname for SSH login"
    echo "    -d dir         target directory"
    echo "    -X             do not compress"
    echo "    -S             send messages to syslog"
    echo "    -f facility    syslog facility"
    echo "    -t ident       syslog ident"
    echo
    echo "    -?             print help"
    echo
    exit $1
}

# Configuration defaults
CONFIG=pitr.conf
CONFIG_DIR=@SYSCONFDIR@
ARCHIVE_DIR=/var/lib/pgsql/archived_xlog
ARCHIVE_LOCAL="no"
SYSLOG="no"
ARCHIVE_COMPRESS="yes"

# Internal configuration
COMPRESS_BIN="gzip -f -4"
COMPRESS_SUFFIX="gz"

# Command line options
args=`getopt "LC:u:d:h:XSf:t:?" "$@"`
if [ $? -ne 0 ]
then
    usage 2
fi

set -- $args
for i in $*
do
    case "$i" in
        -L) CLI_ARCHIVE_LOCAL="yes"; shift;;
	-C) CONFIG=$2; shift 2;;
	-u) CLI_ARCHIVE_USER=$2; shift 2;;
	-h) CLI_ARCHIVE_HOST=$2; shift 2;;
	-d) CLI_ARCHIVE_DIR=$2; shift 2;;
	-X) CLI_ARCHIVE_COMPRESS="no"; shift;;
	-S) CLI_SYSLOG="yes"; shift;;
	-f) CLI_SYSLOG_FACILITY=$2; shift 2;;
	-t) CLI_SYSLOG_IDENT=$2; shift 2;;
        -\?) usage 1;;
        --) shift; break;;
    esac
done

# The first argument must be a WAL file
if [ $# != 1 ]; then
    error "missing xlog filename to archive. Please consider modifying archive_command, eg add %p"
    exit 1
fi

xlog=$1

# check if the config option is a path or in the current directory
# otherwise prepend the configuration directory and .conf
echo $CONFIG | grep -q '\/'
if [ $? != 0 ] && [ ! -f $CONFIG ]; then
    CONFIG="$CONFIG_DIR/`basename $CONFIG .conf`.conf"
fi

# Load configuration file
if [ -f "$CONFIG" ]; then
    . $CONFIG
fi

# Overwrite configuration with cli options
[ -n "$CLI_ARCHIVE_LOCAL" ] && ARCHIVE_LOCAL=$CLI_ARCHIVE_LOCAL
[ -n "$CLI_ARCHIVE_USER" ] && ARCHIVE_USER=$CLI_ARCHIVE_USER
[ -n "$CLI_ARCHIVE_HOST" ] && ARCHIVE_HOST=$CLI_ARCHIVE_HOST
[ -n "$CLI_ARCHIVE_DIR" ] && ARCHIVE_DIR=$CLI_ARCHIVE_DIR
[ -n "$CLI_ARCHIVE_COMPRESS" ] && ARCHIVE_COMPRESS=$CLI_ARCHIVE_COMPRESS
[ -n "$CLI_SYSLOG" ] && SYSLOG=$CLI_SYSLOG
[ -n "$CLI_SYSLOG_FACILITY" ] && SYSLOG_FACILITY=$CLI_SYSLOG_FACILITY
[ -n "$CLI_SYSLOG_IDENT" ] && SYSLOG_IDENT=$CLI_SYSLOG_IDENT

# Redirect output to syslog if configured
if [ "$SYSLOG" = "yes" ]; then
    SYSLOG_FACILITY=${SYSLOG_FACILITY:-local0}
    SYSLOG_IDENT=${SYSLOG_IDENT:-postgres}

    exec 1> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.info)
    exec 2> >(logger -t ${SYSLOG_IDENT} -p ${SYSLOG_FACILITY}.err)
fi

# Sanity check. We need at least to know if we want to perform a local
# copy or have a hostname for an SSH copy
if [ $ARCHIVE_LOCAL != "yes" -a -z "$ARCHIVE_HOST" ]; then
    error "Not enough information to archive the segment"
    exit 1
fi

# Check if the source file exists
if [ -z "$xlog" ]; then
    error "Empty input filename"
    exit 1
fi

if [ ! -r $xlog ]; then
    error "Input file does not exist or is not readable"
    exit 1
fi
    

# Copy the wal locally
if [ $ARCHIVE_LOCAL = "yes" ]; then
    mkdir -p $ARCHIVE_DIR 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to create target directory"
	exit $rc
    fi

    cp $xlog $ARCHIVE_DIR 1>&2
    rc=$?
    if [ $rc != 0 ]; then
	error "Unable to copy $xlog to $ARCHIVE_DIR"
	exit $rc
    fi

    if [ $ARCHIVE_COMPRESS = "yes" ]; then
	dest_path=$ARCHIVE_DIR/`basename $xlog`
	$COMPRESS_BIN $dest_path
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to compress $dest_path"
	    exit $rc
	fi
    fi

else
    # Compress and copy with scp
    echo $ARCHIVE_HOST | grep -q ':' && ARCHIVE_HOST="[${ARCHIVE_HOST}]" # Dummy test for IPv6

    if [ $ARCHIVE_COMPRESS = "yes" ]; then
	file=/tmp/`basename $xlog`.$COMPRESS_SUFFIX
	# We take no risk, pipe the content to the compression program
	# and save output elsewhere: the compression program never
	# touches the input file
	$COMPRESS_BIN -c < $xlog > $file
	rc=$?
	if [ $rc != 0 ]; then
	    error "Compression to $file failed"
	    exit $rc
	fi

	# Using a temporary file is mandatory for rsync. Rsync is the
	# safest way to archive, the file is transfered under a
	# another name then moved to the target name when complete,
	# partly copied files should not happen.
	rsync -a $file ${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}:${ARCHIVE_DIR:-'~'}/
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync the compressed file to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    exit $rc
	fi

	rm $file
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to remove temporary compressed file"
	    exit $rc
	fi
    else
	rsync -a $xlog ${ARCHIVE_USER:+$ARCHIVE_USER@}${ARCHIVE_HOST}:${ARCHIVE_DIR:-'~'}/
	rc=$?
	if [ $rc != 0 ]; then
	    error "Unable to rsync $xlog to ${ARCHIVE_HOST}:${ARCHIVE_DIR}"
	    exit $rc
	fi
    fi
fi

exit 0
