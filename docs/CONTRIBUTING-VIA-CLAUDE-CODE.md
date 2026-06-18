# Adding a printer & opening a pull request with Claude Code

This guide is for **end users who got a new printer working with VectorLabel** and
want to contribute that support back so it ships for everyone. You don't need to be
a programmer — you'll drive [Claude Code](https://claude.com/claude-code) (an AI
coding assistant that runs in your terminal) and it does the Git/GitHub mechanics
for you.

There are two documents:

- **This guide** — the GitHub + Claude Code mechanics (one-time setup, then how to
  branch, commit, and open the pull request).
- **[ADDING-PRINTER-TYPES.md](ADDING-PRINTER-TYPES.md)** — the technical instruction
  set Claude Code follows to actually wire up a new printer type in the code.

---

## 1. One-time setup

You need three things installed:

1. **A GitHub account** — free at <https://github.com/join>.
2. **The GitHub CLI (`gh`)** — this is how Claude Code talks to GitHub.
   ```bash
   brew install gh        # macOS (Homebrew)
   gh auth login          # follow the prompts: GitHub.com → HTTPS → log in via browser
   ```
   `gh auth login` opens your browser once to connect your account. After that,
   Claude Code can create branches and pull requests on your behalf.
3. **Claude Code** — install and sign in:
   ```bash
   npm install -g @anthropic-ai/claude-code   # or see claude.com/claude-code
   ```

## 2. Get your own copy of the project

On the VectorLabel GitHub page, click **Fork** (top-right) to make a copy under your
account. Then clone *your fork* and open it in Claude Code:

```bash
gh repo fork ryancoopster/VectorLabel --clone        # forks + clones in one step
cd VectorLabel
claude                                                # starts Claude Code in this folder
```

> If you already cloned the original repo, that's fine — Claude Code can add your
> fork as a remote when it opens the PR. Just `cd` into the folder and run `claude`.

## 3. Make the change

Inside Claude Code, paste a request like this:

> Please read `docs/ADDING-PRINTER-TYPES.md` and help me add support for my
> **<printer model>** printer. Here's what I know about it: <describe how you got it
> working — the model string it reports, the label/byte format, USB ids, anything
> you changed locally to make it print>. Build and run the tests as you go.

Claude Code will read the codebase, make the edits, and verify with `swift build`
and `swift test` in the `MacApp/` folder. Work with it until your printer prints
correctly and the tests pass.

> **Tip — supplies:** you can add your printer's label supplies entirely in the app
> with no code: **Engine ▸ Preferences ▸ Printers ▸ Edit Supplies…**, create a new
> supply group, and assign your printer's model to it. If you want those supplies to
> ship as built-in defaults, ask Claude Code to add them to
> `SupplyCatalog.makeDefault()` instead.

## 4. Open the pull request

When everything works, just ask:

> Everything builds and prints. Please create a branch, commit these changes with a
> clear message, push to my fork, and open a pull request to the VectorLabel repo
> describing the new printer support.

Claude Code will run roughly these commands for you:

```bash
git checkout -b add-<printer>-support
git add -A
git commit -m "Add support for <printer model>"
git push -u origin add-<printer>-support     # pushes to YOUR fork
gh pr create --repo ryancoopster/VectorLabel \
  --title "Add support for <printer model>" \
  --body  "Summary of the printer, how it was tested, and any caveats."
```

`gh pr create` prints a link to your new pull request. Share that link — the
maintainer reviews it, may ask for tweaks, and merges it when it's ready. 🎉

---

## Frequently asked

**Do I need to understand the code?** No. Describe your printer and what you observed;
Claude Code handles the implementation and the Git commands. Review what it proposes
before you approve commits.

**Is this safe?** Claude Code asks before running commands. Nothing is pushed to
GitHub until you approve the push/PR step, and it goes to *your* fork first — the
maintainer still reviews before anything ships.

**Where do I describe what changed?** The pull-request body. Be specific about your
printer model, how you tested (ideally a real test print), and anything unverified —
see the safety notes in [ADDING-PRINTER-TYPES.md](ADDING-PRINTER-TYPES.md).
