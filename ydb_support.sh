#!/bin/sh
# ydb_support.sh - gathers information related to the system, database, and core files if applicable

# Copyright (C) 2018-2019 YottaDB, LLC
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
    exit 1
  fi
fi

mkdir -p "${OUTDIR}" || exit 1

if [ "${NO_LOGS}" -eq "0" ]; then
  echo "## Gathering system information"

  run uname -a > $OUTDIR/uname.txt 2>&1
  run lsb_release -a > $OUTDIR/lsb_release.txt 2>&1
  run cat /etc/os-release > $OUTDIR/os-release 2>&1

  echo "## Gathering system logs"

  journalctl=$(command -v journalctl)

  if [ "$journalctl" != "" ]; then
    run journalctl --since "${LOGS_SINCE}" --until "${LOGS_UNTIL}" > $OUTDIR/journalctl.log
  else
    # Limited support for this case; just grab the latest files from /var/log
    run cp /var/log/syslog $OUTDIR/
  fi

  run dmesg > $OUTDIR/dmesg.log 2>&1


  dist_dir="$ydb_dist"

  if [ "$dist_dir" = "" ]; then
    dist_dir="$gtm_dist"
  fi

  if [ "$dist_dir" = "" ]; then
    echo "## Warning: neither ydb_dist nor gtm_dist environment variables are set, so we can not get database information"
  else
    echo "## Gathering information about database"

    run $dist_dir/mumps -r %XCMD 'write $ZVERSION' > $OUTDIR/zversion.txt 2>&1

    gbldir="$ydb_gbldir"

    if [ "${gbldir}" = "" ]; then
      gbldir="$gtmgbldir"
    fi

    if [ "${gbldir}" = "" ]; then
      echo "## Warning: neither ydb_gbldir nor gbldir environment variables are set, so we can not get database information"
    else
      run echo "${gbldir}" > $OUTDIR/global_dir.txt
      run $dist_dir/mumps -run GDE show -command > $OUTDIR/gde_show_command.txt 2>&1
      version=$(cat $OUTDIR/zversion.txt)
      mupip_dumpfhead_added_in="GT.M V6.3-001A"
      if [ "$version" \< "$mupip_dumpfhead_added_in" ]; then
        run ${dist_dir}/dse all -dump -all > $OUTDIR/dse_all_dump_all.txt 2>&1
      else
        run ${dist_dir}/mupip dumpfhead -reg '*' > $OUTDIR/mupip_dumpfhead.txt 2>&1
      fi
    fi
  fi

  echo "## Getting filesystem information"
  run df > $OUTDIR/df.txt 2>&1
  run fdisk -l > $OUTDIR/fdisk.txt 2>&1
  run grep ^/dev /etc/mtab > $OUTDIR/mtab.txt 2>&1

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
    pid_exec=$(readlink -f /proc/${PID}/exe)
  fi
  if [ -f "${pid_exec}" ]; then
    out_fn="$OUTDIR/gdb_$(basename $PID).txt"
    run gdb "${pid_exec}" "${PID}" -ex "set print elements 0" -ex "set print repeats 0" -ex "backtrace" -ex "quit" > $out_fn 2>&1
    # For each from in the core, print locals (max at 20 frames)
    # This count is one higher than the actual due to gdb formating
    frame_count=$(grep -c -e "^#[0-9]\\+" $out_fn)
    gdb_arg="-ex \"set print elements 0\""	# display entire string instead of truncating it at 200 bytes by default
    gdb_arg="$gdb_arg -ex \"set print repeats 0\""	# display entire string instead of printing <repeated 20 times> etc.
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

echo "## Done! Please send ${OUTDIR}.tar.gz and a description of your problem to your YottaDB support channel; make sure to include a description of the problem, severity, scope, and timeframes"
