# Git Explorer

Git Explorer is a native macOS app for browsing local Git repositories and the
repositories available to a GitHub account. It combines a searchable repository
sidebar with local README, commit graph, and file views, plus remote repository
previews and cloning.

The app is written in SwiftUI and targets the current development Mac:

- macOS 26.0 or newer
- Bundle identifier: `net.fuzzyhead.git`
- Apple development team: `VD7DMST4GD`

## Features

### Repository browser

- Discovers Git repositories within a selected local folder, including nested
  organization folders up to three levels deep.
- Loads owned, collaborator, and organization repositories from GitHub.
- Merges matching local and remote entries into one repository.
- Groups repositories by owner or organization.
- Filters by organization, local availability, remote-only status, and text
  search.
- Shows repository descriptions and private-repository indicators.

### Remote repositories

- Renders the repository README when one exists.
- Browses the default branch's commit graph, commit details, folders, and text
  files directly through the GitHub API without requiring a clone.
- Shows privacy, default branch, compact update time, and HTTPS clone URL.
- Prompts for a clone destination, defaulting to the configured local repositories folder.
- Reports clone and Git action progress and results through reusable top-right toasts.
- Authenticates private clones without putting the personal access token in the
  command-line arguments.

### Local repositories

- Fetches and prunes remote references when the graph opens, then shows updated
  remote branches and ahead/behind counts alongside the checked-out branch.
- Provides Fetch, fast-forward-only Pull, Push, and Sync (pull then push)
  controls in the repository header.
- Renders the local README.
- Browses files and folders without exposing hidden files.
- Displays an interactive Git history graph.

### Git graph

- Uses reverse chronological, topological Git history.
- Draws deterministic colored lanes, curved merges, HEAD emphasis, branch pills,
  tags, and merge labels.
- Keeps the graph Canvas and virtualized metadata list in independent,
  vertically synchronized layers.
- Reuses completed lanes and preserves active lanes where possible.
- Filters by branch, author, tag, and date.
- Highlights a commit's ancestry on hover.
- Opens commit details with full SHA, parents, children, changed files, and
  patch output.
- Offers branch checkout, comparison, rename, and safe deletion. Git's normal
  merged-branch protection remains in effect.
- Uses lazy row rendering and loads history incrementally in 500-commit pages.

## Requirements

- macOS 26.0 or newer
- Xcode 26 or newer
- Git
- XcodeGen 2.46 or newer when regenerating the Xcode project
- A GitHub personal access token for GitHub repositories

Git Explorer checks common Homebrew and system locations for Git. If Git is not
available, the app displays a warning with installation links and keeps remote
GitHub browsing available.

## GitHub personal access token

The preferred setup is a fine-grained personal access token with:

- Metadata: read-only
- Contents: read-only
- Access to the repositories and organizations you want Git Explorer to display

A classic token can instead use `repo` for private repositories and `read:org`
for organization membership.

There are two supported development workflows:

1. Enter the token in **Git Explorer → Settings** and choose **Save**. The app
   stores it in macOS Keychain.
2. Copy `.env.example` to `.env` and set:

   ```dotenv
   GITHUB_PAT=github_pat_your_token_here
   ```

The `.env` fallback is compiled only in Debug builds. Release builds use the
Keychain or a `GITHUB_PAT` process environment value. The real `.env` file is
ignored by Git and must never be committed.

GitHub requests use the official REST API and automatically paginate repository
and organization results.

## Getting started

Generate the Xcode project after changing `project.yml`:

```bash
xcodegen generate
```

Then open the project:

```bash
open GitExplorer.xcodeproj
```

Select the **GitExplorer** scheme and run it on **My Mac**.

On first launch:

1. Open **Git Explorer → Settings**.
2. Confirm that Git is detected.
3. Choose the local folder that contains your repositories.
4. Enter and save a GitHub personal access token, or use the Debug `.env`
   fallback.

The selected folder is retained as a security-scoped bookmark so sandboxed app
launches can reopen it.

## Command-line build and tests

Build without signing:

```bash
xcodebuild \
  -project GitExplorer.xcodeproj \
  -scheme GitExplorer \
  -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the test suite:

```bash
xcodebuild \
  -project GitExplorer.xcodeproj \
  -scheme GitExplorer \
  -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The tests cover deterministic linear and merge layouts, a 10,000-commit
performance fixture, installed-Git detection, recursive repository discovery,
and a real temporary repository with branches, a tag, a merge, children,
changed files, diff output, and dirty status.

## Architecture

```text
GitExplorerApp
└── AppModel
    ├── GitHubService
    │   ├── paginated repository and organization requests
    │   ├── remote README, commit, contents, and file requests
    │   └── Keychain-backed PAT storage
    └── GitService
        ├── Git executable detection
        ├── local repository discovery
        ├── status, log, details, and file operations
        └── clone and branch operations

ContentView
├── RepositorySidebar
└── RepositoryDetailView
    ├── RemoteRepositoryView
    └── LocalRepositoryView
        ├── LocalReadmeView
        ├── CommitGraphView
        │   ├── synchronized Canvas graph layer
        │   └── virtualized metadata layer
        └── FileBrowserView
```

`GitGraphLayout` is a deterministic lane allocator independent of SwiftUI. It
tracks active parent commits, retains existing lanes, fills empty lanes before
allocating new ones, and releases unused lanes after histories converge.

The app executes the installed Git CLI through `Process`. GitHub access uses
`URLSession`; there are no third-party runtime dependencies.

## Project layout

```text
GitExplorer/
  AppModel.swift
  CommitGraphView.swift
  ContentView.swift
  FileBrowserView.swift
  GitExplorerApp.swift
  GitGraphLayout.swift
  GitHubService.swift
  GitService.swift
  Models.swift
  RepositoryDetailView.swift
  RepositorySidebar.swift
  SettingsView.swift
GitExplorerTests/
  GitGraphLayoutTests.swift
  GitServiceTests.swift
project.yml
```

## Security notes

- Saved tokens are stored as generic passwords in macOS Keychain under service
  `net.fuzzyhead.git`.
- The token is sent only to `api.github.com` and, during authenticated private
  clones, to the repository's HTTPS Git endpoint through a temporary Git
  `http.extraHeader` environment configuration using GitHub's Basic token
  authentication format.
- Tokens are not embedded in clone URLs or Git command arguments.
- `.env` is development-only and ignored by source control.
- Use the narrowest repository access and read-only permissions that meet your
  needs.

## Current limits

- Local discovery searches three nested directory levels and skips common heavy
  folders such as `node_modules`, `Pods`, `vendor`, `DerivedData`, `build`, and
  `dist`.
- Graph loading starts with the newest 500 commits and loads older history as
  the user reaches the end of the graph.
- Remote graphs follow the repository's default branch and load in 100-commit
  GitHub API pages; remote branch mutations still require a local clone.
- Repository cloning uses the repository name under the selected root. If that
  destination already exists, Git reports the conflict and no files are
  overwritten.
- README rendering uses SwiftUI's native Markdown support; advanced GitHub
  Markdown extensions and repository-relative images may render differently
  from github.com.

## License

No license has been assigned.
