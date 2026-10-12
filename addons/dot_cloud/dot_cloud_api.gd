extends RefCounted

## dot-cloud's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game or a tool could call that did not exist before.
## OLDEST is raised to LEVEL when something that could have been called is removed or
## changes meaning.

# 1: everything before this file existed (an absent file reads as 1).
# 2: DotCloudPublisher.extra_files (pack path -> file outside the source).
const LEVEL := 2
const OLDEST := 1
