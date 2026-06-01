---
name: Bug report
about: Report a problem with Acuity
title: "[Bug] "
labels: bug
assignees: ''
---

**What happened**
A clear description of the bug and what you expected to happen instead.

**Display(s) affected**
- Model (e.g. Dell S2721DGF):
- Native resolution / refresh rate:
- Connection (DisplayPort / HDMI / USB-C / dock + model):

**`acuity list --json` output**

```
paste here
```

**Environment**
- macOS version:
- Mac model and chip (Apple Silicon or Intel):
- Acuity version (`acuity --version`):
- Install method (Homebrew cask or source build):

**Steps to reproduce**
1.
2.
3.

**Logs**
If the LaunchAgent or live re-apply is involved, attach relevant output from:

```
log show --predicate 'process == "acuity"' --last 10m
```
