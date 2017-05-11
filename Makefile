install: all

update: clean install

all: /usr/local/bin/wp-backup.sh

/usr/local/bin/wp-backup.sh:
	cp wp-backup.sh $@

clean:
	rm /usr/local/bin/wp-backup.sh
