---
name: inline-review
description: >
  Leave review annotations on markdown (.md) and text (.txt) drafts, or process
  existing annotations (accept/disagree), using CriticMarkup syntax compatible
  with inline-review.nvim. Only operates on .md and .txt files — do NOT trigger
  for code files (.py, .lua, .js, .ts, .rs, etc.) or any other file type.
  Use when asked to "review this draft", "leave comments on this file",
  "annotate this", "suggest changes", "process these annotations", "accept the
  changes", "respond to the review", or "inline review", AND the target file is
  markdown or plain text. Also use when the user invokes /inline-review.
---

# Inline Review

Annotate markdown (`.md`) and plain text (`.txt`) files by editing them directly —
insert CriticMarkup delimiters and maintain a YAML endmatter block. The user views
the result in Neovim with inline-review.nvim, which conceals the markup and renders
a review pane.

**File type restriction**: only operate on `.md` and `.txt` files. If the target
file is any other type, decline and suggest a different review approach.

Use `claude` as the author name on all annotations.

## Annotation types

### Comment — anchor text with a note

```
{==anchor text==}{>>comment body<<}{#c1}
```

### Addition — propose inserting text

```
{++proposed text++}{#s1}
```

### Deletion — propose removing text

```
{--text to remove--}{#s1}
```

### Replacement — propose swapping text

```
{~~old text~>new text~~}{#s1}
```

## ID rules

- Comment IDs use prefix `c`: `c1`, `c2`, `c3`, ...
- Suggestion IDs (addition, deletion, replacement) use prefix `s`: `s1`, `s2`, ...
- Always increment from the highest existing number. If c3 and c7 exist, the next comment is `c8`. Never fill gaps.
- Each annotation gets exactly one `{#id}` ref appended to its closing delimiter.

## Multi-line annotations

All types support spanning multiple lines. Each line in the selection gets its own
markup with the same ID.

### Multi-line comment

The first line carries the body. Continuation lines omit it:

```
{==first line anchor==}{>>the comment body<<}{#c1}
{==second line anchor==}{#c1}
```

### Multi-line deletion

Each line is wrapped independently:

```
{--first line text--}{#s1}
{--second line text--}{#s1}
```

### Multi-line replacement

Earlier lines become deletions. Only the last line carries the replacement:

```
{--first line text--}{#s1}
{~~last line text~>replacement text~~}{#s1}
```

## YAML endmatter

Metadata lives at the end of the file. The block is separated from content by a
blank line followed by `---`. If an endmatter block already exists, update it in
place. If not, append one.

### Structure

```yaml

---
comments:
  c1:
    by: claude
    at: 2025-01-15T10:30:00.000Z
  c2:
    body: good point
    by: claude
    at: 2025-01-15T11:00:00.000Z
    re: c1
suggestions:
  s1:
    by: claude
    at: 2025-01-15T10:31:00.000Z
```

### Rules

- Sections: `comments:` then `suggestions:`. Omit a section if empty.
- IDs are sorted: same prefix sorted numerically (`c1` before `c2`), different prefixes sorted alphabetically.
- Field order within an entry: `body`, `by`, `at`, `re`, `status`, `resolved`. Omit fields that are absent.
- Indentation: section at 0, ID at 2 spaces, fields at 4 spaces.
- Timestamps: UTC ISO 8601 with `.000Z` — `%Y-%m-%dT%H:%M:%S.000Z`.
- `body` field: present on replies (entries with `re:`). Top-level comment bodies go inline as `{>>body<<}` when single-line; a body containing newlines goes in the endmatter `body:` field instead (block scalar), with the inline markup carrying only the anchor: `{==anchor==}{#c1}`.
- `re` field: points to the parent ID for replies. Nested replies point to the reply they respond to.
- Quoting: values containing `: # {} [] , & * ! | > ' "` or starting with `- ?` must be double-quoted. Backslashes and double quotes inside are escaped.
- Multi-line values: use YAML block scalar `|` with continuation lines indented to 6 spaces.

## How to annotate (new review)

1. Read the file.
2. Scan for existing `{#c\d+}` and `{#s\d+}` refs to determine next available IDs.
3. If endmatter exists, parse it to get the full ID state.
4. Insert annotations inline at the relevant locations.
5. Append or update the endmatter block with entries for each new annotation.
6. Use the current UTC time for all timestamps in a single review pass.
7. Enter the review loop (see "Review loop").

## How to process an annotated draft

When you open a file that already contains annotations (from the user or another
reviewer), process each annotation by either accepting or disagreeing.

### Accepting a suggestion

Perform the intended operation and remove all markup and metadata for that ID:

- **Addition** `{++text++}{#s1}`: keep `text`, remove the delimiters and ref.
- **Deletion** `{--text--}{#s1}`: remove `text` and all markup.
- **Replacement** `{~~old~>new~~}{#s1}`: replace with `new`, remove markup.
- **Multi-line**: apply the same logic to every line carrying that ID.
- **Comment with an implied action** (e.g. "rewrite this paragraph"): perform
  the action on the anchor text, remove the original comment markup and its
  endmatter entry, then add a new comment on the changed text indicating what
  was done (e.g. `{==rewritten text==}{>>Rewrote per suggestion in previous review<<}{#cN}`).

After accepting, remove the ID's entry from the endmatter (`comments:` or
`suggestions:`). Also remove any replies (`re:` pointing to that ID) and their
descendants.

### Disagreeing with an annotation

Never delete markup or metadata. Instead, add a reply explaining why:

- For **suggestions** (addition/deletion/replacement): add a reply in the
  endmatter with `re:` pointing to the suggestion's ID. The reply is a comment
  entry with a `body:` field.
- For **comments**: add a reply with `re:` pointing to the comment's ID.

Keep disagreement replies brief — one or two sentences stating the reason.

```yaml
comments:
  c5:
    body: "Keeping the original phrasing — it matches the terminology in the spec."
    by: claude
    at: 2025-01-15T12:00:00.000Z
    re: s2
```

### Mixed processing

You can accept some annotations and disagree with others in the same pass. Process
all annotations in the file, don't leave any unaddressed. After processing, the
file should contain only: clean text (accepted changes applied), any annotations
you disagreed with (markup intact), and your new reply comments.

## Review loop

The review is a conversation: you annotate, the user responds, you process their
response, and so on until the file is clean. Run this loop after every annotation
pass (new review or processing).

### Loop steps

1. **Present the file** — open it for the user to review (see below).
2. **Wait for the user to finish** — the tmux popup blocks until nvim exits;
   for non-tmux, ask the user to confirm when done.
3. **Re-read the file** and check for remaining annotations (`{#c\d+}` or `{#s\d+}` refs).
4. **If annotations remain**: the user has responded — they may have accepted
   or rejected your suggestions, added new comments, or left your disagreements
   unresolved. Process the file again (see "How to process an annotated draft"),
   then go to step 1.
5. **If no annotations remain**: the review is complete. Report that the file is clean.

### Presenting the file

Check if the user is in a tmux session:

```bash
test -n "$TMUX"
```

**If inside tmux**: open the annotated file in a tmux popup overlay at 85% screen
area. The `-E` flag makes this call block until the user closes nvim, which is
your signal to re-read the file.

```bash
tmux popup -w 85% -h 85% -E "nvim '<file_path>'"
```

**If not inside tmux**: tell the user to open the annotated file in Neovim and
let you know when they're done:

> Open `<file_path>` in Neovim to review the annotations. Let me know when
> you're finished so I can process your responses.

## Judgment calls

- Prefer comments over suggestions when the issue is subjective or the fix isn't obvious.
- Prefer replacements over deletion+addition when rewriting a phrase.
- Keep comment bodies concise — one or two sentences.
- Don't annotate every line. Focus on substantive issues: clarity, correctness, structure, missing information.
- Group related feedback under a single comment when the lines are adjacent.
