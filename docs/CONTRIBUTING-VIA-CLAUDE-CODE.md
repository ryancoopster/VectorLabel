# Adding a printer & opening a pull request — no terminal needed

This guide is for **people who got a new printer working with VectorLabel** (or want to
fix something) and want to contribute it back so it ships for everyone. **You don't need
to be a programmer, and you don't need to touch a terminal.** You'll describe the change
in plain English inside the **Claude app**, and Claude does the coding and the
GitHub steps (branch, commit, pull request) for you.

There are two documents:

- **This guide** — the click-by-click flow in the Claude app: connect GitHub, make the
  change, open the pull request.
- **[ADDING-PRINTER-TYPES.md](ADDING-PRINTER-TYPES.md)** — the technical recipe Claude
  follows to actually wire up a new printer type in the code. You don't have to read it;
  you just point Claude at it.

---

## 1. One-time setup (a few clicks)

1. **A GitHub account** — free at <https://github.com/join>. GitHub is where the
   VectorLabel code lives and where your change gets reviewed.
2. **The Claude app** — download it from <https://claude.ai/download> (or use
   <https://claude.ai> in your browser) and sign in.
3. **Connect GitHub to Claude.** In the Claude app, open **Settings → Connectors**
   (or the **+ / connect** control in the chat composer) and add the **GitHub**
   connector. It opens GitHub once in your browser to authorize the connection and lets
   you pick which repositories Claude may access. Grant it access to your copy of
   **VectorLabel** (you'll make that copy in the next step).

That's the whole setup — no Homebrew, no command-line tools, no `git`.

## 2. Get your own copy of the project

On the VectorLabel GitHub page (<https://github.com/ryancoopster/VectorLabel>), click
**Fork** (top-right). That makes a copy under your own account that you're free to
change. When Claude asks which repository to work in, point it at **your fork**.

> Don't worry about cloning or downloading anything — the Claude app works with the
> repository directly through the GitHub connection.

## 3. Make the change

Start a new chat in the Claude app, make sure the **GitHub connector is enabled** for
that chat, and paste a request like this:

> Work on my fork of **VectorLabel**. Please read `docs/ADDING-PRINTER-TYPES.md` and
> help me add support for my **&lt;printer model&gt;** printer. Here's what I know about it:
> &lt;describe how you got it working — the model name it reports, the label/byte format,
> its USB IDs, and anything you changed locally to make it print&gt;.

Claude will read the codebase, make the edits, and explain what it changed. Work with it
in plain English until you're happy — ask it to adjust anything that looks off. You can
also ask it to describe how to test a print so you can confirm on your own printer.

> **Supplies need no code.** You can add your printer's label sizes entirely in the app:
> **Engine ▸ Preferences ▸ Printers ▸ Edit Supplies…**, create a new supply group, and
> assign your printer's model to it. If you want those sizes to ship as built-in
> defaults for everyone, just ask Claude to add them to the default supply catalog.

## 4. Open the pull request

When it's working, ask Claude to submit it:

> Everything works. Please commit these changes to a new branch on my fork with a clear
> message, and open a pull request to the main VectorLabel repository describing the new
> printer support and how I tested it.

Claude creates the branch, commits, and opens the pull request through the GitHub
connection — **you never leave the chat**. It'll give you a link to the pull request.
Share that link; the maintainer reviews it, may ask for small tweaks (just relay them to
Claude), and merges it when it's ready. 🎉

## 5. Log the change

Every fix and feature that ships is recorded in [`CHANGELOG.md`](../CHANGELOG.md) under
the **[Unreleased]** heading, so the website's Downloads page can show users what
changed. Ask Claude to add a short bullet there as part of your pull request:

> Also add a one-line entry to `CHANGELOG.md` under `[Unreleased]` describing this change.

---

## Frequently asked

**Do I need to understand the code?** No. Describe your printer and what you observed;
Claude handles the implementation and the GitHub steps. Review what it proposes before
you approve it.

**Do I need a terminal, Homebrew, or the `gh`/`git` command line?** No — everything is
done through the Claude app and the GitHub connection. (A terminal-based flow is also
possible if you prefer it, but it's no longer required.)

**Is this safe?** Claude shows you what it's going to do and asks before it commits or
opens a pull request, and the change lands on **your** fork first — the maintainer still
reviews everything before it ships to anyone.

**Where do I describe what changed?** In the pull-request description. Be specific about
your printer model, how you tested (ideally a real test print), and anything you're not
100% sure of — see the safety notes in
[ADDING-PRINTER-TYPES.md](ADDING-PRINTER-TYPES.md).
