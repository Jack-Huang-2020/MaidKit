# Code of Conduct

Welcome to the MaidKit project!

MaidKit is a cross-platform SSH server manager maintained by Solsynth and its contributors. We welcome contributions ranging from bug reports and feature requests to documentation and code changes.

## Getting Started

Before you continue, please read and agree to Solsynth's Contributor License Agreement (CLA):
<https://solsynth.dev/legal/contributor-license>

AI-assisted contributions are welcome when they are reviewed and properly tested by someone who understands the affected code. You must be able to review and explain the changes you submit. We do not enforce a human-edit percentage, but unreviewed AI-generated changes that waste maintainers' time may result in the contributor being blocked from further contributions to Solsynth projects.

Pull requests must be linked to an issue so that the context and motivation for the change are clear. Localization-only updates may be submitted without linking an issue.

If you have read and understood the guidance above, feel free to fork the project and start contributing.

## Project Structure

MaidKit is a cross-platform Flutter application for managing servers over SSH. It provides server administration tools without requiring software to be installed on the managed servers.

The project is built with Flutter and uses Riverpod for state management, auto_route for navigation, Drift for local persistence, and dartssh2 for SSH behavior. See [docs/architecture.md](docs/architecture.md) for the project architecture.

## Commit Messages

We use gitmoji to clarify the reason for and nature of each change. Learn more at <https://gitmoji.dev>.

Commit messages should follow this syntax:

```text
:[gitmoji]: <commit message>
```

## New Features

Before implementing a new feature, create an issue or discuss it in the official development channel. Feature proposals should be discussed with the maintainers and community first. Pull requests for features that have not been discussed may not be merged.

## Bug Reports / Ask for Help

Read the error message, check for updates, and review the available documentation before creating an issue. Be respectful to maintainers and contributors in GitHub issues and development channels. Issues that are abusive, hostile, or unrelated to MaidKit may be removed, and repeated violations may result in a loss of contribution privileges.

## Styles of Code

Before creating a pull request, make sure the code passes `flutter analyze` and the relevant tests. Fix all reported issues where possible. If a diagnostic cannot be fixed for a valid reason, suppress it only with an explicit, narrowly scoped comment.

Write code comments in English so that they remain understandable to contributors across the project.

---

We appreciate every contribution. Let's work together to make server maintenance safer and more convenient!
