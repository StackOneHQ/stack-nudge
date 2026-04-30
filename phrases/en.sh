#!/bin/bash
# English phrase templates. %s is the repo name.
# shellcheck disable=SC2034  # arrays are consumed by notify.sh after sourcing
TEMPLATES_RESPONSE=(
  "%s is ready for you"
  "%s needs your attention"
  "task complete in %s"
  "%s is ready for your review"
  "your input is needed in %s"
  "%s awaits your response"
  "work complete in %s"
  "output ready in %s"
  "%s is prepared for your review"
  "ready for your decision in %s"
)
TEMPLATES_NOTIFICATION=(
  "%s requires a decision"
  "%s is awaiting input"
  "%s requires your attention"
  "%s has a question for you"
  "%s is awaiting approval"
  "%s needs direction"
  "approval needed in %s"
  "%s is paused for your review"
  "confirmation required in %s"
  "%s is blocked awaiting input"
)
