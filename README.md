# ms-teams.nvim

> **Disclaimer — vibe coded.** This plugin was built with heavy AI
> assistance ("vibe coding"). The author's contribution is mainly the
> specification and checking that it works. It is still early-stage and
> unstable: breaking changes happen without notice and parts of the UI are
> rough. Use at your own risk.

Microsoft Teams chats inside Neovim, read and answer Microsoft Teams chats
right inside your editor.


## Demo

[![Watch the demo](https://img.youtube.com/vi/p24sI_XM27E/0.jpg)](https://www.youtube.com/watch?v=p24sI_XM27E)

## Requirements

- Neovim 0.9 or newer.
- `curl` and `python3` in `PATH`.
- **DavMail** with a valid OAuth token. The plugin does not implement its
  own login: it reads the refresh token written by DavMail and exchanges it
  for Microsoft Graph access tokens. `davmail-token` is the recommended way
  to create that token. Plaintext tokens are tested; `{AES}` tokens are
  decrypted through DavMail's own code, but that path is untested.

> [!IMPORTANT]
> **No admin consent required.** The plugin reuses the Outlook (Microsoft
> Office) client ID, so you do not need tenant-wide admin approval to use
> it.

- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for
  `:MSTeamsFind` and `:MSTeamsNewChat`.
- Optional: `terminal-notifier` (macOS) or `notify-send` (Linux) for watch
  notifications.
- Optional: image.nvim and ImageMagick for inline profile avatars.

For the complete DavMail setup (token file, scopes, `davmail-token` alias
and `{AES}` password), run inside Neovim:

    :help ms-teams-authentication

## Features

- Chat list and chat detail with unread state, replies, compose buffer and
  attachments (files, tabs, images) opened with `gx`.
- Reactions: compact counts, inline reactor name for single-reaction
  groups, `gr` detail with per-user lists and keycap emoji normalization.
- In-chat search (`F`) with quickfix output.
- User detail (`ms-teams://user-detail/<id>`): Graph profile fields and
  cached profile photo, rendered inline with image.nvim when available.
- Meetings support:
  - Day/week schedule (`:MSTeamsSchedule`, `:MSTeamsScheduleWeek`) with
    date navigation, accepted-meeting highlight and a new-meeting form that
    creates Teams meetings and invites attendees.
  - Meeting detail with join URL, attendees and responses, accept / decline /
    tentative replies, refresh and delete for meetings you organize.
- Live refresh of visible 1:1 chats every 10s, with a per-chat lock so
  only one Neovim instance polls each chat.
- Watch polling with `terminal-notifier` / `notify-send` notifications.
- Notifications view (`:MSTeamsNotifications`): unread chats, mentions,
  pending meeting invites and recent watch activity.
- Per-buffer configurable keymaps (`g?` opens a floating keymap list) and
  throttle-safe caches.

## Documentation

Full documentation (authentication and DavMail setup, installation, setup
options, architecture, commands, keymaps, user detail, schedule, live
refresh, search and storage) lives in Neovim's help format at
`doc/ms-teams.txt`:

    :help ms-teams

If your plugin manager did not generate help tags automatically, run
`:helptags ALL` once.
