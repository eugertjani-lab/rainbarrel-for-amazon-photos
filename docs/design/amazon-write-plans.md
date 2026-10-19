# Changing Amazon Photos through reviewed plans

Status: proposal, 2026-10-19. Branch: `spike/amazon-writes`.

## Goal

Rainbarrel has only ever read from Amazon. This design lets it change the Amazon Photos library as well, so that the library can be reorganized, cleaned up and corrected in one place. Every change is first collected in a plan that the app shows on a review screen. Nothing reaches Amazon until the user presses Apply, and an applied plan can be undone step by step.

The work covers three uses that share one engine. The first mirrors a reorganization made on the backup drive: when folders are moved or renamed on the drive, Amazon gets the same structure. The second cleans up Amazon, for example the 192 files that were uploaded empty, phone junk such as `.nomedia` and Viber `.temp` files, duplicate copies and duplicate folders such as `Pictures (2022-11-18T01_54_43.535)`. The third changes names and descriptions to match the user's own conventions.

## What Amazon's API allows

These calls were tried live on 2026-10-19 in a test folder of the user's account, with the same signed-in session Rainbarrel already uses for downloads.

| Change | Call | Result |
|---|---|---|
| Create a folder | `POST /drive/v1/nodes` with `{name, kind: "FOLDER", parents}` | 201 with an empty body; the new id comes from listing the parent, and a new folder can take a few seconds to appear |
| Move a file or folder | `POST /drive/v1/nodes/{newParent}/children` with `{fromParent, childId}` | 200 with the moved node |
| Rename | `PATCH /drive/v1/nodes/{id}` with `{name}` | 200 |
| Description | `PATCH /drive/v1/nodes/{id}` with `{description}` | 200 |
| Capture date | `PATCH` with `contentDate` or `contentProperties.contentDate` | ignored, or refused with 403 |
| Trash | `PUT /drive/v1/trash/{id}` | 200, status TRASH |
| Restore | `POST /drive/v1/trash/{id}/restore` | 200, status AVAILABLE |

Two findings shape the design. Trashing a folder does not change the status of the files inside it: they stay AVAILABLE with a trashed parent. So every cleanup trashes files one by one and only then the emptied folder. And capture dates cannot be changed through this API. The Amazon Photos website has a date editor, so another endpoint may exist, but until it is found, date fixes are out of scope and the metadata planner says so instead of pretending.

Rainbarrel never empties Amazon's trash. Trashing is the strongest action it takes, which keeps every plan reversible for as long as Amazon keeps its trash.

## Plans

A plan is an ordered list of steps that one planner produced from the current catalog and drive index. Each step has an operation (create folder, move, rename, describe, trash, restore), the node it acts on, the values it changes from and to, and a reason in plain words, for example "empty file (0 bytes)" or "moved on the drive to Pictures/2019/Holiday".

Each step also records what the node looked like when the plan was made: its parent, name, status and MD5. Right before the step runs, Rainbarrel reads the node from Amazon again. If it no longer matches, because something changed in the library since the plan was made, the step is skipped and reported as changed meanwhile. A plan therefore never acts on stale information, and planning and applying can be hours apart.

Plans live in `state.sqlite` in two new tables, `amazon_plans` (planner, creation time, catalog checkpoint, status) and `amazon_plan_steps` (the steps, their state and their result). A plan moves through draft, applying, applied, partly applied and undone.

## Planners

### Mirror a reorganization from the drive

The drive already mirrors Amazon's folders. When the user moves or renames folders and files on the drive, the planner compares each cloud item's path with the path of its drive copy. Files are matched by MD5, and only matches that are unique on both sides count. A file whose content exists several times is reported instead of guessed. Missing folders are created first, then files are moved, then renamed, and folders that end up empty in Amazon are offered for trashing in a separate, unticked group.

Files under `_Unsorted` and anything that only exists on one side are left alone, because they have no counterpart to move.

### Clean up

The cleanup planner offers rules that the user turns on in the review screen. Empty files are trashed. Known phone junk (`.nomedia`, `.thumbnails`, Viber `.temp`, WhatsApp `.decrypt` and Premiere preview files) is trashed. Duplicate content keeps one copy, preferring the copy in the folder the user marks as preferred and otherwise the oldest upload, and trashes the rest. Merging folder A into folder B moves A's files into B, renames on a name clash the way downloads do (`IMG_0001 (2).jpg`), and finally trashes the emptied A.

### Metadata

The metadata planner renames files by a pattern the user picks, for example `YYYY-MM-DD_HH-MM-SS` from the capture date, and sets descriptions. Capture dates are listed as not editable until an endpoint is verified.

## Apply and undo

Apply runs the steps one at a time against Amazon, with the existing request budget and backoff. After each write it reads the node back and only then marks the step done, so a step that Amazon accepted but did not carry out shows as failed. Apply stops at the first unexpected answer and can be resumed. It takes the same lock as downloads and organize, and it refreshes the catalog before it starts, so that the drift check sees the current library.

Each done step stores its inverse: a move back, the old name, the old description, a restore. Undo runs the inverses of a plan in reverse order and checks drift the same way, so it never overwrites a change made after the plan.

When a plan is applied to Amazon, the drive follows through the existing `organize` command, which moves the drive copies into the new layout without downloading anything. When the plan came from the drive, the drive already matches.

## The review screen

The app gets a Plans view. The user picks a planner (and for cleanup, the rules), and Rainbarrel shows the plan grouped by operation and by folder, with counts and bytes at the top: "Move 1,204 files into 37 new folders, rename 210, trash 192 (0 bytes)". Every group and every step can be unticked. A search field filters by path. Each step shows its before and after and its reason. Apply asks once more with the totals and then shows progress per step. A history lists earlier plans with their results and an Undo button.

The command line gets `rainbarrel plan reorganize | cleanup | metadata` (writes a draft and prints its summary), `rainbarrel plan show <id>`, `rainbarrel apply <id>` and `rainbarrel undo <id>`. The MCP server can create and show plans but not apply them, so an assistant can propose changes and the user still decides in the app.

## Safety

A plan never purges anything. Every step checks for drift. A first run is capped at 50 steps, so the user can check the result on the Amazon Photos website before larger plans, and the cap can be lifted in the settings. Cookie values never appear in plans, logs or the review screen, as everywhere else in Rainbarrel.

## Build order

Each stage below is one pull request with its own tests against the fake server.

1. Core write client: typed calls for create folder (with the listing lookup), move, rename, describe, trash and restore, each followed by a read-back.
2. Plans in the database, the drift check, apply, resume and undo, with a cleanup planner limited to empty files as the first real use. This one plan trashes the 192 empty files.
3. The review screen and history in the app.
4. The reorganize planner, and the hand-off to `organize` for the drive.
5. The other cleanup rules: junk, duplicate content and folder merge.
6. The metadata planner for names and descriptions.

## Open questions

Whether the Amazon Photos website changes capture dates through another endpoint, which would bring date fixes back into scope. How Amazon treats a move into a folder that already holds a file of the same name; the plan avoids it by renaming, but the API's own answer should be known. Whether family vault items, if the account uses one, accept the same writes.
