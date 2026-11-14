---
name: no-hardcoded-environment-urls
roles: [all]
work: [code, design]
severity: major
---
Application code takes every URL, host and origin of a platform or product environment from configuration supplied by the environment, with no literal and no literal default, because a literal turns every rename or new environment into a release.
