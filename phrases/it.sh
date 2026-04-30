#!/bin/bash
# Italian phrase templates. Formal addressing (Lei). %s is the repo name.
# shellcheck disable=SC2034  # arrays are consumed by notify.sh after sourcing
TEMPLATES_RESPONSE=(
  "%s è pronto per Lei"
  "%s richiede la Sua attenzione"
  "attività completata in %s"
  "%s è pronto per la Sua revisione"
  "il Suo intervento è richiesto in %s"
  "%s attende la Sua risposta"
  "lavoro completato in %s"
  "risultato pronto in %s"
  "%s è preparato per la Sua revisione"
  "pronto per la Sua decisione in %s"
)
TEMPLATES_NOTIFICATION=(
  "%s richiede una decisione"
  "%s attende il Suo input"
  "%s richiede la Sua attenzione"
  "%s ha una domanda per Lei"
  "%s è in attesa di approvazione"
  "%s necessita di una direzione"
  "approvazione richiesta in %s"
  "%s è in pausa per la Sua revisione"
  "conferma richiesta in %s"
  "%s è bloccato in attesa di input"
)
