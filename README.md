## Overview

These Vultr backup scripts are based on Vultra API v2 and written in Bash and can be used in different scenarios. Create regular server snapshots which you can use to restore your server; define a limit to the amount of snapshots to keep for each server instance and which server instances to backup. Each folder is self-explanatory. More details are available in comments section at the beginning of each script.

These improved versions of Vultr backup script incorporate certain enhancements, including better error handling, use of environment variables for sensitive information, JSON parsing with jq, input validation, and a dry-run option. By using this method, you keep your sensitive information separate from the script, making it easier to manage and more secure.

Remember to add .env to your .gitignore file if you're using version control to prevent accidentally committing sensitive information.

To run the script, just download it, make it executable (chmod +x scriptname) and run using a command similar to this:

```shell
./vultr-single-instance-snapshots-script.sh
```

Any script except the one with User prompt can be run unattended as part of your daily cronjob, e.g. on my Mac laptop I do this:

Execute this command:

```shell
crontab -e
```

Then add the following line to your cronjob file (replace ****** with your username). This will run daily at 1am:

```shell
0 1 * * * /Users/******/Cronjobs/vultr-single-instance-snapshots-script.sh > /dev/null 2>&1
```
