# backup.sh

## Installation

To make the executables (`wp-backup.sh` at the moment) available globally in every user's `PATH` run:

```sh
cd /usr/local/lib
git clone https://github.com/generoi/backup.sh
cd backup.sh
make install
```

The script requires a public key to encrypt database dumps. By default the script assumes this will be located in `~/.ssh/backup.pub.pem` of the running user.

### To fetch updates

```sh
cd /usr/local/lib/backup.sh
git pull origin master
make update
```

## Usage

This script should be ran as a cron job, once a night. For example at 3am every night:

```
0 3 * * * /usr/local/bin/wp-backup.sh -q --customer nooga --remote backup.genero.fi --dir /home/www/nooga/deploy/shared/web/app/uploads --public-key /home/deploy/.ssh/backup.pub.pem
```

### Options

```
# Required
--customer           Customer name (used for default wp path)
--remote             Remote host where backups will be sent

# Optional
--wp                 Path to the Wordpress core files
--dir                Directory to backup, can be multiple
--(db|files)-months  Amount of mothly backups to save (default: 4)
--(db|files)-weeks   Amount of weekly backups to save (default: 4)
--(db|files)-days    Amount of daily backups to save (default: 6)
--public-key         Path to public key to encrypt database dumps (default: ~/.ssh/backup.pub.pem)
--no-db              Skip database backups
-s, --silent         Suppress output (logs to /tmp/backup.log)
-q, --quiet          Suppress output (logs to /tmp/backup.log)
```

### Full example


```sh
wp-backup.sh \
  --quiet \
  --wp /home/www/foo/deploy/current/web/wp \
  --customer foo \
  --remote backup.foobar.com \
  --db-months 6 \
  --db-weeks 4 \
  --db-days 7 \
  --files-months 6 \
  --files-weeks 4 \
  --files-days 7 \
  --public-key /home/backup/.ssh/backup.pub.pem \
  --dir /home/www/foo/deploy/shared/web/app/uploads \
  --dir /home/www/foo/deploy/shared/web/app/files_mf
```

### Decrypting a database dump.

```
openssl smime -decrypt -in nooga-db-20170615_002116.sql.gz.enc -binary -inform DEM -inkey backup.priv.pem -out database.sql.gz
gunzip database.sql.gz
```