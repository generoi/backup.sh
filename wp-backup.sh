#!/usr/bin/env bash

# backup.sh \
#   --wp /home/www/foo/deploy/current/web/wp \
#   --customer foo \
#   --remote minasithil.genero.fi \
#   --db-days 30
#   --files-months 3
#   --files-weeks 3
#   --files-days 6
#   --dir /home/www/foo/deploy/shared/web/app/uploads
#   --dir /home/www/foo/deploy/shared/web/app/uploads2

[[ $UID -eq 0 ]] && echo "You should not run this script as root, use the deploy user." >&2 && exit 1

TIME="$(date +%Y%m%d_%H%M%S)"
WEEK="$(date +%V)"
MONTH="$(date +%m)"
DAY="$(date +%u)"
YESTERDAY="$(date -d 'yesterday' +%u)"

WP_BIN="${WPCLI_BIN:-/usr/local/bin/wp}"
RSYNC_BIN="${RSYNC_BIN:-/usr/bin/rsync}"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
LOGFILE="/tmp/backup.log"
LOGFILE_NUM_LINES=1000

DB_MONTHS_STORED=4
DB_WEEKS_STORED=4
DB_DAYS_STORED=6

FILES_MONTHS_STORED=4
FILES_WEEKS_STORED=4
FILES_DAYS_STORED=6

log() {
  tmp=$(tail -n $LOGFILE_NUM_LINES $LOGFILE 2>/dev/null) && echo "$tmp" > $LOGFILE
  message="[$(date --rfc-3339=seconds)]: $*"
  if (($quiet)); then
    echo "$message" >> $LOGFILE
  else
    echo "$message" | tee $LOGFILE
  fi
}
err() { log "ERROR: $@"; } >&2

remove_expired_backups() {
  local dir="$1"
  local count="$2"
  local remote="$3"

  # Tail needs this incremented by one.
  ((count++))

  ssh "$remote" "cd $dir; ls -tp | tail -n +$count | xargs -d '\n' rm -rf --;"
}

backup_existing() {
  local source="$1"
  local target="$2"
  ssh "$remote" rsync -aq --delete $source/ $target/
}

args=()
wp_path=
customer=
remote=
skip_db=
quiet=0
dirs=()

# Process and remove all flags.
while (($#)); do
  case $1 in
    --wp=*) wp_path="${1#*=}" ;;
    --wp) shift; wp_path="$1" ;;

    --customer=*) customer="${1#*=}" ;;
    --customer) shift; customer="$1" ;;

    --remote=*) remote="${1#*=}" ;;
    --remote) shift; remote="$1" ;;

    --dir=*) dirs="${1#*=}" ;;
    --dir) shift; dirs+=("$1") ;;

    --db-months=*) DB_MONTHS_STORED=${1#*=} ;;
    --db-months) shift; DB_MONTHS_STORED=$1 ;;

    --db-weeks=*) DB_WEEKS_STORED=${1#*=} ;;
    --db-weeks) shift; DB_WEEKS_STORED=$1 ;;

    --db-days=*) DB_DAYS_STORED=${1#*=} ;;
    --db-days) shift; DB_DAYS_STORED=$1 ;;

    --files-months=*) FILES_MONTHS_STORED=${1#*=} ;;
    --files-months) shift; FILES_MONTHS_STORED=$1 ;;

    --files-weeks=*) FILES_WEEKS_STORED=${1#*=} ;;
    --files-weeks) shift; FILES_WEEKS_STORED=$1 ;;

    --files-days=*) FILES_DAYS_STORED=${1#*=} ;;
    --files-days) shift; FILES_DAYS_STORED=$1 ;;

    --no-db) skip_db=1 ;;

    -s|--silent|-q|--quiet) quiet=1 ;;

    -*) err "invalid option: $1"; exit 1 ;;
    *) args+=("$1") ;;
  esac
  shift
done

# Restore the arguments without flags.
set -- "${args[@]}"

if [ -z "$customer" ]; then
  err "--customer is required."
  exit 1
fi

if [ -z "$remote" ]; then
  err "--remote is required."
  exit 1
fi

# Unless --skip-db
if ! (($skip_db)); then
  if [ -z "$wp_path" ]; then
    wp_path="/home/www/${customer}/deploy/current/web/wp"
  fi

  if [ ! -d "$wp_path" ]; then
    err "could not find wp installation path."
    exit 1
  fi

  if [ $DB_DAYS_STORED -eq 0 ]; then
    err "Need at least one daily copy."
    exit 1
  fi


  if [ ! -d "$BACKUP_DIR/db" ]; then
    mkdir -p $BACKUP_DIR/db || exit 1
  fi

  backup_db_file="$BACKUP_DIR/db/$customer-db-$TIME.sql.gz"
  remote_backup_db_dir="~/backups/$customer/db"
  remote_backup_files_dir="~/backups/$customer/files"

  # Export database
  tries=0
  # Make 3 attempts to ensure the file exists and isn't empty.
  while [ ! -e $backup_db_file -o ! -s $backup_db_file ] && [[ $tries -lt 3 ]]; do
    $WP_BIN --path="$wp_path" db export - | gzip -f -6 >| $backup_db_file
    ((tries++))
  done

  if [[ ! -e $backup_db_file ]] || [[ ! -s $backup_db_file ]]; then
    err "database dump failed"
    exit 1
  fi

  # Daily database backup.
  log "Daily database backup ($DAY) for $customer. Keeping $DB_DAYS_STORED days."

  ssh "$remote" mkdir -p $remote_backup_db_dir/day/$DAY;
  remove_expired_backups "$remote_backup_db_dir/day" "$DB_DAYS_STORED" "$remote"
  $RSYNC_BIN -aqz --delete -e 'ssh' "$BACKUP_DIR/db/" "$remote:$remote_backup_db_dir/day/$DAY/"

  # Weekly database backup.
  if [ $DB_WEEKS_STORED -ne 0 ]; then
    log "Weekly database backup ($WEEK) for $customer. Keeping $DB_WEEKS_STORED weeks."

    ssh "$remote" mkdir -p $remote_backup_db_dir/week/$WEEK;
    remove_expired_backups "$remote_backup_db_dir/week" "$DB_WEEKS_STORED" "$remote"
    backup_existing "$remote_backup_db_dir/day/$DAY" "$remote_backup_db_dir/week/$WEEK"
  fi

  # Monhtly database backup.
  if [ $DB_MONTHS_STORED -ne 0 ]; then
    log "Monthly database backup ($MONTH) for $customer. Keeping $DB_MONTHS_STORED months."

    ssh "$remote" mkdir -p $remote_backup_db_dir/month/$MONTH;
    remove_expired_backups "$remote_backup_db_dir/month" "$DB_MONTHS_STORED" "$remote"
    backup_existing "$remote_backup_db_dir/day/$DAY" "$remote_backup_db_dir/month/$MONTH"
  fi

  # Remove local database dump.
  rm -rf $BACKUP_DIR/
fi

# If one or multiple --dir
if [ ${#dirs[@]} -ne 0 ]; then

  if [ $FILES_DAYS_STORED -eq 0 ]; then
    err "Need at least one daily copy."
    exit 1
  fi

  # Daily files backup.
  log "Daily files backup ($DAY) for $customer. Keeping $FILES_DAYS_STORED days."
  commands=$(cat <<EOF
    mkdir -p $remote_backup_files_dir/day;

    # Re-use old files if available.
    if [ ! -d $remote_backup_files_dir/day/$DAY ] && [ -d $remote_backup_files_dir/day/$YESTERDAY ]; then
      cp -r $remote_backup_files_dir/day/$YESTERDAY $remote_backup_files_dir/day/$DAY;
    fi;

    # Ensure the directory exists.
    mkdir -p $remote_backup_files_dir/day/$DAY;
EOF
)
  ssh "$remote" "$commands"
  remove_expired_backups "$remote_backup_files_dir/day" "$FILES_DAYS_STORED" "$remote"

  # Backup directories.
  for dir in "${dirs[@]}"; do
    $RSYNC_BIN -aqz -e 'ssh' --delete "$dir" "$remote:$remote_backup_files_dir/day/$DAY"
    rsync_rc=$?

    if [[ $rsync_rc -eq 0 ]]; then
      log "Backed up directory $dir successfully."
    else
      err "Backing up directory $dir failed with return code $rsync_rc."
    fi
  done

  # Weekly files backup.
  if [ $FILES_WEEKS_STORED -ne 0 ]; then
    log "Weekly files backup ($WEEK) for $customer. Keeping $FILES_WEEKS_STORED weeks."
    ssh "$remote" mkdir -p $remote_backup_files_dir/week/$WEEK;
    remove_expired_backups "$remote_backup_files_dir/week" "$FILES_WEEKS_STORED" "$remote"
    backup_existing "$remote_backup_files_dir/day/$DAY" "$remote_backup_files_dir/week/$WEEK"
  fi

  # Monthly files backup.
  if [ $FILES_MONTHS_STORED -ne 0 ]; then
    log "Monthly files backup ($MONTH) for $customer. Keeping $FILES_MONTHS_STORED months."
    ssh "$remote" mkdir -p $remote_backup_files_dir/month/$MONTH;
    remove_expired_backups "$remote_backup_files_dir/month" "$FILES_MONTHS_STORED" "$remote"
    backup_existing "$remote_backup_files_dir/day/$DAY" "$remote_backup_files_dir/month/$MONTH"
  fi
fi
