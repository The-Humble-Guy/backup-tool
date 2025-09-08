# A tool for automatic backup creation

A backup is an archive with a full or partial copy of the file system. All
backups are stored inside the backup repository. Each backup is described by a
script file in yaml format. This file contains the following:
- name of the backup,
- a list of file paths for the backup,
- type of archive being created,
- compression ratio of the archive,
- regularity of backups,
- the maximum number of backups stored.

Features:
- ease of creating backups and working with the tool,
- the consistency of creating backups,
- backup of symlinks along with the contents they specify,
- limitation of disk space by the number of backups stored,
- support for backup exceptions paths.

## Dependencies

Basic utilities are needed for the tool to work: `cp`, `mv`, `tar`, `gzip`,
`bzip2`, `zip`, `du`, `grep`, `cat`, `find`.

To read configs, you need the `yq` utility. Please install it
**additionally**.

After cloning the repository, you can create symlinks like this:

```bash
cd /home/user/path/to/repo
chmod +x backup-monitor.sh
chmod +x backup.sh

cd /usr/local/bin/
sudo ln -s /home/user/path/to/repo/backup.sh backup
sudo ln -s /home/user/path/to/repo/backup-monitor.sh backup-monitor
```

## How to use

Initializing the tool

```bash
backup init
```

Adding a backup scenario

```bash
backup add-scenario /path/to/scenario
```
For an example of the script design, see the file `config.yaml`

That's all!

If you want to delete the scenario:

```bash
backup delete-scenario /path/to/scenario
```

Or in interactive mode:

```bash
backup delete-scenario
```

List of backups:
```bash
backup ls
```
