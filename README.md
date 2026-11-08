# Minimalistic Bitwarden Backup Tool

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)

This is a lightweight automated shell script tool that backups your Bitwarden vault in an instant on macOS. It utilizes the official [bitwarden-cli](https://bitwarden.com/help/cli/) to authenticate and automatically store backups, exporting a **portable (password-protected)** JSON file that you can import back to Bitwarden or other supported password managers (e.g. [KeePassXC](https://keepassxc.org/)). You can even set up a scheduled reminder that pops up when it's time for backup so you'll never forget.

Although Bitwarden [stores local cache for 30 days](https://bitwarden.com/blog/configuring-bitwarden-clients-for-offline-access/#staying-logged-in-to-browser-extension-desktop-and-mobile-clients) when you go offline, it always gives a peace of mind if you know you have a secure local backup copy in your hard drive or USB thumb drive. It's also hard to keep track of all your backups, or you might completely forget to backup your passwords sometimes. This might be the solution.

> [!important]
> Please manually log out of Bitwaden with `bw logout` after updating Bitwarden CLI to prevent potential token issue.

## Features

- **GUI Prompts:** Uses macOS native dialogs to request the master password and send notifications. No typing passwords into the terminal.
- **One-Click Backup**: Type the command or click **Back Up Now** on the reminder, then enter your master password. Sit back and let the tool handle the rest.
- **Portable Backups:** Creates password-protected JSON exports that can be imported into _any_ Bitwarden account (unlike account-restricted backups). The backup files are protected with the same master password for your Bitwarden vault.
- **Automated Cleanup:** Automatically keeps only the last `N` backups (configurable) to save disk space and prevent potential security threats.
- **Reminders:** Shows a native macOS dialog when it's time for backup (frequency configurable). Click **Back Up Now** to start right away, or **Later** to dismiss it. No extra dependencies needed.

## How to Use

To initiate a backup process, simply type this command in your terminal:

```bash
bw-backup
```

or, if you don't want to use the alias, `cd` to the project folder and type:

```bash
./bw-backup.sh
```

And that's it!

A dialog window will appear requesting your Bitwarden master password. Once you enter the correct password, it handles everything and stores the encrypted JSON file in the directory of your choice. You will receive a notification after ~10 seconds confirming the backup.

If you set up a reminder with `LaunchAgent` (detailed below), a dialog will pop up regularly asking whether to back up now. Clicking **Back Up Now** brings out the same dialog requesting your master password. Enter the password and you are good to go. If you don't respond, the reminder closes itself after an hour.

> [!note]
> Earlier versions used [terminal-notifier](https://github.com/julienXX/terminal-notifier) for clickable notifications. It relies on a deprecated macOS API and, on recent macOS versions, reports success without ever showing anything, so it is no longer used.

A little GIF showing you how easy it is:

<img src="./assets/backup-demo.gif" alt="a gif showing the entire process of using this tool"/>

## Setup

### Prerequisites

You need to have `bitwarden-cli` installed on your macOS system. You can install it easily via [Homebrew](https://brew.sh/):

```bash
brew install bitwarden-cli
```

### Configuring `.env` file

First, clone this repository and go to the project directory:

```bash
git clone https://github.com/kckhchen/bw-backup.git
cd bw-backup
```

Copy the `.env.example` file in the repository and rename it `.env` before configuring.

```bash
cp .env.example .env
```

| Name            | Description                                                                                 | Default                            |
| --------------- | ------------------------------------------------------------------------------------------- | ---------------------------------- |
| `BACKUP_DIR`    | Directory to store your backup files                                                        | `$HOME/Backups/Bitwarden`          |
| `LOG_FILE`      | Path to the log file                                                                        | `$HOME/Library/Logs/bw-backup.log` |
| `MAX_ATTEMPTS`  | Maximum attempts of password before the process aborts                                      | 5                                  |
| `KEEP_LAST_N`   | Number of backups to keep                                                                   | 3                                  |
| `SAFETY_PHRASE` | A phrase to let you know it is this tool prompting you for the password                     | none                               |
| `BW_SERVER`     | Your custom Bitwarden server. If you use the official Bitwarden, plese leave it as a blank. | none                               |

### Installation

Fist you need your Bitwarden API key at hand. Log in to Bitwarden on your web browser and follow the steps from the [official documentation](https://bitwarden.com/help/personal-api-key/#get-your-personal-api-key) to get your API key. Have them ready as you will need them during setup.

This repository comes with a `setup.sh` shell script. Use the following commands to quickly set things up.

```bash
# make executable
chmod +x ./setup.sh

# run the script
./setup.sh
```

`setup.sh` will check dependencies, create the backup directory, validate configurations, and make sure your `.env` file is secure. Specifically, it runs `chmod 600` for your `.env` to make sure only you, the owner, can access the sensitive information inside.

It will also prompt you for your Bitwarden API `clientid` and `clientsecret`. You will be prompted to enter each of them twice for confirmation. The tool will not store your API keys. Rather, it stores them securely inside your Apple Keychain and only uses them to authenticate you when necessary.

The setup script also enables the command `bw-backup` for you to backup your file manually in the terminal and setup `LaunchAgent` for you. (you can opt out of it, of course)

When the setup is done, you can run your `bw-backup` script and have your passwords backed up securely offline on your machine.

## How to Restore

If you ever need to use your backup:

1. Log in to your [Bitwarden Web Vault](https://vault.bitwarden.com/).
2. Go to **Tools** → **Import Data**.
3. Select format: **Bitwarden (json)**.
4. Choose the `Bitwarden-Backup-YYYY-MM-DD-HH-MM-SS.json` file generated by this tool.
5. **Important:** Because the file is encrypted, Bitwarden will ask for the password you used when the backup was created (which is your master password).

Or you might want a cold storage in KeePassXC:

1. Open the KeePassXC application.
2. Select **Import File**, choose **Bitwarden (.json)**.
3. Use **Browse** to locate your backup `Bitwarden-Backup-YYYY-MM-DD-HH-MM-SS.json` and enter your master password in the **Password** field.
4. Encrypt the database with your password.

## Security Disclosure

This tool creates **password-protected** backups using the official `bw export` command.

To create a backup that is portable (password-protected), we must pass the password to the CLI using the `--password` flag. This means that when this particular line of code is running, it may be visible to malware or other users who are actively monitoring process lists. **Do not run this script on a shared computer or multi-user server** where other users might be monitoring processes.

Unfortunately currently there's no way around this limitation as the `bw export` does not support reading passwords from an environment variable, but on a personal computer this tool is generally safe to run.

## Technical Notes

### Log File

When the script runs, it creates a log file at `~/Library/Logs/bw-backup.log`. You can check the log here should anything go wrong. You may also change the log file path in the `.env` file.

### When Sync Fails

Before exporting, the tool runs `bw sync -f` to pull the latest vault from the server. If the sync fails, it will **not** silently fall back to the local cache. Instead, a dialog tells you:

- when the vault was last synced successfully and how old the cached data is,
- the error returned by the Bitwarden CLI,
- a concrete fix for the most common causes (expired CLI login, no network, server errors, rate limiting).

You can then choose **Back Up Cached Data** to write a backup from the stale cache anyway, or **Cancel** to fix the problem first. If you go ahead with cached data, the completion notification says so and a second notification points to the log. The full CLI error is always written to the log file.

The most common cause is an expired CLI login token. The fix is:

```bash
bw logout
```

then run `bw-backup` again. It will log in again using the API key stored in your Keychain.

### Possibility of Full Automation

Technically this can be achieved. However, not having to manually type in the master password to initiate the backup process generally means that the user has to store the master password in plain text as an environment variable, which is dangerous practice. For this reason, manually typing the master password via the secure OS prompt is the intended design.

---

Please feel free to let me know if there are any issues or suggestions. I will be more than happy to accomodate.
