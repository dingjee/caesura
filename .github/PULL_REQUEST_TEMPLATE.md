<!--

Have you read Code of Conduct? By filing an Pull Request, you are expected to comply with it, including treating everyone with respect: https://github.com/dingjee/caesura/blob/main/CODE_OF_CONDUCT.md

-->

Issue: #
<!-- Link to relevant issue. All PRs should be associated with an issue -->

### Requirements

* Filling out the template is required. Any pull request that does not include enough information to be reviewed in a timely manner may be closed at the maintainers' discretion.

<!-- If there’s a checkbox you can’t complete for any reason, that's okay, just explain in detail why you weren’t able to do so. -->

- [ ]  issue was opened to discuss proposed changes before starting implementation. It is important do discuss changes before implementing them (Why should we add it? How should it work? How should it look? Where will it be? ...).
- [ ]  the change targets Caesura's native macOS app (Swift/AppKit/SwiftUI, macOS 13+).
- [ ]  app version number was not changed.
- [ ]  all new code has tests to ensure against regressions.
- [ ] `native/scripts/test.sh` compiles successfully and its core tests pass.
- [ ] `native/scripts/package-app.sh` builds and verifies the app; architectures checked are listed below.
- [ ]  GUI checks, if needed, used a temporary profile and a secondary display without activation or sounds; skipped checks are explained below.
- [ ]  the persistent trial was refreshed with `native/scripts/install-dist.sh` for a major application change or explicit request (otherwise the skipped build is noted), and `native/scripts/clean.sh --apply` completed without losing user data.
- [ ]  AI assistance is disclosed and the contributor understands and can maintain the changes.
- [ ]  README and CHANGELOG were updated accordingly.
- [ ]  after PR is approved, all commits in it are [squashed](https://gitbetter.substack.com/p/how-to-squash-git-commits)

### Description of the Change

<!--

We must be able to understand the design of your change from this description. If we can't get a good idea of what the code will be doing from the description here, the pull request may be closed at the maintainers' discretion. Keep in mind that the maintainer reviewing this PR may not be familiar with or have worked with the code here recently, so please walk us through the concepts.

-->


### Verification Process

<!--

What process did you follow to verify that your change has the desired effects?

- How did you verify that all new functionality works as expected?
- How did you verify that all changed functionality works as expected?
- How did you verify that the change has not introduced any regressions?

Describe the actions you performed (e.g., buttons you clicked, text you typed, commands you ran, etc.), and describe the results you observed.

-->


### Other information
