#!/bin/bash
# Portuguese (Brazilian) phrase templates. %s is the repo name.
# shellcheck disable=SC2034  # arrays are consumed by notify.sh after sourcing
TEMPLATES_RESPONSE=(
  "%s está pronto para você"
  "%s requer sua atenção"
  "tarefa concluída em %s"
  "%s está pronto para sua revisão"
  "sua resposta é necessária em %s"
  "%s aguarda sua resposta"
  "trabalho concluído em %s"
  "resultado pronto em %s"
  "%s está preparado para sua revisão"
  "pronto para sua decisão em %s"
)
TEMPLATES_NOTIFICATION=(
  "%s requer uma decisão"
  "%s aguarda sua resposta"
  "%s requer sua atenção"
  "%s tem uma pergunta para você"
  "%s aguarda aprovação"
  "%s precisa de direção"
  "aprovação necessária em %s"
  "%s está pausado para sua revisão"
  "confirmação necessária em %s"
  "%s está bloqueado aguardando entrada"
)
