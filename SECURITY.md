# Security Policy

## Supported Versions

Security fixes are provided for the latest code on the default branch. Older commits and unpublished local builds are not supported.

## Reporting a Vulnerability

Do not report security vulnerabilities in public GitHub issues.

Use GitHub's private vulnerability reporting for this repository if it is enabled. If private reporting is unavailable, contact the maintainer privately through GitHub and include:

- a clear description of the issue
- steps to reproduce it
- impact assessment
- any suggested remediation

You should receive an initial response within 7 days.

## Sensitive Areas

Please be especially careful with reports involving:

- auth token storage or swapping
- profile isolation boundaries
- debug log redaction
- shell command execution or relaunch behavior
