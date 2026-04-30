#!/bin/bash
# French phrase templates. Formal addressing (vous). %s is the repo name.
# shellcheck disable=SC2034  # arrays are consumed by notify.sh after sourcing
TEMPLATES_RESPONSE=(
  "%s est prêt pour vous"
  "%s requiert votre attention"
  "tâche terminée dans %s"
  "%s est prêt pour votre révision"
  "votre intervention est requise dans %s"
  "%s attend votre réponse"
  "travail terminé dans %s"
  "résultat prêt dans %s"
  "%s est préparé pour votre révision"
  "prêt pour votre décision dans %s"
)
TEMPLATES_NOTIFICATION=(
  "%s requiert une décision"
  "%s attend votre réponse"
  "%s requiert votre attention"
  "%s a une question pour vous"
  "%s est en attente d'approbation"
  "%s nécessite une orientation"
  "approbation requise dans %s"
  "%s est en pause pour votre révision"
  "confirmation requise dans %s"
  "%s est bloqué en attente d'une entrée"
)
