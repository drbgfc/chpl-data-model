# Procedure for migration of databases between machines

**Read this entire document before beginning anything.**

This document outlines the steps that will need to be followed to migrate a database from "initial-machine" to "target-machine". That said, certain lines will need to be modified based on the user that's taking the activity. These lines are not all meant to be copy/pasted

# Set initial/target machines

```sh
export initial_machine="IP address or SSH alias or something equal to system where data starts"
export target_machine="IP address or SSH alias or something equal to system where data is going"
```

# Log into the "initial-machine" and generate the backup file

```sh
ssh $initial_machine
cd chpl-data-model/maint
./dump.sh $DB openchpl_dev
exit
```

# Copy the backup file from the initial machine to the target machine

```sh
scp $initial_machine:chpl-data-model/maint/openchpl.backup openchpl.backup
scp openchpl.backup $target_machine:chpl-data-model/maint/openchpl.backup
```

Or...

```sh
scp -3 $initial_machine:chpl-data-model/maint/openchpl.backup $target_machine:chpl-data-model/maint/openchpl.backup
```

Or...

```sh
rsync -zP $initial_machine:chpl-data-model/maint/openchpl.backup .
rsync -zP openchpl.backup $target_machine:chpl-data-model/maint
```

# Log into the target machine and load the data files

```sh
ssh $target_machine
cd chpl-data-model/maint
./load.sh $DB openchpl_dev
```

Load the users

```sh
psql -U openchpl_dev -h $DB -f users.sql openchpl
```

# Update the target machine with whatever is "new" as per git

```sh
cd ..
psql -U openchpl_dev -h $DB -f v-next.sql openchpl;
psql -U openchpl -h $DB -c analyze;
```

# Notes:

## If loading on live, consider stop/starting tomcat

```sh
service tomcat8 stop
service tomcat8 start
```

## Edit users.sql file to add any users w/encrypted passwords and the things they should be managers of.

## First time setup instructions include:

Setup pgpass.conf (C:\Users\username\AppData\Roaming\postgresql\pgpass.conf)

```sh
localhost:5432:*:openchpl_dev:password
localhost:5432:*:openchpl:password
```

### Create openchpl_dev role (if it doesn't already exist

```sql
CREATE ROLE openchpl_dev LOGIN
  ENCRYPTED PASSWORD 'md5cf8270a3cc591bdefa97b25a3981ef9e'
  NOSUPERUSER INHERIT NOCREATEDB NOCREATEROLE NOREPLICATION;
```

### Backup your local database in case of disaster

```sh
cd chpl_data_model/maint
./dump.sh localhost openchpl
```

### And make sure the openchpl database is owned by openchpl_dev:

#### Drop the openchpl database if it's not owned by openchpl_dev

```sql
DROP DATABASE openchpl;
```

#### Then create it

```sql
CREATE DATABASE openchpl
  WITH OWNER = openchpl_dev
    ENCODING = 'UTF8'
    TABLESPACE = pg_default
    LC_COLLATE = 'English_United States.1252'
    LC_CTYPE = 'English_United States.1252'
    CONNECTION LIMIT = -1;
```