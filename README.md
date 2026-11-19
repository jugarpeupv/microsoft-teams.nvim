# ms-teams.nvim

Microsoft Teams chats inside Neovim, read and answer Microsoft Teams chats
right inside your editor.

## Demo

[![Watch the demo](https://img.youtube.com/vi/p24sI_XM27E/0.jpg)](https://www.youtube.com/watch?v=p24sI_XM27E)

## Features

- Chat list and chat detail with unread state, replies, compose buffer and
  attachments (files, tabs, images) opened with `gx`.
- Reactions: compact counts, inline reactor name for single-reaction
  groups, `gr` detail with per-user lists and keycap emoji normalization.
- In-chat search (`g/`) and Telescope search (`gF`), with quickfix output.
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
- Per-buffer configurable keymaps and throttle-safe caches.

## Documentation

Full documentation (authentication and DavMail setup, installation, setup
options, architecture, commands, keymaps, user detail, schedule, live
refresh, search and storage) lives in Neovim's help format at
`doc/ms-teams.txt`:

    :help ms-teams

If your plugin manager did not generate help tags automatically, run
`:helptags ALL` once.
