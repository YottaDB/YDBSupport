#!/bin/sh
# ydb_support.sh - gathers information related to the system, database, and core files if applicable

# Copyright (C) 2018-2024 YottaDB, LLC
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

##? Usage:
##? ./ydb_support.sh [-f|--force] [-o|--outdir OUTPUT DIRECTORY]
##? sudo -E ./ydb_support.sh [-f|--force] [-o|--outdir OUTPUT DIRECTORY]
##?   [-p|--pid "PID OR CORE FILE"] [-h|--help]
##?   [-l|--logs-since "JOURNALCTL TIME FORMAT"]
##?   [-u|--logs-until "JOURNALCTL TIME FORMAT"]
##?   [-n|--no-logs]
##? 
##? where:
##?   -f|--force removes the output directory if it exists before starting, else an error will be emitted
##?   -o|--outdir <directory> the output directory to store files in before compressing
##?         DEFAULT ydb_support
##?   -p|--pid <pid or core> the PID or core file of a YDB/GTM process to get information from
##?   -h|--help displays this message
##?   -l|--logs-since <time spec> passed to journalctl (if present) to control starting time of logs
##?       DEFAULT: 2 hours ago
##?   -u|--logs-until <time spec> passed to journalctl (if present) to control topping time of logs
##?       DEFAULT: now
##?   -n|--no-logs if present, no information from the system beyond what is required for processing -p is collected
##? 
##? Running as root with sudo also captures dmesg output; running as a normal user does not. When
##? running with sudo, the -E option is important to capture environment variables.

usage() {
  grep "##?" "$0" | grep -v grep | cut -d\  -f 2-
  exit 1
}

run() {
  prog=$1
  shift
  prog_exists=$(command -v ${prog})
  echo "Command: $prog_exists $@"
  if [ "${prog_exists}" != "" ]; then
    $prog_exists "$@"
  else
    echo "Warning: command ${prog} not found"
  fi
}

run_if_root() {
  if [ 0 -eq $(id -u) ] ; then
    run "$@"
  else echo "Command $1 requires root; id is" $(id -un)
  fi
}

LOGS_SINCE="2 hours ago"
LOGS_UNTIL="now"
OUTDIR="ydb_support"
FORCE=0
PID=""
NO_LOGS=0

OPTS=$(getopt -o fo:p:hl:u:n --long force,outdir,pid,help,logs-since,logs-until,no-logs -n 'parse-options' -- "$@")

eval set -- "$OPTS"

while true; do
  case "$1" in
    -f | --force)
      FORCE=1
      shift
      ;;
    -l | --logs-since)
      LOGS_SINCE="${2}"
      shift
      shift
      ;;
    -u | --logs-until)
      LOGS_UNTIL="${2}"
      shift
      shift
      ;;
    -h | --help)
      usage
      shift
      ;;
    -o | --outdir)
      OUTDIR="${2}"
      shift
      shift
      ;;
    -p | --pid)
      PID="${2}"
      shift
      shift
      ;;
    -n | --no-logs)
      NO_LOGS=1
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      exit 1
      break
      ;;
  esac
done

if [ -e "${OUTDIR}" ]; then
  if [ "${FORCE}" -eq "1" ]; then
    rm -rf "${OUTDIR}"
  else
    echo "Specified output directory ${OUTDIR} already exists; please stash it somewhere" 1>&2
    echo "or use the -f / --force option to replace it." 1>&2
    exit 1
  fi
fi

mkdir -p "${OUTDIR}" || exit 1

if [ "${NO_LOGS}" -eq "0" ]; then
  echo "## Gathering system information"

  run uname -a > $OUTDIR/uname.txt 2>&1
  run lsb_release -a > $OUTDIR/lsb_release.txt 2>&1
  run cat /etc/os-release > $OUTDIR/os-release 2>&1
  run lscpu > $OUTDIR/lscpu.txt 2>&1
  run lsmem > $OUTDIR/lsmem.txt 2>&1
  run lsblk > $OUTDIR/lsblk.txt 2>&1

  echo "## Gathering environment variables, omitting keys, passphrases, and passwords"
  echo "Command: env | grep -Eiv \(key\)\|\(passp\)\|\(passw\) | sort" > $OUTDIR/env.txt 2>&1
  env | grep -Eiv \(key\)\|\(passp\)\|\(passw\) | sort >> $OUTDIR/env.txt 2>&1

  echo "## Gathering system logs"

  journalctl=$(command -v journalctl)

  if [ "$journalctl" != "" ]; then
    run journalctl --since "${LOGS_SINCE}" --until "${LOGS_UNTIL}" > $OUTDIR/journalctl.log
  else
    # Limited support for this case; just grab the latest files from /var/log
    run cp /var/log/syslog $OUTDIR/
  fi

  run_if_root dmesg > $OUTDIR/dmesg.log 2>&1

  if [ ! -z "$ydb_dist" ] ; then dist_dir=$ydb_dist
  elif [ ! -z "$gtm_dist" ] ; then dist_dir=$gtm_dist
  else
    script_dir=$(realpath $(dirname $0))
    if [ -x $script_dir/mumps ] ; then dist_dir=$script_dir
    elif [ -x $script_dir/../mumps ] ; then dist_dir=$script_dir/..
    else
      if [ -f /usr/share/pkgconfig/yottadb.pc ] ; then
	dist_dir=$(grep ^prefix= /usr/share/pkgconfig/yottadb.pc | cut -d = -f 2)
	if [ ! -d "$dist_dir" ] ; then
	  echo "## Warning: /usr/share/pkgconfig/yottadb.pc says YottaDB/GT.M is installed at $dist_dir"
	  echo "## but such a directory does not exist."
	  unset dist_dir
	fi
      fi
    fi
  fi

  if [ "$dist_dir" = "" ]; then
    echo "## Warning: Could not locate a YottaDB or GT.M distribution"
  else
    dist_dir=$(realpath $dist_dir)
    echo "## YottaDB/GT.M distribution is at $dist_dir"
    echo "## Gathering information about the database"

    if [ -e $dist_dir/yottadb ] ; then pgm=yottadb
    else pgm=mumps
    fi

    run $dist_dir/$pgm -r %XCMD 'write $ZVERSION,!' > $OUTDIR/zversion.txt 2>&1
    if [ "yottadb" = $pgm ] ; then run $dist_dir/$pgm -r %XCMD 'write $zyrelease,!' >$OUTDIR/zyrelease.txt 2>&1 ; fi

    gbldir="$ydb_gbldir"

    if [ "${gbldir}" = "" ]; then
      gbldir="$gtmgbldir"
    fi

    if [ "${gbldir}" = "" ]; then
      echo "## Warning: neither ydb_gbldir nor gtmgbldir environment variables are set, so no database is available"
    else
      run echo "${gbldir}" > $OUTDIR/global_dir.txt
      run $dist_dir/$pgm -run GDE show -command > $OUTDIR/gde_show_command.txt 2>&1
      # Get DSE output even if MUPIP DUMPHEAD is available, as it is easier to read
      run ${dist_dir}/dse all -dump -all > $OUTDIR/dse_all_dump_all.txt 2>&1
      version=$(tail -1 $OUTDIR/zversion.txt)
      mupip_dumpfhead_added_after="GT.M V6.3-001A"
      if [ "$version" \> "$mupip_dumpfhead_added_after" ]; then
        run ${dist_dir}/mupip dumpfhead -reg '*' > $OUTDIR/mupip_dumpfhead.txt 2>&1
      fi
    fi
  fi

  echo "## Getting filesystem information"
  echo "Command: df | grep ^/dev/[^l]" > $OUTDIR/df.txt 2>&1
  df | grep ^/dev/[^l] >> $OUTDIR/df.txt 2>&1
  run grep ^/dev/[^l] /etc/mtab > $OUTDIR/mtab.txt 2>&1

fi

if [ "${PID}" != "" ]; then
  if [ -e "${PID}" ]; then
    echo "## Analyzing core file"
    outfn="$OUTDIR/file_on_$(basename $PID).txt"
    run file ${PID} > "$outfn"
    pid_exec=$(cat "$outfn" | tr ',' '\n' | grep execfn | awk '{print $2}')
    pid_exec=$(echo $pid_exec | sed "s/'//g")
  else
    echo "## Analyzing active process"
    pid_exec=$(realpath /proc/${PID}/exe)
  fi
  if [ -f "${pid_exec}" ]; then
    out_fn="$OUTDIR/gdb_$(basename $PID).txt"
    run gdb "${pid_exec}" "${PID}" -ex "set confirm off" -ex "set print elements 8192" -ex "set print repeats 8192" -ex "backtrace" -ex "quit" > $out_fn 2>&1
    # For each from in the core, print locals (max at 20 frames)
    # This count is one higher than the actual due to gdb formating
    frame_count=$(grep -c -e "^#[0-9]\\+" $out_fn)
    gdb_arg="-ex \"set print elements 8192\""		# display upto 8192 bytes of a string (default is to truncate a large
    							# string to just 200 bytes) as we might need to see the entire string
							# for example in case it is an Octo SQL query.
    gdb_arg="$gdb_arg -ex \"set print repeats 8192\""	# print every repeating consecutive byte of string upto a max of 8192
    							# instead of the default 10; this helps see the entire string in a
							# copy-pasteable manner instead of seeing a broken sequence of the actual
							# string followed by say a "<repeated 20 times>" string in between.
    # Minus 2 to account for the 0 offset expr counting to n, inclusive
    # If frame count is less than 100 just print all of them in order
    if [ 100 -gt $frame_count ]; then
      for i in $(seq 0 $(expr $frame_count - 2)); do
        gdb_arg="$gdb_arg -ex \"frame $i\" -ex \"info locals\" -ex \"info registers\""
      done
    else
      # Bottom 50 frames
      for i in $(seq 0 49); do
        gdb_arg="$gdb_arg -ex \"frame $i\" -ex \"info locals\" -ex \"info registers\""
      done
      # Top 50 frames
      for i in $(seq $(expr $frame_count - 50) $(expr $frame_count - 2)); do
        gdb_arg="$gdb_arg -ex \"frame $i\" -ex \"info locals\" -ex \"info registers\""
      done
    fi
    gdb_arg="$gdb_arg -ex \"quit\""
    run echo $gdb_arg | run xargs -- gdb "${pid_exec}" "${PID}" >> $out_fn 2>&1
  else
    echo "## Warning: failed to find executable for $PID"
  fi
fi

echo "## Done getting information, packing tarball"

tar -czf ${OUTDIR}.tar.gz ${OUTDIR}

echo "## Done! Please review the files in ${OUTDIR} to make sure that they only contain metadata"
echo "## that can be sent. If not, please edit them as needed, and run the command"
echo "##   tar -czf ${OUTDIR}.tar.gz ${OUTDIR}"
echo "## to recreate ${OUTDIR}.tar.gz. Send ${OUTDIR}.tar.gz and a description of your problem to your"
echo "## YottaDB support channel, as well as the severity (impact), scope, and timeframes. You can"
echo "## remove the directory ${OUTDIR} afterwards. Thank you."
