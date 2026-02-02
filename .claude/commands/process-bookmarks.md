# /process-bookmarks

Process prepared Twitter bookmarks into a markdown archive with rich analysis and optional filing to a knowledge library.

## Before You Start

### CRITICAL: One File Per Bookmark (NO combined bookmarks.md)

Smaug archives each bookmark to its own markdown file under `archiveDir` (from config).

- **Default behavior:** Use the `Write` tool to create a new file for each bookmark.
- **If the file already exists** (e.g. force re-process): do **NOT** overwrite it blindly. Use `Edit` to update the generated sections and preserve any user notes.

The legacy single-file `bookmarks.md` workflow is no longer the default.

### Multi-Step Parallel Protocol (CRITICAL)

**Create todo list IMMEDIATELY after reading bookmark count.** This ensures final steps never get skipped.

**Check parallelThreshold from config** (default: 8). Use parallel processing only when bookmark count >= threshold. For smaller batches, sequential processing is faster due to subagent overhead.

```bash
node -e "console.log(require('./smaug.config.json').parallelThreshold ?? 8)"
```

**For bookmarks below threshold (sequential):**
```javascript
TodoWrite({ todos: [
  {content: "Read pending bookmarks", status: "pending", activeForm: "Reading pending bookmarks"},
  {content: "Process bookmark 1", status: "pending", activeForm: "Processing bookmark 1"},
  {content: "Process bookmark 2", status: "pending", activeForm: "Processing bookmark 2"},
  {content: "Clean up pending file", status: "pending", activeForm: "Cleaning up pending file"},
  {content: "Commit and push changes", status: "pending", activeForm: "Committing changes"},
  {content: "Return summary", status: "pending", activeForm: "Returning summary"}
]})
```

**For bookmarks at or above threshold (MUST use parallel subagents):**
```javascript
TodoWrite({ todos: [
  {content: "Read pending bookmarks", status: "pending", activeForm: "Reading pending bookmarks"},
  {content: "Spawn subagents to write bookmark files", status: "pending", activeForm: "Spawning subagents"},
  {content: "Wait for all subagents to complete", status: "pending", activeForm: "Waiting for subagents"},
  {content: "Clean up pending file", status: "pending", activeForm: "Cleaning up pending file"},
  {content: "Commit and push changes", status: "pending", activeForm: "Committing changes"},
  {content: "Return summary", status: "pending", activeForm: "Returning summary"}
]})
```

**Execution rules:**
- Mark each step `in_progress` before starting
- Mark `completed` immediately after finishing (no batching)
- Only ONE task `in_progress` at a time
- Never skip final steps (commit, summary)

**CRITICAL for parallel processing:** Spawn ALL subagents in ONE message. Each subagent writes bookmark markdown files directly under `archiveDir`:
```javascript
// Send ONE message with multiple Task calls - they run in parallel
// Use model="haiku" for cost-efficient parallel processing (~50% cost savings)
Task(subagent_type="general-purpose", model="haiku", prompt="Process batch 0 (oldest first): write bookmark files for bookmarks 0-4")
Task(subagent_type="general-purpose", model="haiku", prompt="Process batch 1 (oldest first): write bookmark files for bookmarks 5-9")
Task(subagent_type="general-purpose", model="haiku", prompt="Process batch 2 (oldest first): write bookmark files for bookmarks 10-14")
// ... all batches in the SAME message
```

**DO NOT:**
- Write to a combined `bookmarks.md` file
- Overwrite an existing per-bookmark file with `Write` (use `Edit` instead)
- Process bookmarks above threshold sequentially (too slow)
- Send Task calls in separate messages (defeats parallelism)
- Skip cleanup of `pending-bookmarks.json`

### Setup

**Get today's date (friendly format):**
```bash
date +"%A, %B %-d, %Y"
```

Bookmark files use `dateISO` for folder names (e.g., `2026-01-02`).

**Load paths and categories from config:**
```bash
node -e "const c=require('./smaug.config.json'); console.log(JSON.stringify({archiveMode:c.archiveMode, archiveDir:c.archiveDir, archiveFile:c.archiveFile, pendingFile:c.pendingFile, stateFile:c.stateFile, categories:c.categories}, null, 2))"
```

This gives you:
- `archiveMode`: `files` (one file per bookmark) or `single` (legacy)
- `archiveDir`: Where to write per-bookmark files (e.g., `./bookmarks`)
- `archiveFile`: Legacy single-file path (only if `archiveMode: single`)
- `pendingFile`: Where pending bookmarks are stored
- `stateFile`: Where processing state is tracked
- `categories`: Custom category definitions

**IMPORTANT:** Use these paths throughout. The `~` will be the user's home directory.
If no custom categories, use the defaults from `src/config.js`.

## Input

Prepared bookmarks are in the `pendingFile` path from config (typically `./.state/pending-bookmarks.json` or a custom path).

Each bookmark includes:
- `id`, `author`, `authorName`, `text`, `tweetUrl`, `createdAt`, `date`, `dateISO`
- `tags[]` - folder tags from bookmark folders (e.g., `["ai-tools"]`)
- `links[]` - each with `original`, `expanded`, `type`, and `content`
  - `type`: "github", "article", "video", "tweet", "media", "image"
  - `content`: extracted text, headline, author (for articles/github)
- `isReply`, `replyContext` - parent tweet info if this is a reply
- `isQuote`, `quoteContext` - quoted tweet info if this is a quote tweet

## Categories System

Categories define how different bookmark types are handled. Each category has:
- `match`: URL patterns or keywords to identify this type
- `action`: What to do with matching bookmarks
  - `file`: Create a knowledge file in the category folder (and ALWAYS create the per-bookmark file)
  - `capture`: Create the per-bookmark file only
  - `transcribe`: Create the per-bookmark file with a transcript-needed flag (and optionally a placeholder in the category folder)
- `folder`: Where to save files (for `file` action)
- `template`: Which template to use (`tool`, `article`, `podcast`, `video`)

**Default categories:**
| Category | Match Patterns | Action | Folder |
|----------|---------------|--------|--------|
| github | github.com | file | ./knowledge/tools |
| article | medium.com, substack.com, dev.to, blog | file | ./knowledge/articles |
| podcast | podcasts.apple.com, spotify.com/episode, overcast.fm | transcribe | ./knowledge/podcasts |
| youtube | youtube.com, youtu.be | transcribe | ./knowledge/videos |
| video | vimeo.com, loom.com | transcribe | ./knowledge/videos |
| tweet | (fallback) | capture | - |

## Workflow

### 1. Read the Prepared Data

Read from the `pendingFile` path specified in config. If the path starts with `~`, expand it to the home directory:
```bash
# Get pendingFile from config and expand ~ (cross-platform)
PENDING_FILE=$(node -e "const p=require('./smaug.config.json').pendingFile; console.log(p.replace(/^~/, process.env.HOME || process.env.USERPROFILE))")
cat "$PENDING_FILE"
```

### 2. Process Bookmarks (Parallel when above threshold)

**IMPORTANT: If bookmark count >= parallelThreshold (default 8), you MUST use parallel processing:**

```
Use the Task tool to spawn multiple subagents simultaneously.
Each subagent processes a batch of ~5 bookmarks.
Example: 20 bookmarks → spawn 4 subagents (5 each) in ONE message with multiple Task calls.
```

This is critical for performance. Do NOT process bookmarks sequentially when above threshold.

For each bookmark (or batch):

#### a. Determine the best title/summary

Don't use generic titles like "Article" or "Tweet". Based on the content:
- GitHub repos: Use the repo name and brief description
- Articles: Use the article headline or key insight
- Videos: Note for transcript, use tweet context
- Quote tweets: Capture the key insight being highlighted
- Reply threads: Include parent context in the summary
- Plain tweets: Use the key point being made

#### b. Categorize using the categories config

Match each bookmark's links against category patterns (check `match` arrays). Use the first matching category, or fall back to `tweet`.

**For each action type:**
- `file`: Create a knowledge file in the category's folder using its template
- `capture`: No knowledge file
- `transcribe`: No knowledge file by default; include a transcript-needed flag (you may also create a placeholder file in the category folder)

**Special handling:**
- Quote tweets: Include quoted tweet context in entry
- Reply threads: Include parent context in entry

#### c. Add bookmark entry to archive (USE EDIT TOOL)

Create a per-bookmark markdown file under `archiveDir` using `Write`:

- Path: `${archiveDir}/${bookmark.dateISO}/${bookmark.id}.md`
- Ensure the date folder exists first (use `Bash`: `mkdir -p "${archiveDir}/${bookmark.dateISO}"`).
- If the file already exists, use `Edit` and preserve anything under `## Notes`.

**Standard bookmark file format:**
```markdown
---
tweet_id: "{id}"
author: "{author}"
author_name: "{authorName}"
date: "{dateISO}"
tweet_url: "{tweetUrl}"
tags: [{tag1}, {tag2}]
category: "{category_key}"
status: "needs_transcript" (only for transcribe)
filed:
  - "./knowledge/tools/{slug}.md" (only if filed)
---

# {descriptive_title}

> {tweet_text}

{Optional: quoted/reply context block}

## Links
- Tweet: {tweetUrl}
- Link: {expanded_url} (if present)

## What
{1-2 sentence description of what this actually is}

## Notes

```

**Quoted tweets:** add a short block between the main quote and Links section.

**Replies:** include a short "Replying to" context block.

### 3. Clean Up Pending File

After successfully processing, remove the processed bookmarks from the pending file (use `pendingFile` path from config, expanding `~`):

```javascript
const pendingPath = config.pendingFile.replace(/^~/, process.env.HOME);
const pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
const processedIds = new Set([/* IDs you processed */]);
const remaining = pending.bookmarks.filter(b => !processedIds.has(b.id));
pending.bookmarks = remaining;
pending.count = remaining.length;
fs.writeFileSync(pendingPath, JSON.stringify(pending, null, 2));
```

### 4. Commit and Push Changes

After all bookmarks are processed and filed, commit the changes:

```bash
# Get today's date for commit message
DATE=$(date +"%b %-d")

# Get archiveDir from config and expand ~
ARCHIVE_DIR=$(node -e "const c=require('./smaug.config.json'); const p=c.archiveDir||'./bookmarks'; console.log(p.replace(/^~/, process.env.HOME || process.env.USERPROFILE))")

# Stage all bookmark-related changes
git add "$ARCHIVE_DIR"  # The archiveDir path from config
git add knowledge/

# Commit with descriptive message
git commit -m "Process N Twitter bookmarks from $DATE

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"

# Push immediately
git push
```

Replace "N" with actual count. If any knowledge files were created, mention them in the commit message body.

### 5. Return Summary

```
Processed N bookmarks:
- @author1: Tool Name → filed to knowledge/tools/tool-name.md
- @author2: Article Title → filed to knowledge/articles/article-slug.md
- @author3: Plain tweet → bookmark file only

Committed and pushed.
```

## Frontmatter Templates

### Tool Entry (`./knowledge/tools/{slug}.md`)

```yaml
---
title: "{tool_name}"
type: tool
date_added: {YYYY-MM-DD}
source: "{github_url}"
tags: [{relevant_tags}, {folder_tags}]
via: "Twitter bookmark from @{author}"
---

{Description of what the tool does, key features, why it was bookmarked}

## Key Features

- Feature 1
- Feature 2

## Links

- [GitHub]({github_url})
- [Original Tweet]({tweet_url})
```

### Article Entry (`./knowledge/articles/{slug}.md`)

```yaml
---
title: "{article_title}"
type: article
date_added: {YYYY-MM-DD}
source: "{article_url}"
author: "{article_author}"
tags: [{relevant_tags}, {folder_tags}]
via: "Twitter bookmark from @{author}"
---

{Summary of the article's key points and why it was bookmarked}

## Key Takeaways

- Point 1
- Point 2

## Links

- [Article]({article_url})
- [Original Tweet]({tweet_url})
```

### Podcast Entry (`./knowledge/podcasts/{slug}.md`)

```yaml
---
title: "{episode_title}"
type: podcast
date_added: {YYYY-MM-DD}
source: "{podcast_url}"
show: "{show_name}"
tags: [{relevant_tags}, {folder_tags}]
via: "Twitter bookmark from @{author}"
status: needs_transcript
---

{Brief description from tweet context}

## Episode Info

- **Show:** {show_name}
- **Episode:** {episode_title}
- **Why bookmarked:** {context from tweet}

## Transcript

*Pending transcription*

## Links

- [Episode]({podcast_url})
- [Original Tweet]({tweet_url})
```

### Video Entry (`./knowledge/videos/{slug}.md`)

```yaml
---
title: "{video_title}"
type: video
date_added: {YYYY-MM-DD}
source: "{video_url}"
channel: "{channel_name}"
tags: [{relevant_tags}, {folder_tags}]
via: "Twitter bookmark from @{author}"
status: needs_transcript
---

{Brief description from tweet context}

## Video Info

- **Channel:** {channel_name}
- **Title:** {video_title}
- **Why bookmarked:** {context from tweet}

## Transcript

*Pending transcription*

## Links

- [Video]({video_url})
- [Original Tweet]({tweet_url})
```

## Parallel Processing (REQUIRED when above threshold)

Because the archive is **one file per bookmark**, subagents can safely write bookmark files directly (no merge step).

**Rules:**
- Each subagent processes its assigned bookmarks in order (oldest first)
- For each bookmark, create the date folder (via `Bash`: `mkdir -p "${archiveDir}/${dateISO}"`), then `Write` the bookmark file
- If a bookmark file already exists, use `Edit` and preserve anything under `## Notes`
- Knowledge files (`knowledge/tools/*`, `knowledge/articles/*`, etc.) can also be created directly

**Subagent prompt template:**
```
You are processing these bookmarks (oldest first):
{JSON array of 5-10 bookmarks}

Config:
- archiveDir: {from smaug.config.json}

For each bookmark:
1) mkdir -p "{archiveDir}/{dateISO}"
2) Write "{archiveDir}/{dateISO}/{id}.md" using the standard bookmark file format
3) If category action is "file", also create the knowledge file in the category folder
4) If category action is "transcribe", set status: needs_transcript in the bookmark file
```

## Example Output

```
Processed 4 bookmarks:

1. @tom_doerr: Whisper-Flow (Real-time Transcription)
   → Tool: github.com/dimastatz/whisper-flow
   → Filed: knowledge/tools/whisper-flow.md

2. @simonw: Gist Host Fork for Rendering GitHub Gists
   → Article about GitHub Gist rendering
   → Filed: knowledge/articles/gisthost-gist-rendering.md

3. @michael_chomsky: ResponsiveDialog Component Pattern
    → Quote tweet endorsing @jordienr's UI pattern
    → Bookmark file only (with quoted context)

4. @CasJam: Claude Code Video Post-Production
    → Plain tweet (video content)
    → Bookmark file only, flagged for transcript
```
