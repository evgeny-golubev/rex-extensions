---
name: sidecar-tasks-setup
description: Sets up the Tasks tab of the Rex sidecar pane, step by step, with Google Tasks or Apple Reminders. Use it when the user asks to set up, connect or fix the sidecar Tasks tab, Google Tasks or Apple Reminders for the sidecar, or when the tab or a task action says "not set up", "Sign-in needed", "access denied" or "Sign-in failed".
---

# Sidecar Tasks setup

Guide the user through setting up the Tasks tab of the Rex sidecar pane. Check
what is already done yourself, then give the user one step at a time. After
each step the user takes in the browser or in the tab, stop and wait for them
to say it is done. Keep each message short: what to open, what to type or
click, and what they should see.

Never print or ask for secrets:

- Never ask the user to paste a client ID, client secret, token or the
  contents of a JSON file into the chat.
- Never run `security` with `-w` or `-g`, and never `cat` or read the
  downloaded `client_secret_*.json` file or `tasks_state.json`.
- Send task output to `/dev/null` or count it; do not show the user's tasks
  unless they ask.

## 1. Check the state

Run these checks first, in one Bash call, and change nothing:

```sh
EXT=~/.config/rex/extensions/cc-sidecar
test -x "$EXT/providers/google-tasks" && echo "extension: present" || echo "extension: missing"
echo "task actions: $(rex actions 2>/dev/null | grep -c '^tasks_')"
order=$(plutil -extract tabs.order json -o - "$EXT/settings.json" 2>/dev/null)
hidden=$(plutil -extract tabs.hidden.Tasks raw -o - "$EXT/settings.json" 2>/dev/null)
case "$order" in *'"Tasks"'*) [ "$hidden" = true ] && echo "tab: hidden" || echo "tab: shown" ;; *) echo "tab: hidden" ;; esac
echo "provider: $(plutil -extract provider raw -o - "$EXT/tasks_state.json" 2>/dev/null || echo none)"
security find-generic-password -s google-tasks-client -a client >/dev/null 2>&1 && echo "google client: stored" || echo "google client: missing"
security find-generic-password -s google-tasks-client -a refresh_token >/dev/null 2>&1 && echo "google sign-in: stored" || echo "google sign-in: missing"
```

Then, for the provider in use, or for Google when the client is stored, run
the provider and keep only its exit code and its first error line:

```sh
EXT=~/.config/rex/extensions/cc-sidecar
"$EXT/providers/google-tasks" tasks >/dev/null 2>"$TMPDIR/sidecar-tasks-check.txt"; echo "exit code: $?"
head -1 "$TMPDIR/sidecar-tasks-check.txt"; rm -f "$TMPDIR/sidecar-tasks-check.txt"
```

For Apple Reminders, run `"$EXT/providers/apple-reminders" tasks` the same way.

Read the results:

| Result | Meaning | Go to |
| --- | --- | --- |
| extension missing, or task actions not 3 | cc-sidecar is not installed or not loaded | 2 |
| tab hidden | The Tasks tab is not shown yet | 3 |
| provider none | No task source chosen | 4 |
| exit code 0 | Set up and working | 7 |
| exit code 4, or google client missing | Google Tasks is not set up | 5 |
| exit code 3, google client stored | Google sign-in is missing or ended | 6 |
| exit code 3 with Apple Reminders | macOS access to Reminders not granted | 4 |
| exit code 1 | Read the error line; see "If something goes wrong" | 8 |

Tell the user in one or two lines what is already done and what is left.
When everything works, say that the Tasks tab is already set up, name the
source, and stop. Do not change anything.

## 2. Install cc-sidecar

Tell the user the steps in the Install section of
`~/.config/rex/extensions/README.md`: the repository linked at
`~/.config/rex/extensions`, `require("extensions.cc-sidecar")` in
`~/.config/rex/init.lua`, then `rex config reload`. Offer to run
`rex config reload` once the line is there. Check again with
`rex actions | grep -c '^tasks_'`, which prints 3.

## 3. Show the Tasks tab

The tab is hidden until shown. Ask the user, in a sidecar pane:

1. Press `,` to open the tab settings.
2. Select **Tasks** and press `Space`.
3. Press `Esc`.

The Tasks tab now shows in the tab bar. Wait for the user.

## 4. Choose the source

Ask which source the user wants:

- **Apple Reminders**: no setup. Best when the user already keeps tasks in
  Reminders, or wants to start in a minute. It has no steps (subtasks).
- **Google Tasks**: about 10 minutes of setup in Google Cloud, once. It keeps
  steps, and syncs with Google's apps.

Then ask the user to open the Tasks tab and press `g` for Google Tasks or `r`
for Apple Reminders. `W` changes the choice later.

For Apple Reminders: macOS asks once for access to Reminders; the user allows
it. If the tab shows "Access to Reminders needed", the user presses `L`, or
allows it in System Settings, Privacy and Security, Reminders. Then go to 7.

For Google Tasks, go to 5, or to 6 when the client is already stored.

## 5. Set up Google Tasks

One step per message. Wait for the user after each one. If the user already
has a project or a client from an earlier try, skip the steps they have done.

1. **Create a project.** Open https://console.cloud.google.com/projectcreate.
   Project name: anything, such as `Sidecar Tasks`. Click **Create**. When it
   is made, check that the project picker at the top of the page shows it.
2. **Enable the Google Tasks API.** Open
   https://console.cloud.google.com/apis/library/tasks.googleapis.com, check
   that the new project is selected at the top, and click **Enable**. The
   page then shows "API Enabled" or the API's details page.
3. **Set up the Google Auth Platform.** Open
   https://console.cloud.google.com/auth/overview and click **Get started**.
   - App name: `Sidecar Tasks`. It must not contain the word "Google".
   - User support email: the user's own address.
   - Audience: **External**.
   - Contact information: the user's own address.
   - Agree to the Google API Services User Data Policy, click **Continue**,
     then **Create**.
4. **Add a test user.** Open https://console.cloud.google.com/auth/audience.
   Leave the publishing status at **Testing**. Under **Test users**, click
   **Add users**, enter the Google address whose tasks the tab will show,
   and click **Save**.
5. **Create the client.** Open https://console.cloud.google.com/auth/clients
   and click **Create client**. Application type: **Desktop app**. Name:
   `Sidecar Tasks desktop`. Click **Create**. In the dialog that shows the
   new client, click **Download JSON**. The file goes to Downloads as
   `client_secret_<numbers>-<letters>.apps.googleusercontent.com.json`.
6. **Store the client.** When the user says it is downloaded, find the file:

   ```sh
   find ~/Downloads -maxdepth 1 -name 'client_secret_*.json' -exec ls -t {} +
   ```

   It lists the newest first.

   - No file: ask where the browser saved it, and use that path. Ask for the
     path only, never the contents.
   - Several files: say so, and use the newest unless the user names another.

   Import it, and delete the file only when the import succeeds:

   ```sh
   ~/.config/rex/extensions/cc-sidecar/providers/google-tasks import-client "<path>" && rm "<path>"
   ```

   It prints `client stored`. Tell the user the client is now in the macOS
   Keychain, under `google-tasks-client`, and the download is deleted.

Then go to 6.

## 6. Sign in to Google

Tell the user what will happen before running the command:

1. The browser opens Google's account chooser. Choose the account added as
   test user.
2. Google shows "Google hasn't verified this app". This is expected for an
   app of one's own: click **Advanced**, then **Continue** (it may read **Go
   to Sidecar Tasks (unsafe)**).
3. Google asks to let Sidecar Tasks see and change the user's tasks. Tick the
   box if one is shown, and click **Continue**.
4. The browser shows "Sign-in complete. This window can be closed."

Tell the user too: if the browser shows "Access blocked" or "Error 403:
access_denied", Google will not answer the command. They then press `Esc` in
Claude Code to stop the wait and say what they saw; the fix is in 8.

Then run the sign-in. It waits up to 5 minutes, so give the Bash call a
timeout of 330000 ms:

```sh
~/.config/rex/extensions/cc-sidecar/providers/google-tasks login
```

It prints `signed in` on success. On failure, see "If something goes wrong".
The user can also press `L` in the Tasks tab, which runs the same sign-in.

## 7. Verify

Count the lists and open tasks through the task actions, without showing them:

```sh
f="$TMPDIR/sidecar-tasks-list.json"
if rex do tasks_list > "$f" 2> "$f.err"; then
  i=0; while n=$(plutil -extract "$i.tasks" raw -o - "$f" 2>/dev/null); do echo "list $((i + 1)): $n open tasks"; i=$((i + 1)); done
else
  echo "tasks_list failed: $(head -1 "$f.err")"
fi
rm -f "$f" "$f.err"
```

Tell the user it works, with the counts, and that the tab shows the tasks at
its next fetch, or at once after pressing `r` in the Tasks tab. With Google
in Testing, mention once that Google ends the sign-in every 7 days; the tab
then shows "Sign-in needed" and `L` signs in again.

## 8. If something goes wrong

| What the user sees | Cause | Fix |
| --- | --- | --- |
| The app name is rejected in step 3 | The name contains "Google" | Choose a name without it, such as `G Task Client` |
| **Publish app** fails: "configuration is not complete in Branding" | Publishing needs the Branding page complete | Not needed: leave the app in **Testing**. Sign-in then lasts 7 days, and `L` renews it |
| "Error 403: access_denied" or "Access blocked" in the browser, or `login` ends with "access denied" or "no answer from the browser" | The account is not a test user | Add it under **Test users** at https://console.cloud.google.com/auth/audience, then run `login` again |
| The tab shows the wrong account's tasks, or the user chose the wrong account | Signed in with another Google account | Ask first, then sign out with `security delete-generic-password -s google-tasks-client -a refresh_token`. Make sure the right account is a test user, run `login` and choose that account |
| "Sign-in needed" after about a week | Google ends a Testing app's sign-in after 7 days | Press `L` in the tab, or run `login` |
| "Google Tasks is not set up yet" | No client is stored | Steps 5.5 and 5.6 |
| "This file is for a Web application client" | The client type is wrong | Create a new client of type **Desktop app** (step 5.5) |
| The client dialog was closed before **Download JSON** | The JSON file was not saved | Create a new Desktop app client and download it from the dialog |
| "HTTP 403" with "has not been used in project" or "is disabled" | The Tasks API is not enabled in the client's project | Step 5.2, with that project selected; wait a minute, then check again |
| "Access to Reminders needed" | macOS access not granted | Press `L` in the tab, or allow it in System Settings, Privacy and Security, Reminders |

If Google Tasks keeps failing, offer Apple Reminders: `W`, then `r` in the
Tasks tab, with no setup.

Delete the Keychain entries only when the user agrees, and only the one the
fix names. Never delete `tasks_state.json`.
