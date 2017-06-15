#!/usr/bin/env bash

# backup.sh \
#   --wp /home/www/foo/deploy/current/web/wp \
#   --customer foo \
#   --remote backup.genero.fi \
#   --db-days 30
#   --files-months 3
#   --files-weeks 3
#   --files-days 6
#   --dir /home/www/foo/deploy/shared/web/app/uploads
#   --dir /home/www/foo/deploy/shared/web/app/uploads2

[[ $UID -eq 0 ]] && echo "You should not run this script as root, use the deploy user." >&2 && exit 1

TIME=$(date +%Y%m%d_%H%M%S)
WEEK=$(date +%V)
MONTH=$(date +%m)
WEEKDAY=$(date +%u)
DAY=$(date +%d)
YESTERDAY=$(date -d 'yesterday' +%u)

WP_BIN=${WPCLI_BIN:-/usr/local/bin/wp}
RSYNC_BIN=${RSYNC_BIN:-/usr/bin/rsync}
TEMP_BACKUP_DIR=${TEMP_BACKUP_DIR:-$HOME/backups}
REMOTE_BACKUP_DIR=${REMOTE_BACKUP_DIR:-/var/www/backup}
LOGFILE=/tmp/backup.log
LOGFILE_NUM_LINES=1000
PUB_KEY=~/.ssh/backup.pub.pem

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

prune() {
  local remote=$1
  local dir=$2
  local count=$3

  # Tail needs this incremented by one.
  ((count++))

  ssh $remote "cd $dir; ls -tp | tail -n +$count | xargs -d '\n' rm -rf --;"
}

sync() {
  local remote=$1
  local source=$2
  local target=$3
  ssh $remote rsync -aq --delete $source/ $target/
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
    --wp=*) wp_path=${1#*=} ;;
    --wp) shift; wp_path=$1 ;;

    --customer=*) customer=${1#*=} ;;
    --customer) shift; customer=$1 ;;

    --remote=*) remote=${1#*=} ;;
    --remote) shift; remote=$1 ;;

    --dir=*) dirs=${1#*=} ;;
    --dir) shift; dirs+=($1) ;;

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

    --public-key=*) PUB_KEY=${1#*=} ;;
    --public-key) shift; PUB_KEY=$1 ;;

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


  if [ ! -d $TEMP_BACKUP_DIR/db ]; then
    mkdir -p $TEMP_BACKUP_DIR/db || exit 1
  fi

  backup_db_file=$TEMP_BACKUP_DIR/db/$customer-db-$TIME.sql.gz.enc
  remote_backup_db_dir=$REMOTE_BACKUP_DIR/$customer/db
  remote_backup_files_dir=$REMOTE_BACKUP_DIR/$customer/files

  # Export database
  tries=0
  # Make 3 attempts to ensure the file exists and isn't empty.
  while [ ! -e $backup_db_file -o ! -s $backup_db_file ] && [[ $tries -lt 3 ]]; do
    $WP_BIN --path="$wp_path" db export - \
      | gzip -f -6 \
      | openssl smime -encrypt -binary -text -aes256 -out $backup_db_file -outform DER $PUB_KEY
    ((tries++))
  done

  if [[ ! -e $backup_db_file ]] || [[ ! -s $backup_db_file ]]; then
    err "database dump failed"
    exit 1
  fi

  ssh $remote mkdir -p $remote_backup_db_dir/daily/$WEEKDAY
  ssh $remote mkdir -p $remote_backup_db_dir/weekly/$WEEK
  ssh $remote mkdir -p $remote_backup_db_dir/monthly/$MONTH

  # Daily database backup.
  log "Daily database backup ($WEEKDAY) for $customer. Keeping $DB_DAYS_STORED days."
  $RSYNC_BIN -aqz --delete -e 'ssh' $TEMP_BACKUP_DIR/db/ $remote:$remote_backup_db_dir/daily/$WEEKDAY/

  # Weekly database backup.
  if [[ "$DB_WEEKS_STORED" != "0" ]]; then
    log "Weekly database backup ($WEEK) for $customer. Keeping $DB_WEEKS_STORED weeks."
    sync $remote $remote_backup_db_dir/daily/$WEEKDAY $remote_backup_db_dir/weekly/$WEEK
  fi

  # Monhtly database backup.
  if [[ "$DB_MONTHS_STORED" != "0" ]]; then
    log "Monthly database backup ($MONTH) for $customer. Keeping $DB_MONTHS_STORED months."
    sync $remote $remote_backup_db_dir/daily/$WEEKDAY $remote_backup_db_dir/monthly/$MONTH
  fi

  prune $remote $remote_backup_db_dir/daily $DB_DAYS_STORED
  prune $remote $remote_backup_db_dir/weekly $DB_WEEKS_STORED
  prune $remote $remote_backup_db_dir/monthly $DB_MONTHS_STORED

  # Remove local database dump.
  rm -rf $TEMP_BACKUP_DIR/
fi

# If one or multiple --dir
if [ ${#dirs[@]} -ne 0 ]; then

  if [ $FILES_DAYS_STORED -eq 0 ]; then
    err "Need at least one daily copy."
    exit 1
  fi

  # Re-use yesterday's files.
  ssh $remote mkdir -p $remote_backup_files_dir/daily
  commands=$(cat <<EOF
    if [ ! -d $remote_backup_files_dir/daily/$WEEKDAY ] && [ -d $remote_backup_files_dir/daily/$YESTERDAY ]; then
      cp -r $remote_backup_files_dir/daily/$YESTERDAY $remote_backup_files_dir/daily/$WEEKDAY;
    fi
EOF
)
  ssh $remote "$commands"
  ssh $remote mkdir -p $remote_backup_files_dir/daily/$WEEKDAY
  ssh $remote mkdir -p $remote_backup_files_dir/weekly/$WEEK
  ssh $remote mkdir -p $remote_backup_files_dir/monthly/$MONTH

  # Daily files backup.
  log "Daily files backup ($WEEKDAY) for $customer. Keeping $FILES_DAYS_STORED days."
  # Backup directories.
  for dir in "${dirs[@]}"; do
    $RSYNC_BIN -aqz -e 'ssh' --no-perms --no-owner --no-group --delete \
      --exclude '*.webp' \
      --exclude '*.php' \
      --exclude '*-c-center.jpg'  --exclude '*-c-center.png' \
      --exclude '*-c-default.jpg' --exclude '*-c-default.png' \
      --exclude '*-c-1.jpg'       --exclude '*-c-1.png' \
      --exclude '*-??x??.jpg'     --exclude '*-??x??.png' \
      --exclude '*-??x???.jpg'    --exclude '*-??x???.png' \
      --exclude '*-???x??.jpg'    --exclude '*-???x??.png' \
      --exclude '*-???x???.jpg'   --exclude '*-???x???.png' \
      --exclude '*-???x????.jpg'  --exclude '*-???x????.png' \
      --exclude '*-????x???.jpg'  --exclude '*-????x???.png' \
      --exclude '*-????x????.jpg' --exclude '*-????x????.png' \
      --prune-empty-dirs \
      -- "$dir" "$remote:$remote_backup_files_dir/daily/$WEEKDAY"
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
    sync $remote $remote_backup_files_dir/daily/$WEEKDAY $remote_backup_files_dir/weekly/$WEEK
  fi

  # Monthly files backup.
  if [ $FILES_MONTHS_STORED -ne 0 ]; then
    log "Monthly files backup ($MONTH) for $customer. Keeping $FILES_MONTHS_STORED months."
    sync $remote $remote_backup_files_dir/daily/$WEEKDAY $remote_backup_files_dir/monthly/$MONTH
  fi

  prune $remote $remote_backup_files_dir/daily $FILES_DAYS_STORED
  prune $remote $remote_backup_files_dir/weekly $FILES_WEEKS_STORED
  prune $remote $remote_backup_files_dir/monthly $FILES_MONTHS_STORED

fi
